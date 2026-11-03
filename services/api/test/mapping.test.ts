// Column mapping (data-model-goal8.md §14): the mappers alone, then upload, templates and the download
// against the local stack.
import assert from 'node:assert/strict';
import { after, before, test } from 'node:test';
import { createVerifier } from '../src/auth.ts';
import { matchTemplate, normalise, rulesMapper, suggestMapping, templateHeaders, templateMapper, type Target, type Template } from '../src/mapping.ts';
import { openXlsx, type Row } from '../src/xlsx.ts';
import { simple } from './fixture.ts';
import { makeApp, SUPABASE_URL, TENANT_A, tokenFor } from './helpers.ts';

const t = (target: string, label: string): Target => ({ target, label, kind: 'text', required: false, category_id: null });
const catalog = [t('tag', 'Asset tag'), t('name', 'Name'), t('category', 'Category'), t('location', 'Location'),
  t('serial_number', 'Serial number'), t('model', 'Model'), t('warranty_end', 'Warranty end'), t('om_vendor', 'O&M vendor'),
  t('custom:rated_power', 'Rated power'), t('custom:model_no', 'Model')];
const suggest = (columns: string[], cat = catalog) => suggestMapping({ columns, samples: [], catalog: cat }, [rulesMapper]);

test('rules: labels, keys and synonyms; Sr. No. is ignored; each target once', async () => {
  const m = await suggest(['Sr. No.', 'Asset Code', 'Equipment Name', 'Cat', 'Plant', 'S/N', 'Wty Till', 'Rated Power', 'Tag No', 'Notes']);
  assert.deepEqual(m.map((s) => s.target),
    ['ignore', 'tag', 'name', 'category', 'location', 'serial_number', 'warranty_end', 'custom:rated_power', 'ignore', 'ignore']);
  assert.equal(normalise('O&M Vendor'), 'oandmvendor');
});

test('rules: a target the user may not set is never suggested', async () => {
  const m = await suggest(['Name', 'Cost', 'Warranty end'], catalog.filter((c) => c.target !== 'warranty_end'));
  assert.deepEqual(m.map((s) => s.target), ['name', 'ignore', 'ignore']);
});

const tpl = (id: string, headers: string[], targets: Record<string, string>, at: number): Template =>
  ({ id, name: id, headers, targets, updated_at: new Date(at) });

test('templates: apply when every non-blank header is in one; latest wins; letters do not matter', async () => {
  const a = tpl('a', ['assetname', 'grp', 'notes'], { assetname: 'name', grp: 'category' }, 1);
  const b = tpl('b', ['assetname', 'grp'], { assetname: 'name', grp: 'location' }, 2);
  assert.equal(matchTemplate(['Grp', 'Asset Name', 'Column C'], [a, b])?.id, 'b');
  assert.equal(matchTemplate(['Grp', 'Asset Name', 'Notes'], [a, b])?.id, 'a');
  assert.equal(matchTemplate(['Grp', 'Other'], [a, b]), undefined);
  const m = await suggestMapping({ columns: ['Grp', 'Asset Name', 'Serial'], samples: [], catalog }, [templateMapper(a), rulesMapper]);
  assert.deepEqual(m, [{ target: 'category', source: 'template' }, { target: 'name', source: 'template' },
    { target: 'serial_number', source: 'rules' }]);
});

test('download headers: a clashing custom label gets its key and still maps back', async () => {
  const headers = templateHeaders(catalog);
  assert.ok(headers.includes('Model [model_no]'));
  assert.deepEqual((await suggest(headers)).map((s) => s.target), catalog.map((c) => c.target));
});

// Against the local stack.
const XLSX = 'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet';
const { app, db } = makeApp();
let admin: string; // tenant_admin in A: excel_import, asset_financials view and update, coverage_contract
let plant: string; // asset manager in A: asset_financials view only
let auditor: string; // no excel_import
before(async () => {
  [admin, plant, auditor] = await Promise.all([tokenFor('admin.a@example.com', TENANT_A), tokenFor('plant.a@example.com', TENANT_A),
    tokenFor('auditor.a@example.com', TENANT_A)]);
});
after(async () => { await app.close(); await db.pool.end(); });

