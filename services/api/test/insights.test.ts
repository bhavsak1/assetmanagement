// Story 10.6: the semantic layer and query compiler. The compiler alone first, then the routes against the local
// stack: list counts, one block per permission step, a forged query, scope and cross-tenant.
import assert from 'node:assert/strict';
import { randomUUID } from 'node:crypto';
import { after, before, test } from 'node:test';
import pg from 'pg';
import { buildApp } from '../src/app.ts';
import { createDb, type Claims, type Query } from '../src/db.ts';
import { buildCatalog, compile, loadCatalog, loadRights, QueryError } from '../src/insights.ts';
import { DATABASE_URL, TENANT_A, TENANT_B } from './helpers.ts';

const ALL = new Set(['asset_core', 'asset_financials', 'category_config', 'location_hierarchy', 'vendor_core', 'coverage_contract',
  'coverage_values', 'obligation', 'service_record', 'service_values'].map((d) => `${d}.view`));
const CUSTOM = [{ entity: 'asset', key: 'rated_kw', label: 'Rated kW', type: 'number', options: [] },
  { entity: 'vendor', key: 'gstin', label: 'GSTIN', type: 'text', options: [] }];
const full = buildCatalog(ALL, CUSTOM);
const refused = (q: unknown, code: QueryError['code'], cat = full) =>
  assert.throws(() => compile(q, cat), (e) => e instanceof QueryError && e.code === code, JSON.stringify(q));

test('catalog: one step per domain; a subject or field appears only with its domains', () => {
  const keys = (rights: string[]) => {
    const c = buildCatalog(new Set(rights.map((d) => `${d}.view`)), CUSTOM);
    return Object.fromEntries(Object.entries(c).map(([s, v]) => [s, Object.keys(v.fields)]));
  };
  assert.deepEqual(keys([]), {});
  const core = keys(['asset_core']);
  assert.deepEqual(Object.keys(core), ['asset']);
  for (const f of ['category', 'location', 'purchase_value', 'oem_vendor', 'amc_end', 'warranty_end']) assert.ok(!core.asset!.includes(f), f);
  assert.ok(core.asset!.includes('status') && core.asset!.includes('custom.rated_kw'));
  assert.ok(keys(['asset_core', 'asset_financials']).asset!.includes('purchase_value'));
  assert.ok(keys(['asset_core', 'location_hierarchy']).asset!.includes('location'));
  const cov = keys(['asset_core', 'coverage_contract']);
  assert.ok(cov.asset!.includes('amc_end') && !cov.coverage!.includes('contract_value') && !cov.coverage!.includes('vendor'));
  assert.ok(keys(['coverage_contract', 'coverage_values']).coverage!.includes('contract_value'));
  assert.equal(keys(['obligation']).obligation, undefined, 'obligation also needs asset_core');
  const svc = keys(['service_record', 'asset_core']).service_record!;
  assert.ok(!svc.includes('cost') && !svc.includes('obligation_name'));
  assert.ok(keys(['service_record', 'asset_core', 'service_values']).service_record!.includes('cost'));
  assert.deepEqual(keys(['vendor_core']).vendor, ['name', 'code', 'roles', 'active', 'added_on', 'custom.gstin']);
  assert.deepEqual(keys(['location_hierarchy']).location, ['name', 'code', 'type', 'parent', 'active']);
});

