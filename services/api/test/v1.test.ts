// Story 9.2: the public API /v1 with API keys (docs/data-model-goal9.md §17). Real local database.
// Pool of one, so key requests and user requests share one physical connection (the 8.1 leak rule).
import assert from 'node:assert/strict';
import { randomUUID } from 'node:crypto';
import { after, before, test } from 'node:test';
import { buildApp } from '../src/app.ts';
import { createVerifier } from '../src/auth.ts';
import { createDb, type Query } from '../src/db.ts';
import { RATE_LIMIT } from '../src/v1.ts';
import { DATABASE_URL, SUPABASE_URL, TENANT_A, TENANT_B, tokenFor } from './helpers.ts';

const ADMIN_A = '00000000-0000-0000-0000-0000000a0001';
const WEB = 'http://localhost:5173';
const db = createDb(DATABASE_URL, 1);
const app = buildApp({ verify: createVerifier(SUPABASE_URL), withUser: db.withUser, withKey: db.withKey, corsOrigins: [WEB] });
const asAdmin = <T>(fn: (q: Query) => Promise<T>) => db.withUser({ sub: ADMIN_A, role: 'authenticated', tenant_id: TENANT_A }, fn);

const run = randomUUID().slice(0, 8).toUpperCase();
let key = ''; // plant manager: asset view, create, update, financials view
let readKey = ''; // technician: asset view only, no financials
let revokedKey = '';
let rateKey = '';
let category = '';
let location = '';
const assets: string[] = [];
let userToken = '';

async function integrationUser(q: Query, name: string, group: string) {
  const id = (await q<{ id: string }>('select public.create_integration_user($1) as id', [name])).rows[0]!.id;
  await q(`insert into public.user_group_assignment (tenant_id, user_id, security_group_id)
           select $1, $2, id from public.security_group where tenant_id = $1 and template_code = $3`, [TENANT_A, id, `starter.${group}`]);
  return id;
}
const newKey = async (q: Query, user: string, name = 'test') =>
  (await q<{ key: string }>("select key from public.create_api_key($1, $2, now() + interval '1 day')", [user, name])).rows[0]!.key;

before(async () => {
  await asAdmin(async (q) => {
    const writer = await integrationUser(q, `V1 writer ${run}`, 'plant_manager');
    const reader = await integrationUser(q, `V1 reader ${run}`, 'technician');
    key = await newKey(q, writer);
    rateKey = await newKey(q, writer, 'rate');
    revokedKey = await newKey(q, writer, 'revoked');
    readKey = await newKey(q, reader);
    category = (await q<{ id: string }>('insert into public.asset_category (tenant_id, name) values ($1, $2) returning id', [TENANT_A, `V1 ${run}`])).rows[0]!.id;
    location = (await q<{ id: string }>('insert into public.location (tenant_id, name) values ($1, $2) returning id', [TENANT_A, `V1 ${run}`])).rows[0]!.id;
    for (const n of [1, 2, 3]) {
      const id = randomUUID();
      await q('insert into public.asset (id, tenant_id, tag, name, category_id, location_id, purchase_value, purchase_currency) values ($1, $2, $3, $4, $5, $6, 1000, $7)',
        [id, TENANT_A, `V1-${run}-${n}`, `Pump ${n}`, category, location, 'INR']);
      assets.push(id);
    }
  });
  await asAdmin(async (q) => q('select public.revoke_api_key(id) from public.api_keys() where prefix = $1', [revokedKey.slice(5, 17)]));
  userToken = await tokenFor('test.user2@example.com', TENANT_B);
});
after(async () => { await app.close(); await db.pool.end(); });

const get = (url: string, k = key) => app.inject({ url, headers: { authorization: `Bearer ${k}` } });
const send = (method: 'POST' | 'PATCH', url: string, payload: object, k = key) => app.inject({ method, url, payload, headers: { authorization: `Bearer ${k}` } });

test('no key, a wrong key, a revoked key or a user token: 401 problem+json', async () => {
  const wrong = `${key.slice(0, 60)}${key.endsWith('A') ? 'B' : 'A'}`;
  for (const r of [await app.inject({ url: '/v1/assets' }), await get('/v1/assets', wrong), await get('/v1/assets', revokedKey), await get('/v1/assets', userToken)]) {
    assert.equal(r.statusCode, 401);
    assert.match(String(r.headers['content-type']), /^application\/problem\+json/);
    assert.equal(r.json().code, 'unauthorized');
  }
});

test('/v1/me names the integration user and tenant', async () => {
  const r = await get('/v1/me');
  assert.equal(r.statusCode, 200);
  assert.equal(r.json().name, `V1 writer ${run}`);
  assert.equal(r.json().tenant_id, TENANT_A);
});

