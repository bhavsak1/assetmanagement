// Pooled connections never leak tenant context (docs/data-model-goal8.md §2).
// Pool of one: every request reuses the same physical connection, stricter than Supavisor.
import assert from 'node:assert/strict';
import { after, before, test } from 'node:test';
import { makeApp, TENANT_A, TENANT_B, tokenFor, USER_A, USER_B } from './helpers.ts';

const { app, db } = makeApp(1);
let tokens: Record<string, string>;
before(async () => {
  tokens = { [TENANT_A]: await tokenFor('test.user@example.com', TENANT_A), [TENANT_B]: await tokenFor('test.user2@example.com', TENANT_B) };
});
after(async () => { await app.close(); await db.pool.end(); });

const me = (tenant: string) => app.inject({ url: '/me', headers: { authorization: `Bearer ${tokens[tenant]}` } });
const owner = { [TENANT_A]: USER_A, [TENANT_B]: USER_B };

test('50 interleaved requests each see only their own user and tenant', async () => {
  const tenants = Array.from({ length: 50 }, (_, i) => (i % 2 ? TENANT_B : TENANT_A));
  const answers = await Promise.all(tenants.map(me));
  answers.forEach((r, i) => {
    assert.equal(r.statusCode, 200);
    assert.deepEqual(r.json(), { user_id: owner[tenants[i]!], tenant_id: tenants[i], tenant_name: tenants[i] === TENANT_A ? 'TEST Tenant A' : 'TEST Tenant B' });
  });
});

test('a request that fails mid-transaction leaves nothing behind', async () => {
  const claims = { sub: USER_A, role: 'authenticated', tenant_id: TENANT_A };
  await assert.rejects(db.withUser(claims, (q) => q('select 1 / 0')));
  const r = await me(TENANT_B);
  assert.equal(r.json().tenant_id, TENANT_B);
});

test('outside a request the connection is the bare service role with no claims', async () => {
  const c = await db.pool.connect();
  try {
    const { rows } = await c.query("select current_user as role, coalesce(current_setting('request.jwt.claims', true), '') as claims");
    assert.deepEqual(rows[0], { role: 'assetly_api', claims: '' });
    await assert.rejects(c.query('select 1 from public.tenant'), /permission denied/);
    await assert.rejects(c.query('select 1 from public.asset'), /permission denied/);
  } finally {
    c.release();
  }
});