test('compiler: unknown, hidden and forged fields, ops and values are refused before SQL exists', () => {
  const planner = buildCatalog(new Set(['asset_core.view', 'insights_query.ask']), []);
  refused({ subject: 'asset', measures: [{ fn: 'sum', field: 'purchase_value' }] }, 'field_not_allowed', planner);
  refused({ subject: 'asset', fields: ['purchase_value'] }, 'field_not_allowed', planner);
  refused({ subject: 'asset', filters: [{ field: 'purchase_value', op: 'gt', value: 1 }] }, 'field_not_allowed', planner);
  refused({ subject: 'coverage' }, 'subject_not_allowed', planner);
  refused({ subject: '__proto__' }, 'subject_not_allowed');
  refused({ subject: 'asset', fields: ['constructor'] }, 'field_not_allowed');
  refused({ subject: 'asset', fields: ['name; drop table asset --'] }, 'field_not_allowed');
  refused({ subject: 'asset', fields: ['a.name'] }, 'field_not_allowed');
  refused({ subject: 'asset', fields: ['custom.gstin'] }, 'field_not_allowed'); // a vendor key on assets
  refused({ subject: 'asset', sql: 'select 1' }, 'bad_query');
  refused({ subject: 'asset', limit: 5000 }, 'bad_query');
  refused({ subject: 'asset', filters: Array(11).fill({ field: 'name', op: 'eq', value: 'x' }) }, 'bad_query');
  refused({ subject: 'asset', group_by: [{ field: 'tag' }, { field: 'name' }, { field: 'model' }] }, 'bad_query');
  refused({ subject: 'asset', filters: [{ field: 'name', op: 'gt', value: 'x' }] }, 'bad_op');
  refused({ subject: 'asset', filters: [{ field: 'name', op: 'raw', value: 'x' }] }, 'bad_op');
  refused({ subject: 'asset', filters: [{ field: 'name', op: 'eq', value: { sql: 'x' } }] }, 'bad_value');
  refused({ subject: 'asset', filters: [{ field: 'purchase_date', op: 'eq', value: "2026-01-01' or 1=1" }] }, 'bad_value');
  refused({ subject: 'asset', filters: [{ field: 'criticality', op: 'eq', value: 'Z' }] }, 'bad_value');
  refused({ subject: 'asset', filters: [{ field: 'amc_end', op: 'within_next_days', value: 1e9 }] }, 'bad_value');
  refused({ subject: 'asset', filters: [{ field: 'status', op: 'in_place', value: 'x' }] }, 'bad_op');
  refused({ subject: 'asset', measures: [{ fn: 'sum', field: 'name' }] }, 'bad_op');
  refused({ subject: 'asset', group_by: [{ field: 'purchase_date' }] }, 'bad_query'); // a date needs a bucket
  refused({ subject: 'asset', measures: [{ fn: 'count' }], sort: [{ field: 'name' }] }, 'field_not_allowed');
});

test('compiler: SQL never contains a value or a custom-field key; every value is a parameter', () => {
  const evil = ["x'); drop table asset; --", 'Pune', '%_\\', '9f1c-not-a-uuid'];
  const { sql, params } = compile({
    subject: 'asset', fields: ['tag', 'custom.rated_kw', 'purchase_value'],
    filters: [
      { field: 'name', op: 'contains', value: evil[0] },
      { field: 'manufacturer', op: 'in', value: [evil[1], evil[2]] },
      { field: 'purchase_value', op: 'between', value: [1234.5, 98765] },
      { field: 'custom.rated_kw', op: 'gt', value: 4321 },
      { field: 'purchase_date', op: 'gte', value: '2025-04-01' },
      { field: 'amc_end', op: 'within_next_days', value: 61 },
      { field: 'location', op: 'in_place', value: evil[3] },
      { field: 'criticality', op: 'eq', value: 'A' },
    ],
    sort: [{ field: 'purchase_value', dir: 'desc' }], limit: 777,
  }, full, [[], [], [], [], [], [], ['11111111-2222-3333-4444-555555555555']]);
  for (const v of [...evil, '1234.5', '98765', '4321', '2025-04-01', '61', "'A'", '777', 'rated_kw', 'pune', '11111111-2222']) {
    assert.ok(!sql.toLowerCase().includes(v.toLowerCase()), `${v} in ${sql}`);
  }
  assert.ok(params.includes('rated_kw') && params.includes(777) && params.includes(`%${'x\'); drop table asset; --'}%`));
  assert.ok(params.some((p) => Array.isArray(p) && p.includes('%_\\')), 'in values stay data');
  assert.ok(compile({ subject: 'asset', filters: [{ field: 'name', op: 'contains', value: '50%_off\\' }] }, full).params.includes('%50\\%\\_off\\\\%'));
  assert.equal(params.filter((p) => p === 'rated_kw').length, 1, 'one key parameter, used twice');
});

