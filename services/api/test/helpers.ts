// Real tokens from the local Supabase stack (seed users from supabase/seed.sql).
import { buildApp } from '../src/app.ts';
import { createVerifier } from '../src/auth.ts';
import { createDb } from '../src/db.ts';

export const SUPABASE_URL = process.env.SUPABASE_URL ?? 'http://127.0.0.1:54321';
export const DATABASE_URL = process.env.DATABASE_URL ?? 'postgres://assetly_api:assetly-local-api@127.0.0.1:54322/postgres';
const ANON_KEY = process.env.SUPABASE_ANON_KEY ?? '';

export const USER_A = '00000000-0000-0000-0000-0000000000a1'; // test.user, tenants A and B
export const USER_B = '00000000-0000-0000-0000-0000000000a2'; // test.user2, tenant B only
export const TENANT_A = '00000000-0000-0000-0000-00000000000a';
export const TENANT_B = '00000000-0000-0000-0000-00000000000b';

async function post(path: string, body: unknown, token = ANON_KEY) {
  const r = await fetch(SUPABASE_URL + path, {
    method: 'POST',
    headers: { apikey: ANON_KEY, authorization: `Bearer ${token}`, 'content-type': 'application/json' },
    body: JSON.stringify(body),
  });
  const text = await r.text();
  if (!r.ok) throw new Error(`${path} ${r.status} ${text}`);
  return text ? JSON.parse(text) : null;
}

export async function signIn(email: string): Promise<{ access_token: string; refresh_token: string }> {
  return post('/auth/v1/token?grant_type=password', { email, password: 'assetly-local-test' });
}

// The login flow from story 1.8: pick the tenant, then refresh so the hook adds tenant_id.
export async function tokenFor(email: string, tenantId: string): Promise<string> {
  const s = await signIn(email);
  await post('/rest/v1/rpc/select_tenant', { p_tenant_id: tenantId }, s.access_token);
  return (await post('/auth/v1/token?grant_type=refresh_token', { refresh_token: s.refresh_token })).access_token;
}

export function makeApp(poolSize?: number) {
  const db = createDb(DATABASE_URL, poolSize);
  const app = buildApp({ verify: createVerifier(SUPABASE_URL), withUser: db.withUser });
  return { app, db };
}

export const anonKey = ANON_KEY;
