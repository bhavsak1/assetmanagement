// Story 10.4: AI value matching. The checks alone, then the route against the local stack with a fake provider
// (CI never calls a model, D7).
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { after, before, test } from 'node:test';
import pg from 'pg';
import { createGateway, type ModelRequest, type Provider } from '../src/ai.ts';
import { buildApp } from '../src/app.ts';
import { createVerifier } from '../src/auth.ts';
import { createDb, type Query } from '../src/db.ts';
import { AI_SCHEMA, AI_SYSTEM, aiChecked, aiInput } from '../src/values.ts';
import { simple } from './fixture.ts';
import { DATABASE_URL, SUPABASE_URL, TENANT_A, tokenFor } from './helpers.ts';

const ask = [
  { column: 'vendor' as const, raw: 'Siemens Ind.', candidates: [{ id: 'v1', label: 'Siemens India Pvt Ltd' }, { id: 'v2', label: 'Sigma' }] },
  { column: 'location' as const, raw: 'Plnt-2 Nsk', candidates: [{ id: 'l1', label: 'Nashik / Plant 2' }] },
];

test('input: values and candidate names by index, never an id', () => {
  const input = aiInput(ask);
  assert.deepEqual(JSON.parse(input).values[0], { value: 0, field: 'vendor', text: 'Siemens Ind.',
    candidates: [{ candidate: 0, name: 'Siemens India Pvt Ltd' }, { candidate: 1, name: 'Sigma' }] });
  assert.ok(!input.includes('v1') && !input.includes('l1'));
});

test('checks: a value we sent, once, one of its candidates, confidence 0.5 to 1; anything else is dropped', () => {
  const out = aiChecked({ matches: [
    { value: 0, candidate: 0, confidence: 0.923, reason: 'name_variant' },
    { value: 0, candidate: 1, confidence: 0.99, reason: 'similar' }, // second answer for the same value
    { value: 1, candidate: 1, confidence: 0.9, reason: 'abbreviation' }, // not one of its candidates
    { value: 1, candidate: -1, confidence: 0.9, reason: 'similar' }, // "none fits"
    { value: 7, candidate: 0, confidence: 0.9, reason: 'similar' }, // not a value we sent
  ] }, ask);
  assert.deepEqual(out, [{ column: 'vendor', raw: 'Siemens Ind.', target_id: 'v1', confidence: 0.92, reason: 'name_variant', status: 'suggested' }]);
  assert.deepEqual(aiChecked({ matches: [{ value: 1, candidate: 0, confidence: 0.4, reason: 'similar' }] }, ask), []);
});

test('golden eval cases use the prompt and schema the route sends (D7)', () => {
  const cases = JSON.parse(readFileSync(new URL('../eval/cases/import_values.json', import.meta.url), 'utf8')) as
    { feature: string; system: string; schema: unknown; input: string; expect: Record<string, number> }[];
  assert.ok(cases.length >= 3);
  for (const c of cases) {
    assert.equal(c.feature, 'import_values');
    assert.equal(c.system, AI_SYSTEM);
    assert.deepEqual(c.schema, AI_SCHEMA);
    const values = (JSON.parse(c.input) as { values: { value: number; candidates: unknown[] }[] }).values;
    for (const [v, cand] of Object.entries(c.expect)) assert.ok(cand < (values[Number(v)]?.candidates.length ?? 0), `${v} -> ${cand}`);
  }
});

// Against the local stack.
const XLSX = 'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet';
const ADMIN_DATABASE_URL = process.env.ADMIN_DATABASE_URL ?? 'postgres://postgres:postgres@127.0.0.1:54322/postgres';
const db = createDb(DATABASE_URL);
const verify = createVerifier(SUPABASE_URL);
const admin = new pg.Client({ connectionString: ADMIN_DATABASE_URL });
const s = Math.random().toString(36).slice(2, 8);
const names = { category: `Air compressor ${s}`, location: `Plant 2 Nashik ${s}`, vendor: `Siemens India ${s}` };
let tokenA: string; // tenant admin in A: excel_import run and review; A has ai_addon
let auditorA: string; // no excel_import
const seen: ModelRequest[] = [];
// Picks the candidate carrying this run's suffix, as a good model would.
const provider: Provider = {
  name: 'fake',
  call: async (req) => {
    seen.push(req);
    const { values } = JSON.parse(req.input) as { values: { value: number; candidates: { candidate: number; name: string }[] }[] };
    const matches = values.map((v) => ({ value: v.value, candidate: v.candidates.find((c) => c.name.includes(s))?.candidate ?? -1,
      confidence: 0.92, reason: 'abbreviation' }));
    return { text: JSON.stringify({ matches }), stopReason: 'end_turn', usage: { input_tokens: 600, output_tokens: 90 } };
  },
};
const appWith = (enabled: boolean) => buildApp({ verify: createVerifier(SUPABASE_URL), withUser: db.withUser,
  callModel: createGateway({ withUser: db.withUser, providers: [provider], enabled }) });
const app = appWith(true);
const asUser = async <T>(token: string, fn: (q: Query) => Promise<T>) => db.withUser((await verify(token))!, fn);
const ids: Record<string, string> = {};