test('compiler: money aggregates group by currency; refs group by id too', () => {
  const { sql, columns } = compile({ subject: 'asset', group_by: [{ field: 'location' }], measures: [{ fn: 'count' }, { fn: 'sum', field: 'purchase_value' }] }, full);
  assert.deepEqual(columns.map((c) => c.key), ['location', 'purchase_value_currency', 'count', 'sum_purchase_value']);
  assert.match(sql, /group by 1, 2, a\.location_id/);
  const total = compile({ subject: 'asset', measures: [{ fn: 'sum', field: 'purchase_value' }] }, full);
  assert.deepEqual(total.columns.map((c) => c.key), ['purchase_value_currency', 'sum_purchase_value']);
});

// ---- Against the local stack ----------------------------------------------------------------------------------

const ADMIN_DATABASE_URL = process.env.ADMIN_DATABASE_URL ?? 'postgres://postgres:postgres@127.0.0.1:54322/postgres';
const ADMIN_A = '00000000-0000-0000-0000-0000000a0001';
const PLANNER_A = '00000000-0000-0000-0000-0000000a0003';
const TECH_A = '00000000-0000-0000-0000-0000000a0004';
const ADMIN_B = '00000000-0000-0000-0000-0000000b0001';
const db = createDb(DATABASE_URL);
const admin = new pg.Client({ connectionString: ADMIN_DATABASE_URL });
// Tokens are claims in JSON: auth is not under test here (me.test.ts covers it).
const claims = (sub: string, tenant = TENANT_A): Claims => ({ sub, role: 'authenticated', aud: 'authenticated', tenant_id: tenant });
const app = buildApp({ verify: async (t) => JSON.parse(Buffer.from(t, 'base64url').toString()), withUser: db.withUser });
const bearer = (sub: string, tenant = TENANT_A) => `Bearer ${Buffer.from(JSON.stringify(claims(sub, tenant))).toString('base64url')}`;
const runQ = (sub: string, payload: object, tenant = TENANT_A) =>
  app.inject({ method: 'POST', url: '/insights/run', payload, headers: { authorization: bearer(sub, tenant) } });
const catalogOf = (sub: string, tenant = TENANT_A) => app.inject({ url: '/insights/catalog', headers: { authorization: bearer(sub, tenant) } });
const as = <T>(sub: string, fn: (q: Query) => Promise<T>) => db.withUser(claims(sub), fn);

const s = randomUUID().slice(0, 6);
const ids: Record<string, string> = {};
let stepUser = ''; // an integration user that gains one domain at a time
let scoped = ''; // sees only the Pune subtree

