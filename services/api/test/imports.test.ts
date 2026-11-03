// POST /imports against the local stack: auth, RLS, limits, CORS (data-model-goal8.md §13).
import assert from 'node:assert/strict';
import { after, before, test } from 'node:test';
import { buildApp } from '../src/app.ts';
import { createVerifier } from '../src/auth.ts';
import { MAX_ROWS } from '../src/imports.ts';
import { simple } from './fixture.ts';
import { makeApp, SUPABASE_URL, TENANT_A, TENANT_B, tokenFor } from './helpers.ts';

const XLSX = 'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet';
const { app, db } = makeApp();
let admin: string; // tenant_admin in A: excel_import run, review, commit
let auditor: string; // auditor in A: no excel_import
let adminB: string; // tenant_admin in B, a read_only tenant
before(async () => {
  [admin, auditor, adminB] = await Promise.all([
    tokenFor('admin.a@example.com', TENANT_A), tokenFor('auditor.a@example.com', TENANT_A), tokenFor('admin.b@example.com', TENANT_B)]);
});
after(async () => { await app.close(); await db.pool.end(); });

const upload = (body: Buffer, token?: string, name = 'assets.xlsx', url = '/imports') => app.inject({
  method: 'POST', url, payload: body,
  headers: { 'content-type': XLSX, 'x-file-name': encodeURIComponent(name), ...(token ? { authorization: `Bearer ${token}` } : {}) },
});

// Reads as the uploader, through RLS.
async function staged(token: string, batchId: string) {
  const claims = (await createVerifier(SUPABASE_URL)(token))!;
  return db.withUser(claims, async (q) => ({
    batch: (await q('select tenant_id, file_name, sheet_name, header_row, columns, row_count, status from public.import_batch where id = $1', [batchId])).rows[0],
    rows: (await q('select row_number, cells from public.import_row where batch_id = $1 order by row_number', [batchId])).rows,
  }));
}

const messy = simple([
  ['Asset register, Pune plant'],
  [],
  ['Asset Name', 'Tag', 'Wty Till', 'Tag'],
  ['Air compressor', 'PNE-0188', 45839, null],
  ['=cmd|calc', 'X-2', null, null, 'extra'],
]);

test('stages a messy sheet: title row skipped, header found, rows kept with Excel row numbers', async () => {
  const r = await upload(messy, admin, 'Pune assets ✓.xlsx');
  assert.equal(r.statusCode, 201, r.body);
  const body = r.json();
  assert.equal(body.header_row, 3);
  assert.deepEqual(body.columns, ['Asset Name', 'Tag', 'Wty Till', 'Tag (2)', 'Column E']);
  assert.equal(body.row_count, 2);
  assert.deepEqual(body.warnings.list, [{ code: 'beyond_header', column: 4 }]);

  const { batch, rows } = await staged(admin, body.batch_id);
  assert.deepEqual(batch, { tenant_id: TENANT_A, file_name: 'Pune assets ✓.xlsx', sheet_name: 'Sheet1', header_row: 3,
    columns: body.columns, row_count: 2, status: 'staged' });
  assert.deepEqual(rows, [
    { row_number: 4, cells: ['Air compressor', 'PNE-0188', 45839] },
    { row_number: 5, cells: ['=cmd|calc', 'X-2', null, null, 'extra'] },
  ]);
});

test('no token: 401', async () => {
  assert.equal((await upload(messy)).statusCode, 401);
});

test('no excel_import.run: 403, nothing staged', async () => {
  const r = await upload(messy, auditor);
  assert.equal(r.statusCode, 403, r.body);
});

test('read_only tenant: 403', async () => {
  assert.equal((await upload(messy, adminB)).statusCode, 403);
});

test('wrong name or type: 415', async () => {
  assert.equal((await upload(messy, admin, 'assets.csv')).statusCode, 415);
  assert.equal((await upload(Buffer.from('a,b'), admin)).statusCode, 415);
  const r = await app.inject({ method: 'POST', url: '/imports', payload: 'a,b', headers: { 'content-type': 'text/csv', authorization: `Bearer ${admin}` } });
  assert.equal(r.statusCode, 415);
});

test('over 10 MB: 413', async () => {
  assert.equal((await upload(Buffer.alloc(10 * 2 ** 20 + 1), admin)).statusCode, 413);
});

test('over 20,000 data rows: 413 and the transaction leaves nothing', async () => {
  const rows = [['Name'], ...Array.from({ length: MAX_ROWS + 1 }, (_, i) => [`a${i}`])];
  const r = await upload(simple(rows), admin, 'big.xlsx');
  assert.equal(r.statusCode, 413);
  assert.deepEqual(r.json(), { error: 'too_many_rows' });
  const claims = (await createVerifier(SUPABASE_URL)(admin))!;
  const n = await db.withUser(claims, async (q) => (await q<{ n: number }>("select count(*)::int as n from public.import_batch where file_name = 'big.xlsx'")).rows[0]!.n);
  assert.equal(n, 0);
});

test('an unknown sheet name: 400', async () => {
  const r = await upload(messy, admin, 'assets.xlsx', '/imports?sheet=Nope');
  assert.equal(r.statusCode, 400);
  assert.deepEqual(r.json(), { error: 'sheet_not_found' });
});

test('busy instance: 429', async () => {
  const busy = buildApp({ verify: createVerifier(SUPABASE_URL), withUser: db.withUser, maxParses: 0 });
  const r = await busy.inject({ method: 'POST', url: '/imports', payload: messy,
    headers: { 'content-type': XLSX, 'x-file-name': 'a.xlsx', authorization: `Bearer ${admin}` } });
  assert.equal(r.statusCode, 429);
  await busy.close();
});

test('CORS: only listed origins', async () => {
  const web = buildApp({ verify: createVerifier(SUPABASE_URL), withUser: db.withUser, corsOrigins: ['http://localhost:5173'] });
  const pre = (origin: string) => web.inject({ method: 'OPTIONS', url: '/imports',
    headers: { origin, 'access-control-request-method': 'POST', 'access-control-request-headers': 'authorization,content-type,x-file-name' } });
  const ok = await pre('http://localhost:5173');
  assert.equal(ok.headers['access-control-allow-origin'], 'http://localhost:5173');
  assert.match(String(ok.headers['access-control-allow-headers']), /X-File-Name/);
  assert.equal((await pre('https://evil.example')).headers['access-control-allow-origin'], undefined);
  await web.close();
});