test('assets page by cursor with no gap or repeat', async () => {
  const p1 = await get(`/v1/assets?category_id=${category}&limit=2`);
  assert.equal(p1.statusCode, 200);
  assert.equal(p1.json().data.length, 2);
  assert.ok(p1.json().next_cursor);
  const p2 = await get(`/v1/assets?category_id=${category}&limit=2&cursor=${p1.json().next_cursor}`);
  assert.equal(p2.json().data.length, 1);
  assert.equal(p2.json().next_cursor, null);
  const ids = [...p1.json().data, ...p2.json().data].map((a: { id: string }) => a.id);
  assert.deepEqual(ids.toSorted(), assets.toSorted());
  assert.match(p1.json().data[0].updated_at, /^\d{4}-\d\d-\d\dT\d\d:\d\d:\d\d\.\d+Z$/);
  assert.equal((await get(`/v1/assets?tag=v1-${run}-2`)).json().data[0].id, assets[1]);
  assert.equal((await get(`/v1/assets?cursor=nonsense`)).statusCode, 422);
  assert.equal((await get(`/v1/assets?limit=500`)).json().code, 'validation_failed');
});

test('one asset; masked money without asset_financials.view; unknown id 404', async () => {
  const r = await get(`/v1/assets/${assets[0]}`);
  assert.equal(r.statusCode, 200);
  assert.equal(r.json().purchase_value, '1000.0000');
  assert.equal((await get(`/v1/assets/${assets[0]}`, readKey)).json().purchase_value, null);
  assert.equal((await get(`/v1/assets/${randomUUID()}`)).statusCode, 404);
  assert.equal((await get('/v1/assets/not-a-uuid')).statusCode, 422);
  assert.equal((await get('/v1/nothing')).json().code, 'not_found');
});

test('create and change an asset; the audit row names the key', async () => {
  const c = await send('POST', '/v1/assets', { name: 'API pump', category_id: category, location_id: location, tag: `v1-${run}-new` });
  assert.equal(c.statusCode, 201);
  assert.equal(c.json().tag, `V1-${run}-NEW`);
  const p = await send('PATCH', `/v1/assets/${c.json().id}`, { model: 'X-200' });
  assert.equal(p.statusCode, 200);
  assert.equal(p.json().model, 'X-200');
  const audit = await asAdmin(async (q) => (await q<{ api_key_id: string | null; prefix: string }>(
    `select a.api_key_id, k.prefix from public.audit_log a join public.api_keys() k on k.id = a.api_key_id
     where a.record_id = $1 and a.action = 'update'`, [c.json().id])).rows);
  assert.equal(audit[0]?.prefix, key.slice(5, 17));
  assert.equal((await send('POST', '/v1/assets', { name: 'Dup', category_id: category, tag: `V1-${run}-NEW` })).statusCode, 409);
});

test('9.5a: a client id makes create safe to retry', async () => {
  const id = randomUUID();
  const c = await send('POST', '/v1/assets', { id, name: 'Retry pump', category_id: category });
  assert.equal(c.statusCode, 201);
  assert.equal(c.json().id, id);
  const again = await send('POST', '/v1/assets', { id, name: 'Retry pump', category_id: category });
  assert.equal(again.statusCode, 409);
  assert.equal((await get(`/v1/assets?category_id=${category}&limit=200`)).json().data.filter((a: { name: string }) => a.name === 'Retry pump').length, 1);
});

test('9.5a: deleted assets are tombstones with include_deleted, 410 on get and patch', async () => {
  const id = randomUUID();
  await asAdmin(async (q) => {
    await q('insert into public.asset (id, tenant_id, tag, name, category_id, location_id, purchase_value, purchase_currency) values ($1, $2, $3, $4, $5, $6, 5, $7)',
      [id, TENANT_A, `V1-${run}-DEL`, 'Gone pump', category, location, 'INR']);
    await q('update public.asset set deleted_at = now() where id = $1', [id]);
  });
  const live = (await get(`/v1/assets?category_id=${category}&limit=200`)).json().data as { id: string }[];
  assert.ok(!live.some((a) => a.id === id), 'left out by default');
  assert.ok(live.every((a) => (a as { deleted_at?: unknown }).deleted_at === null), 'live rows say deleted_at null');

  // Page one row at a time to the end: every live row and the tombstone, once each, in order.
  const seen: { id: string; updated_at: string; deleted_at?: string | null }[] = [];
  let cursor = '';
  do {
    const r = await get(`/v1/assets?category_id=${category}&include_deleted=true&limit=1${cursor && `&cursor=${cursor}`}`);
    assert.equal(r.statusCode, 200);
    seen.push(...r.json().data);
    cursor = r.json().next_cursor ?? '';
  } while (cursor);
  assert.deepEqual(seen.map((a) => a.id).toSorted(), [...live.map((a) => a.id), id].toSorted());
  const t = seen.find((a) => a.id === id)!;
  assert.deepEqual(Object.keys(t).toSorted(), ['created_at', 'deleted_at', 'id', 'tag', 'updated_at'], 'only id, tag and timestamps');
  assert.match(String(t.deleted_at), /Z$/);

  const g = await get(`/v1/assets/${id}`);
  assert.equal(g.statusCode, 410);
  assert.equal(g.json().code, 'gone');
  assert.equal(g.json().deleted_at, t.deleted_at);
  assert.equal((await send('PATCH', `/v1/assets/${id}`, { model: 'X' })).statusCode, 410);
  assert.equal((await get(`/v1/assets/${randomUUID()}`)).statusCode, 404, 'never existed stays 404');
});