before(async () => {
  await admin.connect();
  const one = async (sql: string, p: unknown[]) => (await admin.query(sql, p)).rows[0].id as string;
  ids.category = await one('insert into public.asset_category (tenant_id, name) values ($1, $2) returning id', [TENANT_A, `Insights ${s}`]);
  ids.pune = await one('insert into public.location (tenant_id, name) values ($1, $2) returning id', [TENANT_A, `Pune ${s}`]);
  ids.line = await one('insert into public.location (tenant_id, name, parent_id) values ($1, $2, $3) returning id', [TENANT_A, `Line 1 ${s}`, ids.pune]);
  ids.mumbai = await one('insert into public.location (tenant_id, name) values ($1, $2) returning id', [TENANT_A, `Mumbai ${s}`]);
  ids.vendor = await one(`insert into public.vendor (tenant_id, name, roles) values ($1, $2, '{om}') returning id`, [TENANT_A, `Acme ${s}`]);
  const places = [ids.pune, ids.pune, ids.line, ids.mumbai, ids.mumbai];
  for (const [i, loc] of places.entries()) {
    ids[`a${i}`] = await one(`insert into public.asset (tenant_id, tag, name, category_id, location_id, purchase_value, purchase_currency)
      values ($1, $2, $3, $4, $5, $6, $7) returning id`, [TENANT_A, `IN-${s}-${i}`, `Pump ${s} ${i}`, ids.category, loc, 1000 * (i + 1), i === 4 ? 'USD' : 'INR']);
  }
  // An AMC on asset 0 ending in 30 days.
  ids.amc = await one(`insert into public.coverage (tenant_id, coverage_type, vendor_id, reference, start_date, end_date, contract_value, contract_currency)
    values ($1, 'amc', $2, $3, current_date - 300, current_date + 30, 5000, 'INR') returning id`, [TENANT_A, ids.vendor, `AMC ${s}`]);
  await admin.query('insert into public.coverage_asset (tenant_id, coverage_id, asset_id) values ($1, $2, $3)', [TENANT_A, ids.amc, ids.a0]);

  const user = async (name: string) => as(ADMIN_A, async (q) => (await q<{ id: string }>('select public.create_integration_user($1) as id', [name])).rows[0]!.id);
  stepUser = await user(`Insights steps ${s}`);
  scoped = await user(`Insights scoped ${s}`);
  for (const [d, o] of [['insights_query', 'ask'], ['location_hierarchy', 'view'], ['asset_core', 'view']]) {
    await admin.query('select tests.grant($1, $2, $3, $4)', [TENANT_A, scoped, d, [o]]);
  }
  const profile = await one('insert into public.scope_profile (tenant_id, name) values ($1, $2) returning id', [TENANT_A, `Pune ${s}`]);
  await admin.query(`insert into public.scope_profile_rule (tenant_id, scope_profile_id, dimension, location_id) values ($1, $2, 'location', $3)`,
    [TENANT_A, profile, ids.pune]);
  await admin.query(`update public.user_group_assignment set scope_profile_id = $3 where tenant_id = $1 and user_id = $2 and security_group_id in
    (select p.security_group_id from public.group_domain_policy p join public.domain_operation o on o.id = p.domain_operation_id
     join public.security_domain d on d.id = o.security_domain_id where d.code = 'asset_core')`, [TENANT_A, scoped, profile]);
});
after(async () => {
  await admin.query('update public.asset set deleted_at = now() where tag like $1', [`IN-${s}-%`]);
  await admin.query('update public.coverage set deleted_at = now() where id = $1', [ids.amc]);
  await admin.end(); await app.close(); await db.pool.end();
});

const mine = { field: 'category', op: 'eq', value: `Insights ${s}` };

