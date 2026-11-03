// Template drop-downs (data-model-goal8.md §16) against the local stack: the lists hold what the user may see.
import assert from 'node:assert/strict';
import { after, before, test } from 'node:test';
import pg from 'pg';
import yauzl from 'yauzl';
import { createVerifier } from '../src/auth.ts';
import type { Query } from '../src/db.ts';
import { templateLists, templateXlsx, LIST_CAP, type Target } from '../src/mapping.ts';
import { simple } from './fixture.ts';
import { makeApp, SUPABASE_URL, TENANT_A, TENANT_B, tokenFor } from './helpers.ts';

const XLSX = 'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet';
// Superuser, only to take one right away inside a transaction that is always rolled back.
const ADMIN_DATABASE_URL = process.env.ADMIN_DATABASE_URL ?? 'postgres://postgres:postgres@127.0.0.1:54322/postgres';
const PLANT_A = '00000000-0000-0000-0000-0000000a0002';

const { app, db } = makeApp();
const verify = createVerifier(SUPABASE_URL);
let admin: string; // tenant_admin in A
let plant: string; // asset manager in A
let adminB: string; // tenant_admin in B
const s = Math.random().toString(36).slice(2, 8); // names unique per run
const cat = { parent: `T83b Utilities ${s}`, child: `T83b Compressor ${s}`, off: `T83b Old ${s}` };
const loc = { parent: `T83b Plant ${s}`, child: `T83b Bay ${s}` };
const vendor = { oem: `T83b Atlas ${s}`, om: `T83b Service Co ${s}` };
const key = `t83b_${s}`;

const asUser = async <T>(token: string, fn: (q: Query) => Promise<T>) => db.withUser((await verify(token))!, fn);
const download = (token: string) => app.inject({ method: 'GET', url: '/imports/template', headers: { authorization: `Bearer ${token}` } });

before(async () => {
  [admin, plant, adminB] = await Promise.all([tokenFor('admin.a@example.com', TENANT_A), tokenFor('plant.a@example.com', TENANT_A),
    tokenFor('admin.b@example.com', TENANT_B)]);
  await asUser(admin, async (q) => {
    const id = async (sql: string, v: unknown[]) => (await q<{ id: string }>(sql, v)).rows[0]!.id;
    const p = await id('insert into public.asset_category (tenant_id, name) values (private.current_tenant_id(), $1) returning id', [cat.parent]);
    await q('insert into public.asset_category (tenant_id, name, parent_id) values (private.current_tenant_id(), $1, $2)', [cat.child, p]);
    await q('insert into public.asset_category (tenant_id, name, is_active) values (private.current_tenant_id(), $1, false)', [cat.off]);
    const l = await id('insert into public.location (tenant_id, name) values (private.current_tenant_id(), $1) returning id', [loc.parent]);
    await q('insert into public.location (tenant_id, name, parent_id) values (private.current_tenant_id(), $1, $2)', [loc.child, l]);
    await q(`insert into public.vendor (tenant_id, name, roles) values (private.current_tenant_id(), $1, '{oem}'),
             (private.current_tenant_id(), $2, '{om}')`, [vendor.oem, vendor.om]);
    await q(`insert into public.field_definition (tenant_id, entity, key, label, type, options, security_domain_id)
             values (private.current_tenant_id(), 'asset', $1, $2, 'list', $3,
                     (select id from public.security_domain where code = 'asset_core'))`,
    [key, `T83b Duty ${s}`, JSON.stringify([{ code: 'cont', label: 'Continuous' }, { code: 'old', label: 'Retired duty', is_active: false },
      { code: 'stby', label: 'Standby' }])]);
  });
});

after(async () => {
  await asUser(admin, async (q) => {
    // Deactivate, never delete (CLAUDE.md §8); children first.
    await q('update public.asset_category set is_active = false where name = any ($1)', [[cat.child, cat.parent]]);
    await q('update public.location set active = false where name = $1', [loc.child]);
    await q('update public.location set active = false where name = $1', [loc.parent]);
    await q('update public.vendor set is_active = false where name like $1', [`T83b % ${s}`]);
    await q('update public.field_definition set is_active = false where key = $1', [key]);
  });
  await app.close();
  await db.pool.end();
});

// The parts of a zip as text (the reader in src/xlsx.ts skips hidden sheets, so tests read the XML).
function parts(buf: Buffer): Promise<Record<string, string>> {
  return new Promise((ok, ko) => yauzl.fromBuffer(buf, { lazyEntries: true }, (e, z) => {
    if (e) return ko(e);
    const out: Record<string, string> = {};
    z.on('entry', (entry: yauzl.Entry) => z.openReadStream(entry, (err, st) => {
      if (err) return ko(err);
      const chunks: Buffer[] = [];
      st.on('data', (c: Buffer) => chunks.push(c)).on('end', () => { out[entry.fileName] = Buffer.concat(chunks).toString(); z.readEntry(); });
    }));
    z.on('end', () => ok(out));
    z.readEntry();
  }));
}

const unesc = (x: string) => x.replace(/&lt;/g, '<').replace(/&gt;/g, '>').replace(/&quot;/g, '"').replace(/&amp;/g, '&');

// Lists sheet as { header: values }.
async function listsOf(file: Buffer): Promise<Record<string, string[]>> {
  const xml = (await parts(file))['xl/worksheets/sheet2.xml']!;
  const cols: Record<string, string[]> = {};
  for (const m of xml.matchAll(/<c r="([A-Z]+)\d+"[^>]*><is><t[^>]*>([^<]*)<\/t>/g)) (cols[m[1]!] ??= []).push(unesc(m[2]!));
  return Object.fromEntries(Object.values(cols).map(([head, ...values]) => [head!, values]));
}

