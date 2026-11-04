// POST /imports/:id/commit and /undo (data-model-goal8.md §18) against the local stack. Rights, scope and
// row checks are in the SQL functions and their pgTAP tests; this checks the routes around them.
import assert from 'node:assert/strict';
import { after, before, test } from 'node:test';
import { createVerifier } from '../src/auth.ts';
import type { Query } from '../src/db.ts';
import { simple } from './fixture.ts';
import { makeApp, SUPABASE_URL, TENANT_A, TENANT_B, tokenFor } from './helpers.ts';

const XLSX = 'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet';
const { app, db } = makeApp();
const verify = createVerifier(SUPABASE_URL);
let admin: string; // tenant_admin in A: excel_import run, review, commit; import_undo
let auditor: string; // auditor in A: no excel_import
let adminB: string; // tenant_admin in B, a read_only tenant
const s = Math.random().toString(36).slice(2, 8); // names unique per run
const cat = `T86 Pumps ${s}`;
let batch: string;

const asUser = async <T>(token: string, fn: (q: Query) => Promise<T>) => db.withUser((await verify(token))!, fn);
const post = (path: string, token?: string) =>
  app.inject({ method: 'POST', url: path, headers: token ? { authorization: `Bearer ${token}` } : {} });

before(async () => {
  [admin, auditor, adminB] = await Promise.all([tokenFor('admin.a@example.com', TENANT_A), tokenFor('auditor.a@example.com', TENANT_A),
    tokenFor('admin.b@example.com', TENANT_B)]);
  await asUser(admin, (q) => q('insert into public.asset_category (tenant_id, name) values (private.current_tenant_id(), $1)', [cat]));
  const up = await app.inject({ method: 'POST', url: '/imports',
    payload: simple([['Name', 'Category'], [`T86 pump 1 ${s}`, cat], [`T86 pump 2 ${s}`, cat], ['', cat]]),
    headers: { 'content-type': XLSX, 'x-file-name': 'a.xlsx', authorization: `Bearer ${admin}` } });
  assert.equal(up.statusCode, 201, up.body);
  batch = up.json().batch_id;
  await asUser(admin, (q) => q('select public.import_save_mapping($1, $2)', [batch, JSON.stringify(up.json().mapping)]));
});

after(async () => {
  await asUser(admin, (q) => q('update public.asset_category set is_active = false where name = $1', [cat]));
  await app.close();
  await db.pool.end();
});

test('commit and undo need a token, a known batch and the rights', async () => {
  assert.equal((await post(`/imports/${batch}/commit`)).statusCode, 401);
  assert.equal((await post('/imports/not-a-uuid/commit', admin)).statusCode, 404);
  assert.equal((await post(`/imports/${batch}/commit`, auditor)).statusCode, 403);
  assert.equal((await post(`/imports/${batch}/undo`, auditor)).statusCode, 403);
  assert.equal((await post(`/imports/${batch}/commit`, adminB)).statusCode, 403, 'read-only tenant');
  assert.equal((await post(`/imports/${batch}/undo`, admin)).statusCode, 409, 'not committed yet');
});

test('commit checks again and writes the good rows once; undo removes them', async () => {
  const first = await post(`/imports/${batch}/commit`, admin);
  assert.equal(first.statusCode, 200, first.body);
  assert.deepEqual([first.json().created_assets, first.json().skipped], [2, 1]);
  const again = await post(`/imports/${batch}/commit`, admin);
  assert.deepEqual(again.json(), first.json(), 'commit twice: same outcome');
  const live = () => asUser(admin, async (q) =>
    (await q<{ n: number }>('select count(*)::int as n from public.asset where name like $1 and deleted_at is null', [`T86 pump % ${s}`])).rows[0]!.n);
  assert.equal(await live(), 2, 'nothing created twice');

  const undo = await post(`/imports/${batch}/undo`, admin);
  assert.equal(undo.statusCode, 200, undo.body);
  assert.deepEqual([undo.json().undone, undo.json().blocked], [2, 0]);
  assert.equal(await live(), 0);
});