test('hand-written queries match the Assets list counts (count_assets)', async () => {
  const listed = await as(ADMIN_A, async (q) => ({
    all: (await q<{ n: number }>('select public.count_assets() as n')).rows[0]!.n,
    pune: (await q<{ n: number }>('select public.count_assets(p_location_id => $1) as n', [ids.pune])).rows[0]!.n,
    cat: (await q<{ n: number }>('select public.count_assets(p_category_id => $1) as n', [ids.category])).rows[0]!.n,
  }));
  const count = async (filters: object[]) => {
    const r = await runQ(ADMIN_A, { subject: 'asset', filters, measures: [{ fn: 'count' }] });
    assert.equal(r.statusCode, 200, r.body);
    return Number(r.json().rows[0][0]);
  };
  assert.equal(await count([]), listed.all);
  assert.equal(await count([{ field: 'location', op: 'in_place', value: `Pune ${s}` }]), listed.pune);
  assert.equal(listed.pune, 3);
  assert.equal(await count([mine]), listed.cat);
  assert.equal(await count([mine, { field: 'location', op: 'eq', value: ids.pune }]), 2);
  assert.equal(await count([mine, { field: 'amc_end', op: 'within_next_days', value: 60 }]), 1);
  assert.equal(await count([mine, { field: 'purchase_value', op: 'gte', value: 3000 }]), 3);
  assert.equal(await count([{ field: 'name', op: 'contains', value: "x' or 1=1; drop table public.asset; --" }]), 0);

  const sums = await runQ(ADMIN_A, { subject: 'asset', filters: [mine], measures: [{ fn: 'sum', field: 'purchase_value' }], sort: [{ field: 'purchase_value_currency' }] });
  assert.deepEqual(sums.json().rows.map((r: unknown[]) => [r[0], Number(r[1])]), [['INR', 10000], ['USD', 5000]]);
  const rows = await runQ(ADMIN_A, { subject: 'asset', filters: [mine], fields: ['tag', 'location', 'amc_end'], sort: [{ field: 'tag' }] });
  assert.deepEqual(rows.json().columns.map((c: { key: string }) => c.key), ['id', 'tag', 'location', 'amc_end']);
  assert.equal(rows.json().rows[0][2], `Pune ${s}`);
  assert.deepEqual(rows.json().resolved, [{ filter: 0, value: `Insights ${s}`, match: { id: ids.category, label: `Insights ${s}` } }]);
});

test('every subject compiles and runs for the tenant admin', async () => {
  const cat = await as(ADMIN_A, async (q) => loadCatalog(q, await loadRights(q)));
  assert.deepEqual(Object.keys(cat), ['asset', 'obligation', 'coverage', 'service_record', 'vendor', 'location']);
  for (const [subject, sub] of Object.entries(cat)) {
    const fields = Object.keys(sub.fields).slice(0, 20);
    const r = await runQ(ADMIN_A, { subject, fields, limit: 5 });
    assert.equal(r.statusCode, 200, `${subject} ${r.body}`);
    const g = await runQ(ADMIN_A, { subject, group_by: [{ field: fields[1]! }], measures: [{ fn: 'count' }] });
    assert.equal(g.statusCode, 200, `${subject} ${g.body}`);
  }
  const amc = await runQ(ADMIN_A, { subject: 'coverage', filters: [{ field: 'vendor', op: 'eq', value: `Acme ${s}` }], fields: ['reference', 'contract_value', 'asset_count'] });
  assert.deepEqual(amc.json().rows.map((r: unknown[]) => [r[1], Number(r[2]), r[3], Number(r[4])]), [[`AMC ${s}`, 5000, 'INR', 1]]);
});

test('reference values: an unknown or ambiguous name asks the user to choose; no SQL runs', async () => {
  const none = await runQ(ADMIN_A, { subject: 'asset', filters: [{ field: 'location', op: 'eq', value: `Nowhere ${s} zzzz` }] });
  assert.equal(none.statusCode, 200);
  assert.deepEqual(none.json().needs_choice, [{ filter: 0, value: `Nowhere ${s} zzzz`, options: [] }]);
  const fuzzy = await runQ(ADMIN_A, { subject: 'asset', filters: [{ field: 'location', op: 'eq', value: `${s}` }] });
  assert.ok(fuzzy.json().needs_choice[0].options.length >= 2, fuzzy.body); // Pune, Line 1 and Mumbai share the suffix
});

