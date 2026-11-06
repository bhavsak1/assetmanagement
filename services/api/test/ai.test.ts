// Story 10.1: the gateway against the local stack with fake providers (CI never calls a model, D7).
// Entitlement, cap and rate limit edges are in supabase/tests/10_1_ai_gateway.test.sql.
import assert from 'node:assert/strict';
import { after, before, test } from 'node:test';
import Anthropic from '@anthropic-ai/sdk'; // eslint-disable-line no-restricted-imports -- only to build SDK error objects
import pg from 'pg';
import { AiError, cost, createGateway, type ModelReply, type Provider } from '../src/ai.ts';
import { buildApp } from '../src/app.ts';
import { createVerifier } from '../src/auth.ts';
import type { Claims } from '../src/db.ts';
import { makeApp, SUPABASE_URL, TENANT_A, TENANT_B, tokenFor } from './helpers.ts';

const ADMIN_DATABASE_URL = process.env.ADMIN_DATABASE_URL ?? 'postgres://postgres:postgres@127.0.0.1:54322/postgres';
const { app, db } = makeApp();
const admin = new pg.Client({ connectionString: ADMIN_DATABASE_URL });
let adminA: Claims; // tenant admin in A: insights_query.ask, ai_usage.view; A has ai_addon
let auditorA: Claims; // auditor in A: ai_usage.view, no insights_query
let adminB: Claims; // tenant admin in B: no ai_addon
let tokenA: string;
before(async () => {
  await admin.connect();
  const verify = createVerifier(SUPABASE_URL);
  const tokens = await Promise.all([
    tokenFor('admin.a@example.com', TENANT_A), tokenFor('auditor.a@example.com', TENANT_A), tokenFor('admin.b@example.com', TENANT_B)]);
  tokenA = tokens[0];
  [adminA, auditorA, adminB] = (await Promise.all(tokens.map(verify))) as [Claims, Claims, Claims];
});
after(async () => {
  await admin.query('delete from public.ai_call where tenant_id = $1', [TENANT_A]);
  await admin.end(); await app.close(); await db.pool.end();
});

const SCHEMA = { type: 'object', properties: { answer: { type: 'string' } }, required: ['answer'], additionalProperties: false };
const usage = { input_tokens: 1000, output_tokens: 200, cache_read_input_tokens: 0 };
const ok = (text: string, stopReason = 'end_turn'): ModelReply => ({ text, stopReason, usage });
function fake(name: string, answer: () => ModelReply): Provider & { calls: number } {
  const p = { name, calls: 0, call: async () => { p.calls++; return answer(); } };
  return p;
}
const fail = (status: number) => () => { throw Anthropic.APIError.generate(status, { error: { message: 'provider text' } }, 'provider text', new Headers()); };
const call = (providers: Provider[], claims = adminA, enabled = true) =>
  createGateway({ withUser: db.withUser, providers, enabled })<{ answer: string }>({
    claims, feature: 'insights', system: 'rules', input: JSON.stringify({ question: 'how many pumps?' }), schema: SCHEMA,
  });
const row = async (id: string) => (await admin.query('select * from public.ai_call where id = $1', [id])).rows[0];
const lastRow = async () => (await admin.query('select * from public.ai_call where tenant_id = $1 order by created_at desc limit 1', [TENANT_A])).rows[0];
const code = async (p: Promise<unknown>) => { try { await p; return 'ok'; } catch (e) { return e instanceof AiError ? e.code : String(e); } };

test('a good answer is returned and logged with tokens and cost', async () => {
  const primary = fake('anthropic', () => ok('{"answer":"12"}'));
  const r = await call([primary]);
  assert.deepEqual(r.output, { answer: '12' });
  const c = await row(r.ai_call_id);
  assert.equal(c.status, 'ok');
  assert.equal(c.provider, 'anthropic');
  assert.equal(c.model, 'claude-haiku-5-5');
  assert.equal(c.input_tokens, 1000);
  assert.equal(Number(c.cost_micro_usd), cost('claude-haiku-5-5', usage)); // 100 + 100 = 200 micro USD
  assert.equal(Number(c.cost_micro_usd), 200);
  assert.deepEqual(c.output, { answer: '12' });
  assert.equal(c.request.input, '{"question":"how many pumps?"}');
});

