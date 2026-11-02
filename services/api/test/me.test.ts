import assert from 'node:assert/strict';
import { after, before, test } from 'node:test';
import { generateKeyPair, SignJWT } from 'jose';
import { buildApp } from '../src/app.ts';
import { createDb } from '../src/db.ts';
import { anonKey, DATABASE_URL, makeApp, signIn, SUPABASE_URL, TENANT_A, TENANT_B, tokenFor, USER_A, USER_B } from './helpers.ts';

const { app, db } = makeApp();
let tokenA: string;
before(async () => { tokenA = await tokenFor('test.user@example.com', TENANT_A); });
after(async () => { await app.close(); await db.pool.end(); });

const me = (token?: string) => app.inject({ url: '/me', headers: token ? { authorization: `Bearer ${token}` } : {} });

test('health needs no token', async () => {
  const r = await app.inject({ url: '/health' });
  assert.equal(r.statusCode, 200);
  assert.deepEqual(r.json(), { ok: true });
});

test('me returns the user and tenant, read through RLS', async () => {
  const r = await me(tokenA);
  assert.equal(r.statusCode, 200);
  assert.deepEqual(r.json(), { user_id: USER_A, tenant_id: TENANT_A, tenant_name: 'TEST Tenant A' });
});

test('no token, garbage, anon key: 401', async () => {
  assert.equal((await me()).statusCode, 401);
  assert.equal((await me('not-a-jwt')).statusCode, 401);
  assert.equal((await me(anonKey)).statusCode, 401);
});

test('a token signed by another key: 401', async () => {
  const { privateKey } = await generateKeyPair('ES256');
  const forged = await new SignJWT({ role: 'authenticated', tenant_id: TENANT_A })
    .setProtectedHeader({ alg: 'ES256' }).setSubject(USER_A).setIssuer(`${SUPABASE_URL}/auth/v1`)
    .setAudience('authenticated').setExpirationTime('5m').sign(privateKey);
  assert.equal((await me(forged)).statusCode, 401);
});

test('a token with no tenant picked: 403', async () => {
  assert.equal((await me((await signIn('test.user@example.com')).access_token)).statusCode, 403);
});

test('claims for a tenant the user is not in: RLS hides it, 403', async () => {
  // bypasses token checks on purpose: proves Postgres, not the service, refuses the tenant
  const forgedDb = createDb(DATABASE_URL, 1);
  const forged = buildApp({ verify: async () => ({ sub: USER_B, role: 'authenticated', tenant_id: TENANT_A }), withUser: forgedDb.withUser });
  const r = await forged.inject({ url: '/me', headers: { authorization: 'Bearer x' } });
  assert.equal(r.statusCode, 403);
  await forged.close(); await forgedDb.pool.end();
  assert.ok(TENANT_B); // user B's own tenant is B
});