test('lists: tenant values as 8.4 accepts them; inactive and deleted left out; hidden sheet; checks on columns', async () => {
  const r = await download(admin);
  assert.equal(r.statusCode, 200, r.body);
  const lists = await listsOf(r.rawPayload);
  assert.ok(lists['Category']!.includes(cat.parent));
  assert.ok(lists['Category']!.includes(`${cat.parent} / ${cat.child}`), 'path');
  assert.ok(!lists['Category']!.some((v) => v.includes(cat.off)), 'inactive');
  assert.ok(lists['Location']!.includes(`${loc.parent} / ${loc.child}`));
  assert.deepEqual(lists['Status'], ['Active', 'In Stock']);
  assert.ok(lists['OEM vendor']!.includes(vendor.oem) && !lists['OEM vendor']!.includes(vendor.om), 'by role');
  assert.ok(lists['O&M vendor']!.includes(vendor.om) && !lists['O&M vendor']!.includes(vendor.oem));
  assert.deepEqual(lists['Criticality'], ['A', 'B', 'C']);
  assert.deepEqual(lists[`T83b Duty ${s}`], ['Continuous', 'Standby'], 'active options in order');

  const p = await parts(r.rawPayload);
  assert.match(p['xl/workbook.xml']!, /<sheet name="Lists" sheetId="2" state="hidden"/);
  const sheet = p['xl/worksheets/sheet1.xml']!;
  assert.match(sheet, /<dataValidation type="list" errorStyle="warning"[^>]*sqref="C2:C20001"><formula1>Lists!\$A\$2:\$A\$\d+<\/formula1>/);
  assert.match(sheet, /type="whole" operator="greaterThanOrEqual"[^>]*><formula1>1</);
  assert.match(sheet, /type="date"/);
  assert.match(p['xl/styles.xml']!, /formatCode="dd-mm-yyyy"/); // tenant A's date format
});

test('a user who lacks a right gets no list for it; the other lists stay', async () => {
  const claims = (await verify(plant))!;
  const c = new pg.Client({ connectionString: ADMIN_DATABASE_URL });
  await c.connect();
  try {
    await c.query('begin');
    await c.query(`delete from private.user_effective_permission u using public.domain_operation o, public.security_domain d
                   where u.domain_operation_id = o.id and o.security_domain_id = d.id and d.code = 'location_hierarchy'
                     and u.user_id = $1 and u.tenant_id = $2`, [PLANT_A, TENANT_A]);
    await c.query("select set_config('role', 'authenticated', true), set_config('request.jwt.claims', $1, true)", [JSON.stringify(claims)]);
    const { lists } = await templateLists((text, values) => c.query(text, values));
    assert.equal(lists['location'], undefined);
    assert.ok(lists['category']!.includes(cat.parent));
    const xml = (await parts(templateXlsx([{ target: 'location', label: 'Location', kind: 'location', required: false, category_id: null }], lists)))['xl/worksheets/sheet1.xml']!;
    assert.doesNotMatch(xml, /dataValidation/, 'no drop-down without values');
  } finally {
    await c.query('rollback');
    await c.end();
  }
});

test('another tenant sees none of these values', async () => {
  const lists = await listsOf((await download(adminB)).rawPayload);
  assert.ok(!Object.values(lists).flat().some((v) => v.includes(s)));
});

test('a list over the cap gets no drop-down', async () => {
  const t: Target = { target: 'category', label: 'Category', kind: 'category', required: false, category_id: null };
  const many = Array.from({ length: LIST_CAP + 1 }, (_, i) => `c${i}`);
  assert.doesNotMatch((await parts(templateXlsx([t], { category: many })))['xl/worksheets/sheet1.xml']!, /dataValidation/);
  assert.match((await parts(templateXlsx([t], { category: many.slice(1) })))['xl/worksheets/sheet1.xml']!, /dataValidation/);
});

test('values picked from the lists come back through upload and 8.4 with no lookup errors', async () => {
  const file = (await download(admin)).rawPayload;
  const lists = await listsOf(file);
  const row: Record<string, string> = {
    Name: 'T83b pump', Category: `${cat.parent} / ${cat.child}`, Location: `${loc.parent} / ${loc.child}`, Status: 'In Stock',
    'OEM vendor': vendor.oem, 'O&M vendor': vendor.om, Criticality: 'B', [`T83b Duty ${s}`]: 'Standby',
  };
  for (const [h, v] of Object.entries(row)) if (h !== 'Name') assert.ok(lists[h]!.includes(v), h);
  const up = await app.inject({ method: 'POST', url: '/imports', payload: simple([Object.keys(row), Object.values(row)]),
    headers: { 'content-type': XLSX, 'x-file-name': 'a.xlsx', authorization: `Bearer ${admin}` } });
  assert.equal(up.statusCode, 201, up.body);
  const codes = await asUser(admin, async (q) => {
    await q('select public.import_save_mapping($1, $2)', [up.json().batch_id, JSON.stringify(up.json().mapping)]);
    await q('select public.import_validate($1)', [up.json().batch_id]);
    return (await q<{ code: string }>(`select m ->> 'code' as code from public.import_row r, jsonb_array_elements(r.messages) m
                                       where r.batch_id = $1`, [up.json().batch_id])).rows.map((x) => x.code);
  });
  assert.ok(!codes.some((c) => ['not_found', 'ambiguous', 'bad_option'].includes(c)), codes.join(','));
});
