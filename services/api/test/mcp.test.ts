// Story 9.5b: the MCP server over /v1 (docs/data-model-goal9.md §19). A real MCP client (the official SDK) over HTTP
// against the real local database. Pool of one, as in v1.test.ts.
import assert from 'node:assert/strict';
import { randomUUID } from 'node:crypto';
import { after, before, test } from 'node:test';
import { Client } from '@modelcontextprotocol/sdk/client/index.js';
import { StreamableHTTPClientTransport } from '@modelcontextprotocol/sdk/client/streamableHttp.js';
import type { CallToolResult } from '@modelcontextprotocol/sdk/types.js';
import { buildApp } from '../src/app.ts';
import { createVerifier } from '../src/auth.ts';
import { createDb, type Query } from '../src/db.ts';
import { DATABASE_URL, SUPABASE_URL, TENANT_A } from './helpers.ts';

const ADMIN_A = '00000000-0000-0000-0000-0000000a0001';
const WEB = 'http://localhost:5173';
const db = createDb(DATABASE_URL, 1);
const app = buildApp({ verify: createVerifier(SUPABASE_URL), withUser: db.withUser, withKey: db.withKey, corsOrigins: [WEB] });
const asAdmin = <T>(fn: (q: Query) => Promise<T>) => db.withUser({ sub: ADMIN_A, role: 'authenticated', tenant_id: TENANT_A }, fn);

const run = randomUUID().slice(0, 8).toUpperCase();
let url = '';
let key = ''; // plant manager: asset view, create, update, financials view
let readKey = ''; // technician: asset view only, no financials
let category = '';
let asset = '';
let gone = '';
let client: Client;
let reader: Client;

async function integrationUser(q: Query, name: string, group: string) {
  const id = (await q<{ id: string }>('select public.create_integration_user($1) as id', [name])).rows[0]!.id;
  await q(`insert into public.user_group_assignment (tenant_id, user_id, security_group_id)
           select $1, $2, id from public.security_group where tenant_id = $1 and template_code = $3`, [TENANT_A, id, `starter.${group}`]);
  return (await q<{ key: string }>("select key from public.create_api_key($1, 'mcp', now() + interval '1 day')", [id])).rows[0]!.key;
}
async function connect(k: string) {
  const c = new Client({ name: 'test', version: '1' });
  await c.connect(new StreamableHTTPClientTransport(new URL(url), { requestInit: { headers: { authorization: `Bearer ${k}` } } }));
  return c;
}
const call = (c: Client, name: string, args: Record<string, unknown> = {}) => c.callTool({ name, arguments: args }) as Promise<CallToolResult>;
const errorOf = (r: CallToolResult) => (r.isError ? JSON.parse((r.content[0] as { text: string }).text) : null) as { status: number; code: string } | null;

before(async () => {
  await asAdmin(async (q) => {
    key = await integrationUser(q, `MCP writer ${run}`, 'plant_manager');
    readKey = await integrationUser(q, `MCP reader ${run}`, 'technician');
    category = (await q<{ id: string }>('insert into public.asset_category (tenant_id, name) values ($1, $2) returning id', [TENANT_A, `MCP ${run}`])).rows[0]!.id;
    asset = randomUUID();
    gone = randomUUID();
    for (const [id, tag] of [[asset, 'A'], [gone, 'G']]) {
      await q('insert into public.asset (id, tenant_id, tag, name, category_id, purchase_value, purchase_currency) values ($1, $2, $3, $4, $5, 900, $6)',
        [id, TENANT_A, `MCP-${run}-${tag}`, `Compressor ${tag}`, category, 'INR']);
    }
    await q('update public.asset set deleted_at = now() where id = $1', [gone]);
  });
  await app.listen({ port: 0, host: '127.0.0.1' });
  const { port } = app.server.address() as { port: number };
  url = `http://127.0.0.1:${port}/mcp`;
  client = await connect(key);
  reader = await connect(readKey);
});
after(async () => {
  await client.close();
  await reader.close();
  await app.close();
  await db.pool.end();
});

test('a bad or missing key is HTTP 401 with WWW-Authenticate, before any JSON-RPC', async () => {
  for (const k of ['', 'asly_wrong_key']) {
    const r = await fetch(url, {
      method: 'POST',
      headers: { 'content-type': 'application/json', accept: 'application/json, text/event-stream', ...(k && { authorization: `Bearer ${k}` }) },
      body: JSON.stringify({ jsonrpc: '2.0', id: 1, method: 'tools/call', params: { name: 'whoami', arguments: {} } }),
    });
    assert.equal(r.status, 401);
    assert.equal(r.headers.get('www-authenticate'), 'Bearer');
  }
  await assert.rejects(connect('asly_wrong_key'));
});