test('permission steps: a user gains a field only with its domain (catalog, compiler, view)', async () => {
  const fields = async () => {
    const r = await catalogOf(stepUser);
    if (r.statusCode !== 200) return r.statusCode;
    return Object.fromEntries((r.json().subjects as { key: string; fields: { key: string }[] }[]).map((x) => [x.key, x.fields.map((f) => f.key)]));
  };
  const grant = (d: string) => admin.query('select tests.grant($1, $2, $3, $4)', [TENANT_A, stepUser, d, [d === 'insights_query' ? 'ask' : 'view']]);
  assert.equal(await fields(), 403, 'no insights_query.ask');
  await grant('insights_query');
  assert.deepEqual(await fields(), {});
  assert.equal((await runQ(stepUser, { subject: 'asset' })).json().error, 'subject_not_allowed');
  await grant('asset_core');
  let f = await fields() as Record<string, string[]>;
  assert.ok(f.asset!.includes('tag') && !f.asset!.includes('purchase_value') && !f.asset!.includes('location') && !f.asset!.includes('amc_end'));
  const sum = { subject: 'asset', filters: [{ field: 'tag', op: 'contains', value: `IN-${s}` }], measures: [{ fn: 'sum', field: 'purchase_value' }] };
  assert.deepEqual([(await runQ(stepUser, sum)).statusCode, (await runQ(stepUser, sum)).json().error], [422, 'field_not_allowed']);
  await grant('asset_financials');
  f = await fields() as Record<string, string[]>;
  assert.ok(f.asset!.includes('purchase_value'));
  assert.equal((await runQ(stepUser, sum)).statusCode, 200);
  await grant('location_hierarchy');
  assert.ok((await fields() as Record<string, string[]>).asset!.includes('location'));
  await grant('coverage_contract');
  f = await fields() as Record<string, string[]>;
  assert.ok(f.asset!.includes('amc_end') && f.coverage!.includes('end_date') && !f.coverage!.includes('contract_value'));
  await grant('coverage_values');
  assert.ok((await fields() as Record<string, string[]>).coverage!.includes('contract_value'));
});

test('starter groups: a planner cannot get purchase values; a forged query returns nulls (third layer)', async () => {
  const planner = await catalogOf(PLANNER_A);
  assert.equal(planner.statusCode, 200);
  const asset = (planner.json().subjects as { key: string; fields: { key: string }[] }[]).find((x) => x.key === 'asset')!;
  assert.ok(!asset.fields.some((f) => f.key === 'purchase_value'));
  const r = await runQ(PLANNER_A, { subject: 'asset', measures: [{ fn: 'sum', field: 'purchase_value' }] });
  assert.deepEqual([r.statusCode, r.json()], [422, { error: 'field_not_allowed', at: 'measures/0' }]);
  // Forged past the compiler: SQL built from the admin's catalog, run as the planner. The secure view masks it.
  const adminCat = await as(ADMIN_A, async (q) => loadCatalog(q, await loadRights(q)));
  const { sql, params } = compile({ subject: 'asset', fields: ['tag', 'purchase_value'], filters: [{ field: 'tag', op: 'contains', value: `IN-${s}` }] }, adminCat);
  const rows = await as(PLANNER_A, async (q) => (await q<{ c2: unknown; c3: unknown }>(sql, params)).rows);
  assert.equal(rows.length, 5);
  assert.ok(rows.every((x) => x.c2 === null && x.c3 === null));
  // No insights_query.ask (technician) or no add-on (tenant B): 403 on both routes.
  for (const [sub, t] of [[TECH_A, TENANT_A], [ADMIN_B, TENANT_B]] as const) {
    assert.equal((await catalogOf(sub, t)).statusCode, 403);
    assert.equal((await runQ(sub, { subject: 'asset' }, t)).statusCode, 403);
  }
});

test('scope: a Pune-scoped user sees only Pune rows', async () => {
  const ours = { field: 'tag', op: 'contains', value: `IN-${s}` }; // no category_config, so no category field
  const r = await runQ(scoped, { subject: 'asset', filters: [ours], fields: ['tag', 'location'], sort: [{ field: 'tag' }] });
  assert.equal(r.statusCode, 200, r.body);
  assert.deepEqual(r.json().rows.map((x: unknown[]) => x[2]), [`Pune ${s}`, `Pune ${s}`, `Line 1 ${s}`]);
  const g = await runQ(scoped, { subject: 'asset', filters: [ours], group_by: [{ field: 'location' }], measures: [{ fn: 'count' }] });
  assert.ok(!g.json().rows.some((x: unknown[]) => x[0] === `Mumbai ${s}`));
});