test('bad bodies are 422 with the field named', async () => {
  const r = await send('POST', '/v1/assets', { category_id: category });
  assert.equal(r.statusCode, 422);
  assert.deepEqual(r.json().errors, [{ field: 'name', code: 'required' }]);
  assert.equal((await send('PATCH', `/v1/assets/${assets[0]}`, { status: 'disposed' })).statusCode, 422); // status is an action
  const bad = await send('POST', '/v1/assets', { name: 'X', category_id: randomUUID() });
  assert.equal(bad.statusCode, 422, bad.body); // the database refuses the category
});

test('a key without write rights: 403 on create and change, the row unchanged', async () => {
  assert.equal((await send('POST', '/v1/assets', { name: 'No', category_id: category }, readKey)).statusCode, 403);
  const r = await send('PATCH', `/v1/assets/${assets[0]}`, { model: 'hack' }, readKey);
  assert.equal(r.statusCode, 403);
  assert.equal(r.json().code, 'forbidden');
  assert.notEqual((await get(`/v1/assets/${assets[0]}`)).json().model, 'hack');
});

test('master data lists', async () => {
  const cats = (await get('/v1/categories')).json().data as { id: string }[];
  assert.ok(cats.some((c) => c.id === category));
  assert.ok(((await get('/v1/locations')).json().data as { id: string }[]).some((l) => l.id === location));
  assert.ok(((await get('/v1/asset-statuses')).json().data as { code: string }[]).some((s) => s.code === 'active'));
});

test(`${RATE_LIMIT} calls a minute per key, then 429 with Retry-After`, async () => {
  // Start early in a minute, so the window does not roll over mid-test.
  while (new Date().getUTCSeconds() > 40) await new Promise((r) => setTimeout(r, 1000));
  const codes = await Promise.all(Array.from({ length: RATE_LIMIT }, () => get('/v1/me', rateKey).then((r) => r.statusCode)));
  assert.deepEqual([...new Set(codes)], [200]);
  const r = await get('/v1/me', rateKey);
  assert.equal(r.statusCode, 429);
  assert.ok(Number(r.headers['retry-after']) > 0);
  assert.equal((await get('/v1/me')).statusCode, 200); // other keys are not limited
});

test('no CORS on /v1; the web origin still gets it elsewhere', async () => {
  const pre = (url: string) => app.inject({ method: 'OPTIONS', url, headers: { origin: WEB, 'access-control-request-method': 'GET' } });
  assert.equal((await pre('/v1/assets')).headers['access-control-allow-origin'], undefined);
  assert.equal((await pre('/me')).headers['access-control-allow-origin'], WEB);
});

test('the OpenAPI document lists the /v1 routes only', async () => {
  const r = await app.inject({ url: '/v1/openapi.json' });
  assert.equal(r.statusCode, 200);
  const paths = Object.keys(r.json().paths);
  assert.ok(r.json().openapi.startsWith('3.'));
  assert.ok(paths.includes('/v1/assets') && paths.includes('/v1/assets/{id}') && paths.includes('/v1/me'));
  assert.ok(!paths.some((p) => !p.startsWith('/v1/')));
});

test('key and user requests interleaved on one connection never mix', async () => {
  const calls = Array.from({ length: 20 }, (_, i) => (i % 2
    ? get('/v1/me').then((r) => assert.equal(r.json().tenant_id, TENANT_A))
    : app.inject({ url: '/me', headers: { authorization: `Bearer ${userToken}` } }).then((r) => assert.equal(r.json().tenant_id, TENANT_B))));
  await Promise.all(calls);
  const c = await db.pool.connect();
  try {
    const { rows } = await c.query("select current_user as role, coalesce(current_setting('request.jwt.claims', true), '') as claims");
    assert.deepEqual(rows[0], { role: 'assetly_api', claims: '' });
  } finally {
    c.release();
  }
});