before(async () => {
  await admin.connect();
  [tokenA, auditorA] = await Promise.all([tokenFor('admin.a@example.com', TENANT_A), tokenFor('auditor.a@example.com', TENANT_A)]);
  ids.category = (await admin.query('insert into public.asset_category (tenant_id, name) values ($1, $2) returning id', [TENANT_A, names.category])).rows[0].id;
  ids.location = (await admin.query('insert into public.location (tenant_id, name) values ($1, $2) returning id', [TENANT_A, names.location])).rows[0].id;
  ids.vendor = (await admin.query(`insert into public.vendor (tenant_id, name, roles) values ($1, $2, '{oem}') returning id`, [TENANT_A, names.vendor])).rows[0].id;
  await admin.query('update public.asset_category set oem_vendor_ids = array[$2::uuid] where id = $1', [ids.category, ids.vendor]);
});
after(async () => {
  await admin.query('delete from public.ai_call where tenant_id = $1', [TENANT_A]);
  await admin.query('update public.asset_category set is_active = false where id = $1', [ids.category]);
  await admin.query('update public.location set active = false where id = $1', [ids.location]);
  await admin.query('update public.vendor set is_active = false where id = $1', [ids.vendor]);
  await admin.end(); await app.close(); await db.pool.end();
});

// Upload, save the rules mapping and validate, as the Mapping step does.
async function validated(rows: (string | null)[][]) {
  const up = await app.inject({ method: 'POST', url: '/imports', payload: simple([['Name', 'Category', 'Location', 'OEM vendor'], ...rows]),
    headers: { 'content-type': XLSX, 'x-file-name': 'messy.xlsx', authorization: `Bearer ${tokenA}` } });
  assert.equal(up.statusCode, 201, up.body);
  const id = up.json().batch_id as string;
  await asUser(tokenA, async (q) => {
    await q('select public.import_save_mapping($1, $2)', [id, JSON.stringify(up.json().mapping)]);
    await q('select public.import_validate($1)', [id]);
  });
  return id;
}
const suggest = (a: ReturnType<typeof buildApp>, id: string, token = tokenA) =>
  a.inject({ method: 'POST', url: `/imports/${id}/ai-values`, headers: { authorization: `Bearer ${token}` } });

test('route: odd values get existing records; only the distinct values go out; stored; a reload makes no call', async () => {
  const odd = { category: `Air comprsr ${s}`, location: `Plnt-2 Nsk ${s}`, vendor: `Siemens Ind. ${s}` };
  const id = await validated([[`Lathe ${s}`, odd.category, odd.location, odd.vendor], [`Fan ${s}`, odd.category, odd.location, odd.vendor]]);
  seen.length = 0;
  const r = await suggest(app, id);
  assert.equal(r.statusCode, 200, r.body);
  const values = r.json().values as { column: string; raw: string; target_id: string; status: string; confidence: number; candidates: { id: string }[] }[];
  assert.deepEqual(values.map((v) => [v.column, v.raw, v.target_id, v.status, v.confidence]), [
    ['category', odd.category, ids.category, 'suggested', 0.92],
    ['location', odd.location, ids.location, 'suggested', 0.92],
    ['vendor', odd.vendor, ids.vendor, 'suggested', 0.92]]);
  assert.ok(values.every((v) => v.candidates[0]!.id === v.target_id));
  assert.equal(seen.length, 1);
  const sent = JSON.parse(seen[0]!.input) as { values: { text: string }[] };
  assert.equal(sent.values.length, 3); // two rows, one value each
  assert.ok(!seen[0]!.input.includes('Lathe') && !/[0-9a-f]{8}-[0-9a-f]{4}-/.test(seen[0]!.input)); // no other column, no id
  const call = (await admin.query('select * from public.ai_call where subject_id = $1', [id])).rows[0];
  assert.deepEqual([call.feature, call.status, call.request, call.output], ['import_values', 'ok', null, null]); // D6

  const again = await suggest(app, id);
  assert.deepEqual(again.json(), r.json());
  assert.equal(seen.length, 1, 'stored values are not sent again');

  // The user accepts; validation runs again and every row resolves.
  await asUser(tokenA, async (q) => {
    await q('select public.import_decide_values($1, $2)', [id, JSON.stringify(values.map((v) => ({ column: v.column, raw: v.raw, target_id: v.target_id, status: 'accepted' })))]);
    await q('select public.import_validate($1)', [id]);
  });
  const codes = (await admin.query(`select distinct m ->> 'code' as code from public.import_row r, jsonb_array_elements(coalesce(r.messages, '[]')) m
    where r.batch_id = $1`, [id])).rows.map((x) => x.code);
  assert.ok(!codes.includes('not_found'), codes.join());
  assert.equal((await suggest(app, id)).json().values[0].status, 'accepted');
});

test('route: AI off, rights and status; nothing to match means no call', async () => {
  const id = await validated([[`Pump ${s}`, `Air comprsr 2 ${s}`, null, null]]);
  const off = appWith(false);
  assert.deepEqual([(await suggest(off, id)).statusCode, (await suggest(off, id)).json()], [503, { error: 'ai_off' }]);
  await off.close();
  assert.equal((await suggest(app, id, auditorA)).statusCode, 404); // no excel_import
  assert.equal((await suggest(app, '00000000-0000-0000-0000-000000000000')).statusCode, 404);
  assert.equal((await app.inject({ method: 'POST', url: `/imports/${id}/ai-values` })).statusCode, 401);

  const clean = await validated([[`Pump ${s}`, names.category, null, null]]);
  seen.length = 0;
  assert.deepEqual((await suggest(app, clean)).json(), { values: [] });
  assert.equal(seen.length, 0);

  await admin.query(`update public.import_batch set status = 'mapped' where id = $1`, [id]);
  assert.deepEqual((await suggest(app, id)).json(), { error: 'changed' });
});