test('a primary failure (503) falls back to the second provider', async () => {
  const primary = fake('anthropic', fail(503));
  const fallback = fake('vertex', () => ok('{"answer":"7"}'));
  const r = await call([primary, fallback]);
  assert.deepEqual(r.output, { answer: '7' });
  assert.equal(primary.calls, 1);
  assert.equal((await row(r.ai_call_id)).provider, 'vertex');
});

test('a 400 is our bug: no fallback, logged as an error code without provider text', async () => {
  const primary = fake('anthropic', fail(400));
  const fallback = fake('vertex', () => ok('{"answer":"7"}'));
  assert.equal(await code(call([primary, fallback])), 'ai_failed');
  assert.equal(fallback.calls, 0);
  const c = await lastRow();
  assert.equal(c.status, 'error');
  assert.equal(c.error_code, 'http_400');
});

test('both providers down: ai_failed, the last error is logged', async () => {
  assert.equal(await code(call([fake('anthropic', fail(529)), fake('vertex', fail(500))])), 'ai_failed');
  const c = await lastRow();
  assert.deepEqual([c.status, c.provider, c.error_code], ['error', 'vertex', 'http_500']);
});

test('an answer that fails the schema is an error, never best effort', async () => {
  assert.equal(await code(call([fake('anthropic', () => ok('{"answer":3}'))])), 'ai_failed');
  assert.equal((await lastRow()).error_code, 'bad_output');
  assert.equal(await code(call([fake('anthropic', () => ok('not json'))])), 'ai_failed');
  assert.equal((await lastRow()).error_code, 'bad_output');
});

test('a refusal is not retried on the fallback', async () => {
  const fallback = fake('vertex', () => ok('{"answer":"7"}'));
  assert.equal(await code(call([fake('anthropic', () => ok('', 'refusal')), fallback])), 'ai_failed');
  assert.equal(fallback.calls, 0);
  assert.equal((await lastRow()).error_code, 'refusal');
});

test('kill switch and no provider: ai_off, no row, no call', async () => {
  const before = (await admin.query('select count(*)::int as n from public.ai_call')).rows[0].n;
  const p = fake('anthropic', () => ok('{"answer":"1"}'));
  assert.equal(await code(call([p], adminA, false)), 'ai_off');
  assert.equal(await code(call([])), 'ai_off');
  assert.equal(p.calls, 0);
  assert.equal((await admin.query('select count(*)::int as n from public.ai_call')).rows[0].n, before);
});

test('refusals from ai_begin: no add-on, no right; the provider is never called', async () => {
  const p = fake('anthropic', () => ok('{"answer":"1"}'));
  assert.equal(await code(call([p], adminB)), 'ai_not_licensed');
  assert.equal(await code(call([p], auditorA)), 'ai_no_right');
  assert.equal(p.calls, 0);
});

test('POST /ai/check: one call end to end; 503 without a gateway; 401 without a token', async () => {
  const p = fake('anthropic', () => ok('{"ok":true}'));
  const withAi = buildApp({ verify: createVerifier(SUPABASE_URL), withUser: db.withUser,
    callModel: createGateway({ withUser: db.withUser, providers: [p], enabled: true }) });
  const r = await withAi.inject({ method: 'POST', url: '/ai/check', headers: { authorization: `Bearer ${tokenA}` } });
  assert.equal(r.statusCode, 200);
  assert.equal(r.json().ok, true);
  assert.equal((await row(r.json().ai_call_id)).feature, 'check');
  assert.equal((await withAi.inject({ method: 'POST', url: '/ai/check' })).statusCode, 401);
  await withAi.close();
  const off = await app.inject({ method: 'POST', url: '/ai/check', headers: { authorization: `Bearer ${tokenA}` } });
  assert.deepEqual([off.statusCode, off.json()], [503, { error: 'ai_off' }]);
});