test('tools/list: 8 tools with schemas taken from /v1', async () => {
  const { tools } = await client.listTools();
  assert.deepEqual(tools.map((t) => t.name).toSorted(), ['create_asset', 'get_asset', 'list_asset_statuses', 'list_assets', 'list_categories', 'list_locations', 'update_asset', 'whoami']);
  const by = Object.fromEntries(tools.map((t) => [t.name, t]));
  assert.ok(by.list_assets!.inputSchema.properties!.include_deleted, 'the /v1 query parameters');
  assert.deepEqual(by.create_asset!.inputSchema.required, ['name', 'category_id']);
  assert.deepEqual(by.update_asset!.inputSchema.required, ['id']);
  assert.ok((by.get_asset!.outputSchema!.properties as Record<string, unknown>).purchase_value, 'the Asset schema inlined');
  assert.equal(by.list_assets!.annotations!.readOnlyHint, true);
  assert.equal(by.create_asset!.annotations!.destructiveHint, false);
});

test('read tools: whoami, list, get; a field the key cannot see stays null', async () => {
  assert.equal((await call(client, 'whoami')).structuredContent!.name, `MCP writer ${run}`);
  const list = await call(client, 'list_assets', { category_id: category, limit: 10 });
  assert.deepEqual((list.structuredContent!.data as { id: string }[]).map((a) => a.id), [asset]);
  assert.equal((await call(client, 'get_asset', { id: asset })).structuredContent!.purchase_value, '900.0000');
  assert.equal((await call(reader, 'get_asset', { id: asset })).structuredContent!.purchase_value, null);
  assert.ok(((await call(client, 'list_categories')).structuredContent!.data as { id: string }[]).some((c) => c.id === category));
});

test('deleted assets: a tombstone with include_deleted, gone on get, not_found for unknown', async () => {
  const list = await call(client, 'list_assets', { category_id: category, include_deleted: true });
  assert.ok((list.structuredContent!.data as { id: string; deleted_at: string | null }[]).some((a) => a.id === gone && a.deleted_at));
  assert.equal(errorOf(await call(client, 'get_asset', { id: gone }))?.code, 'gone');
  assert.equal(errorOf(await call(client, 'get_asset', { id: randomUUID() }))?.code, 'not_found');
});

test('write tools: create with a client id, retry is 409, update; the audit row names the key', async () => {
  const id = randomUUID();
  const c = await call(client, 'create_asset', { id, name: 'Agent pump', category_id: category });
  assert.equal(c.isError, undefined, JSON.stringify(c.content));
  assert.equal(c.structuredContent!.id, id);
  assert.equal(errorOf(await call(client, 'create_asset', { id, name: 'Agent pump', category_id: category }))?.code, 'conflict');
  assert.equal((await call(client, 'update_asset', { id, model: 'MCP-1' })).structuredContent!.model, 'MCP-1');
  const prefix = await asAdmin(async (q) => (await q<{ prefix: string }>(
    `select k.prefix from public.audit_log a join public.api_keys() k on k.id = a.api_key_id where a.record_id = $1 and a.action = 'update'`, [id])).rows[0]?.prefix);
  assert.equal(prefix, key.slice(5, 17));
});

test('refusals are tool errors the model can read', async () => {
  assert.equal(errorOf(await call(reader, 'create_asset', { name: 'No', category_id: category }))?.code, 'forbidden');
  const bad = errorOf(await call(client, 'create_asset', { category_id: category }));
  assert.equal(bad?.code, 'validation_failed');
  assert.equal(errorOf(await call(client, 'update_asset', { id: asset, status: 'disposed' }))?.code, 'validation_failed');
  await assert.rejects(call(client, 'drop_tables'), /Unknown tool/);
});

test('GET and DELETE are 405; a foreign Origin is 403; no CORS headers', async () => {
  assert.equal((await fetch(url)).status, 405);
  assert.equal((await fetch(url, { method: 'DELETE' })).status, 405);
  const r = await fetch(url, { method: 'POST', headers: { origin: 'https://evil.example', authorization: `Bearer ${key}`, 'content-type': 'application/json' }, body: '{}' });
  assert.equal(r.status, 403);
  const pre = await app.inject({ method: 'OPTIONS', url: '/mcp', headers: { origin: WEB, 'access-control-request-method': 'POST' } });
  assert.equal(pre.headers['access-control-allow-origin'], undefined);
});