const upload = (body: Buffer, token: string, url = '/imports') => app.inject({
  method: 'POST', url, payload: body, headers: { 'content-type': XLSX, 'x-file-name': 'a.xlsx', authorization: `Bearer ${token}` } });
const download = (token?: string) => app.inject({ method: 'GET', url: '/imports/template',
  headers: token ? { authorization: `Bearer ${token}` } : {} });
const asUser = async <T>(token: string, fn: Parameters<typeof db.withUser<T>>[1]) =>
  db.withUser((await createVerifier(SUPABASE_URL)(token))!, fn);

async function headerRow(file: Buffer): Promise<string[]> {
  const book = await openXlsx(file);
  const first = (await book.rows(book.sheets[0]!, () => {}).next()).value as Row;
  return first.cells.map(String);
}

test('upload suggests a mapping and stores it on the staged batch', async () => {
  const r = await upload(simple([['Sr No', 'Asset Name', 'Category', 'Cost'], [1, 'Pump', 'PUMP', 100]]), admin);
  assert.equal(r.statusCode, 201, r.body);
  assert.deepEqual(r.json().mapping.map((s: { target: string }) => s.target), ['ignore', 'name', 'category', 'purchase_value']);
  const batch = await asUser(admin, async (q) => (await q('select status, mapping from public.import_batch where id = $1', [r.json().batch_id])).rows[0]!);
  assert.equal(batch.status, 'staged');
  assert.equal(batch.mapping[3].target, 'purchase_value');
  // The asset manager may see purchase value but not set it: not suggested.
  const p = await upload(simple([['Asset Name', 'Cost'], ['Pump', 100]]), plant);
  assert.deepEqual(p.json().mapping.map((s: { target: string }) => s.target), ['name', 'ignore']);
});

test('a saved template applies by itself to the next file with the same headers', async () => {
  const id = await asUser(admin, async (q) => (await q<{ id: string }>(
    `insert into public.import_mapping_template (tenant_id, name, headers, targets)
     values (private.current_tenant_id(), 'mapping test ' || gen_random_uuid(), '{grp,machine}', '{"grp": "category", "machine": "name"}') returning id`)).rows[0]!.id);
  const r = await upload(simple([['Machine', 'Grp'], ['Lathe', 'CNC']]), admin);
  assert.equal(r.json().mapping_template_id, id);
  assert.deepEqual(r.json().mapping, [{ target: 'name', source: 'template' }, { target: 'category', source: 'template' }]);
  await asUser(admin, (q) => q('update public.import_mapping_template set deleted_at = now() where id = $1', [id]));
});

test('header row override (M10): ?header_row=N, else 400', async () => {
  const file = simple([['Asset register'], ['Name', 'Category'], ['Pump', 'PUMP']]);
  assert.equal((await upload(file, admin)).json().header_row, 2);
  const r = await upload(file, admin, '/imports?header_row=1');
  assert.equal(r.json().header_row, 1);
  assert.equal(r.json().row_count, 2);
  for (const bad of ['0', '21', 'x', '5']) {
    const b = await upload(file, admin, `/imports?header_row=${bad}`);
    assert.equal(b.statusCode, 400, bad);
    assert.deepEqual(b.json(), { error: 'bad_header_row' });
  }
});

test('download template: one header per settable field; uploading it back maps every column', async () => {
  assert.equal((await download()).statusCode, 401);
  assert.equal((await download(auditor)).statusCode, 403);
  const r = await download(admin);
  assert.equal(r.statusCode, 200);
  assert.equal(r.headers['content-type'], XLSX);
  const headers = await headerRow(r.rawPayload);
  assert.ok(headers.includes('Purchase value') && headers.includes('Warranty end'));
  const up = await upload(r.rawPayload, admin); // our own file, read back by our own reader
  assert.equal(up.statusCode, 201, up.body);
  assert.ok(up.json().mapping.every((s: { target: string }) => s.target !== 'ignore'));
  assert.ok(!(await headerRow((await download(plant)).rawPayload)).includes('Purchase value'));
});