test('cross-tenant: tenant A rows only, and a tenant B id resolves to nothing', async () => {
  const bLocation = (await admin.query('insert into public.location (tenant_id, name) values ($1, $2) returning id', [TENANT_B, `B only ${s}`])).rows[0].id as string;
  const r = await runQ(ADMIN_A, { subject: 'location', filters: [{ field: 'name', op: 'contains', value: s }], fields: ['name'] });
  assert.ok(!r.json().rows.some((x: unknown[]) => x[1] === `B only ${s}`));
  const forged = await runQ(ADMIN_A, { subject: 'asset', filters: [{ field: 'location', op: 'in_place', value: bLocation }] });
  assert.deepEqual(forged.json().needs_choice, [{ filter: 0, value: bLocation, options: [] }]);
  const all = await runQ(ADMIN_A, { subject: 'asset', fields: ['tag'], limit: 1000 });
  const tenants = (await admin.query('select distinct tenant_id from public.asset where id = any ($1::uuid[])', [all.json().rows.map((x: unknown[]) => x[0])])).rows;
  assert.deepEqual(tenants, [{ tenant_id: TENANT_A }]);
  await admin.query('update public.location set deleted_at = now() where id = $1', [bLocation]);
});

// Story 10.8: a saved widget is only query JSON. Each viewer re-runs it through /insights/run under their own rights.
test('saved widget: a shared widget shows each viewer only their own allowed rows, re-checked on every run', async () => {
  const ours = { field: 'tag', op: 'contains', value: `IN-${s}` };
  const saved = await as(ADMIN_A, async (q) => (await q<{ id: string }>(`insert into public.insight_widget (tenant_id, name, query, shared)
    values ($1, $2, $3, true), ($1, $4, $5, true) returning id`, [TENANT_A,
    `Places ${s}`, { subject: 'asset', filters: [ours], fields: ['tag', 'location'], sort: [{ field: 'tag' }] },
    `Value ${s}`, { subject: 'asset', filters: [ours], fields: ['tag', 'purchase_value'] }])).rows.map((r) => r.id));
  const widget = (sub: string, id: string) => as(sub, async (q) =>
    (await q<{ query: object }>('select query from public.insight_widget where id = $1', [id])).rows[0]?.query);
  const rerun = async (sub: string, id: string) => runQ(sub, (await widget(sub, id))!);

  assert.equal((await rerun(ADMIN_A, saved[0]!)).json().rows.length, 5, 'owner sees all five');
  const pune = await rerun(scoped, saved[0]!);
  assert.deepEqual(pune.json().rows.map((x: unknown[]) => x[2]), [`Pune ${s}`, `Pune ${s}`, `Line 1 ${s}`], 'scoped viewer: Pune only');
  assert.equal(await widget(TECH_A, saved[0]!), undefined, 'no insights_query.ask: the widget is not visible');

  // W5: a field the viewer cannot see is refused, never shown; it comes back with the domain, and goes again without it.
  const value = async () => { const r = await rerun(scoped, saved[1]!); return [r.statusCode, r.json().error]; };
  assert.deepEqual(await value(), [422, 'field_not_allowed']);
  await admin.query('select tests.grant($1, $2, $3, $4)', [TENANT_A, scoped, 'asset_financials', ['view']]);
  assert.deepEqual(await value(), [200, undefined]);
  await admin.query(`delete from public.group_domain_policy p using public.domain_operation o, public.security_domain d
    where o.id = p.domain_operation_id and d.id = o.security_domain_id and d.code = 'asset_financials' and p.tenant_id = $1
      and p.security_group_id in (select security_group_id from public.user_group_assignment where user_id = $2)`, [TENANT_A, scoped]);
  assert.deepEqual(await value(), [422, 'field_not_allowed']);
  await admin.query('update public.insight_widget set deleted_at = now() where id = any ($1::uuid[])', [saved]);
});
