-- Story 8.4: validation and dry run (docs/data-model-goal8.md §15).
-- Seed: tenant A active (date format dd-MM-yyyy, INR), B read_only; a1 in A and B.
begin;
select plan(38);

-- Master data in A: categories, a location tree with two "Bay 3", vendors, a list field, an existing asset.
insert into public.asset_category (id, tenant_id, name, code) values
  ('00000000-0000-0000-0000-0000000084c1', '00000000-0000-0000-0000-00000000000a', 'Compressors', 'CMP'),
  ('00000000-0000-0000-0000-0000000084c2', '00000000-0000-0000-0000-00000000000a', 'Pumps 84', null);
insert into public.location (id, tenant_id, parent_id, name, code) values
  ('00000000-0000-0000-0000-0000000084e1', '00000000-0000-0000-0000-00000000000a', null, 'Plant 2', 'P2'),
  ('00000000-0000-0000-0000-0000000084e3', '00000000-0000-0000-0000-00000000000a', null, 'Plant 9', 'P9');
insert into public.location (id, tenant_id, parent_id, name) values
  ('00000000-0000-0000-0000-0000000084e2', '00000000-0000-0000-0000-00000000000a', '00000000-0000-0000-0000-0000000084e1', 'Bay 3'),
  ('00000000-0000-0000-0000-0000000084e4', '00000000-0000-0000-0000-00000000000a', '00000000-0000-0000-0000-0000000084e3', 'Bay 3');
insert into public.vendor (id, tenant_id, name, code, roles) values
  ('00000000-0000-0000-0000-0000000084f1', '00000000-0000-0000-0000-00000000000a', 'Atlas Copco 84', 'ATL84', '{oem}'),
  ('00000000-0000-0000-0000-0000000084f2', '00000000-0000-0000-0000-00000000000a', 'Other Co 84', 'OTH84', '{oem}');
update public.asset_category set oem_vendor_ids = '{00000000-0000-0000-0000-0000000084f1}'
where id = '00000000-0000-0000-0000-0000000084c1';
insert into public.field_definition (tenant_id, entity, key, label, type, options, security_domain_id, category_id)
select '00000000-0000-0000-0000-00000000000a', 'asset', 'fuel84', 'Fuel', 'list',
       '[{"code":"diesel","label":"Diesel"},{"code":"electric","label":"Electric"}]', d.id,
       '00000000-0000-0000-0000-0000000084c1'
from public.security_domain d where d.code = 'asset_core';
insert into public.asset (id, tenant_id, tag, name, category_id, serial_number, manufacturer) values
  ('00000000-0000-0000-0000-0000000084a1', '00000000-0000-0000-0000-00000000000a', 'EX-84', 'Existing', '00000000-0000-0000-0000-0000000084c1', 'SX84', 'Atlas');

-- Batches: one mapped in A, one in B. Columns and mapping as the Mapping step would save them.
create function pg_temp.batch(p_id text, p_tenant text, p_rows int) returns void language sql as $$
  insert into public.import_batch (id, tenant_id, file_name, file_size, file_sha256, sheet_name, sheet_names, header_row,
                                   columns, row_count, status, mapping)
  select p_id::uuid, p_tenant::uuid, 'assets.xlsx', 100, repeat('a', 64), 'Sheet1', '{Sheet1}', 1,
         array_agg(t order by n), p_rows, 'mapped',
         jsonb_agg(jsonb_build_object('target', t, 'source', 'rules') order by n)
  from unnest(array['tag', 'name', 'category', 'location', 'status', 'quantity', 'purchase_date', 'purchase_value',
                    'purchase_currency', 'oem_vendor', 'warranty_start', 'warranty_end', 'custom:fuel84',
                    'serial_number', 'manufacturer']) with ordinality as x (t, n);
$$;
create function pg_temp.row(p_batch text, p_tenant text, p_n int, p_cells jsonb) returns void language sql as $$
  insert into public.import_row (tenant_id, batch_id, row_number, cells) values (p_tenant::uuid, p_batch::uuid, p_n, p_cells);
$$;
create function pg_temp.codes(p_n int) returns text[] language sql as $$
  select coalesce(array_agg(m ->> 'code' order by m ->> 'code'), '{}')
  from public.import_row r, jsonb_array_elements(coalesce(r.messages, '[]')) m
  where r.batch_id = '00000000-0000-0000-0000-0000000084b1' and r.row_number = p_n;
$$;
grant execute on function pg_temp.codes(int) to authenticated;
create function pg_temp.res(p_n int) returns text language sql as $$
  select result from public.import_row where batch_id = '00000000-0000-0000-0000-0000000084b1' and row_number = p_n;
$$;
grant execute on function pg_temp.res(int) to authenticated;

select pg_temp.batch('00000000-0000-0000-0000-0000000084b1', '00000000-0000-0000-0000-00000000000a', 13);
select pg_temp.batch('00000000-0000-0000-0000-0000000084bb', '00000000-0000-0000-0000-00000000000b', 0);
select pg_temp.row('00000000-0000-0000-0000-0000000084b1', '00000000-0000-0000-0000-00000000000a', n, c::jsonb)
from (values
  -- tag, name, category, location, status, qty, purchase date, value, currency, oem, w start, w end, fuel, serial, make
  (2,  '[null,"Compressor 1","CMP","P2","Active",2,"03-11-2026",120000,"inr","atl84",45000,"2027-11-03","Diesel","S1","Atlas"]'),
  (3,  '["","Compressor 2","compressors","plant 2/bay 3",null,null,null,"1,20,000",null,null,null,null,null,null,null]'),
  (4,  '[null,"Bad","Nope",null,null,0,"31-02-2026",null,null,null,null,null,null,null,null]'),
  (5,  '[null,"Amb","CMP","Bay 3",null,null,null,null,null,null,"2026-01-01",null,null,null,null]'),
  (6,  '["t-1","Dup A","CMP",null,null,null,null,null,null,null,null,null,null,null,null]'),
  (7,  '["T-1","Dup B","CMP",null,null,null,null,null,null,null,null,null,null,null,null]'),
  (8,  '["ex-84","Exists","CMP",null,null,null,null,null,null,null,null,null,null,null,null]'),
  (9,  '[null,"  ","CMP",null,"Disposed",null,null,null,null,null,null,null,"Petrol",null,null]'),
  (10, '[null,"Maybe dup","CMP",null,null,null,null,null,null,null,null,null,null,"sx84","atlas"]'),
  (11, '[null,"Wrong vendor","CMP",null,null,null,null,null,null,"Other Co 84",null,null,null,null,null]'),
  (12, '[null,"Pump","Pumps 84",null,null,null,null,null,null,null,null,null,"Diesel",null,null]'),
  (13, '[null,"No vendor","CMP",null,null,null,null,null,null,null,"2026-01-01","2025-01-01",null,null,null]'),
  (14, '[null,"Old style",null,null,null,"3",null,null,null,null,null,null,null,null,null]')
) as x (n, c);

-- Default deny, then a read-only tenant.
select tests.act_as('00000000-0000-0000-0000-0000000000a1', '00000000-0000-0000-0000-00000000000a');
select throws_ok($$select public.import_validate('00000000-0000-0000-0000-0000000084b1')$$, '42501', null, 'no grant: cannot validate');
reset role;
select tests.grant('00000000-0000-0000-0000-00000000000b', '00000000-0000-0000-0000-0000000000a1', 'excel_import', '{run}');
select tests.act_as('00000000-0000-0000-0000-0000000000a1', '00000000-0000-0000-0000-00000000000b');
select throws_ok($$select public.import_validate('00000000-0000-0000-0000-0000000084bb')$$, '42501', null, 'read-only tenant: cannot validate');

-- run in A, create scoped to Compressors (6.1), everything else unscoped.
reset role;
select tests.grant('00000000-0000-0000-0000-00000000000a', '00000000-0000-0000-0000-0000000000a1', 'excel_import', '{run}');
select tests.grant('00000000-0000-0000-0000-00000000000a', '00000000-0000-0000-0000-0000000000a1', 'asset_core', '{view,update,set_tag}');
select tests.grant('00000000-0000-0000-0000-00000000000a', '00000000-0000-0000-0000-0000000000a1', 'asset_financials', '{view,update}');
select tests.grant('00000000-0000-0000-0000-00000000000a', '00000000-0000-0000-0000-0000000000a1', 'coverage_contract', '{create}');
insert into public.scope_profile (id, tenant_id, name) values
  ('00000000-0000-0000-0000-0000000084f9', '00000000-0000-0000-0000-00000000000a', 'Compressors only');
insert into public.scope_profile_rule (tenant_id, scope_profile_id, dimension, category_id) values
  ('00000000-0000-0000-0000-00000000000a', '00000000-0000-0000-0000-0000000084f9', 'category', '00000000-0000-0000-0000-0000000084c1');
select tests.grant('00000000-0000-0000-0000-00000000000a', '00000000-0000-0000-0000-0000000000a1', 'asset_core', '{create}');
select tests.grant('00000000-0000-0000-0000-00000000000a', '00000000-0000-0000-0000-0000000000a1', 'coverage_contract', '{create}');
update public.user_group_assignment set scope_profile_id = '00000000-0000-0000-0000-0000000084f9'
where id = (select a.id from public.user_group_assignment a
            join public.group_domain_policy p on p.security_group_id = a.security_group_id
            join public.domain_operation o on o.id = p.domain_operation_id
            where a.user_id = '00000000-0000-0000-0000-0000000000a1' and o.code = 'create'
              and o.security_domain_id = (select id from public.security_domain where code = 'asset_core'));

select tests.act_as('00000000-0000-0000-0000-0000000000a1', '00000000-0000-0000-0000-00000000000a');
select throws_ok($$select public.import_validate('00000000-0000-0000-0000-0000000084bb')$$, 'P0002', null, 'another tenant''s batch: not found');
select lives_ok($$select public.import_validate('00000000-0000-0000-0000-0000000084b1')$$, 'run: validates');

select is(pg_temp.res(2), 'ok', 'row 2 ok');
select is(pg_temp.codes(2), '{}', 'row 2 no messages');
select is(pg_temp.codes(3), '{currency_defaulted}', 'row 3: category by name, location by path, value with commas, currency defaulted');
select is(pg_temp.res(3), 'warning', 'row 3 warning');
select is(pg_temp.codes(4), '{date_format,not_found,number_format}', 'row 4: unknown category, 31 Feb, quantity 0');
select is(pg_temp.codes(5), '{ambiguous,warranty_incomplete}', 'row 5: two Bay 3, warranty end missing');
select is(pg_temp.codes(6), '{duplicate_in_file}', 'row 6: tag twice in the file (any case)');
select is(pg_temp.codes(7), '{duplicate_in_file}', 'row 7: the other one');
select is(pg_temp.codes(8), '{tag_exists}', 'row 8: tag of a live asset');
select is(pg_temp.codes(9), '{bad_option,required,status_not_allowed}', 'row 9: blank name, disposed status, unknown option');
select is(pg_temp.codes(10), '{possible_duplicate}', 'row 10: serial and make of a live asset');
select is(pg_temp.res(10), 'warning', 'row 10 is a warning, not an error');
select is(pg_temp.codes(11), '{vendor_not_for_category}', 'row 11: vendor not tagged to the category');
select is(pg_temp.codes(12), '{not_for_category,out_of_scope}', 'row 12: field of another category, outside the create scope');
select is(pg_temp.codes(13), '{warranty_dates,warranty_vendor}', 'row 13: end before start, no vendor');
select is(pg_temp.codes(14), '{required}', 'row 14: category required');

-- The payload 8.6 inserts.
select is((select payload from public.import_row where batch_id = '00000000-0000-0000-0000-0000000084b1' and row_number = 2),
  jsonb_build_object(
    'asset', jsonb_build_object('name', 'Compressor 1', 'category_id', '00000000-0000-0000-0000-0000000084c1',
      'location_id', '00000000-0000-0000-0000-0000000084e1',
      'status_id', (select id from public.asset_status where tenant_id = '00000000-0000-0000-0000-00000000000a' and code = 'active'),
      'quantity', 2, 'serial_number', 'S1', 'manufacturer', 'Atlas', 'purchase_date', '2026-11-03', 'purchase_value', 120000,
      'purchase_currency', 'INR', 'oem_vendor_id', '00000000-0000-0000-0000-0000000084f1', 'custom_values', '{"fuel84": "diesel"}'::jsonb),
    'coverage', jsonb_build_object('coverage_type', 'warranty', 'vendor_id', '00000000-0000-0000-0000-0000000084f1',
      'start_date', '2023-03-15', 'end_date', '2027-11-03')),
  'row 2 payload: ids resolved, Excel serial date, option code, warranty line');
select is((select payload -> 'asset' ->> 'location_id' from public.import_row
           where batch_id = '00000000-0000-0000-0000-0000000084b1' and row_number = 3),
  '00000000-0000-0000-0000-0000000084e2', 'row 3: location found by path');
select ok((select payload is null from public.import_row
           where batch_id = '00000000-0000-0000-0000-0000000084b1' and row_number = 4), 'error rows have no payload');
select is((select messages from public.import_row where batch_id = '00000000-0000-0000-0000-0000000084b1' and row_number = 4),
  '[{"col": 2, "code": "not_found"}, {"col": 5, "code": "number_format", "params": {"min": 1, "integer": true}}, {"col": 6, "code": "date_format", "params": {"format": "dd-MM-yyyy"}}]',
  'messages: column index and fixed params, no cell text');

-- Summary and status.
select is((select status from public.import_batch where id = '00000000-0000-0000-0000-0000000084b1'), 'validated', 'batch validated');
select is((select summary - 'validated_at' - 'codes' from public.import_batch where id = '00000000-0000-0000-0000-0000000084b1'),
  '{"ok": 1, "warning": 2, "error": 10, "skip": 10, "create_assets": 3, "create_coverages": 1, "as_user": "00000000-0000-0000-0000-0000000000a1"}',
  'summary: counts and dry run');
select is((select (summary -> 'codes' ->> 'duplicate_in_file')::int from public.import_batch
           where id = '00000000-0000-0000-0000-0000000084b1'), 2, 'summary counts each code');
select is((select count(*)::int from public.asset where tenant_id = '00000000-0000-0000-0000-00000000000a' and name in ('Compressor 1', 'Compressor 2')),
  0, 'dry run: no asset written');

-- Tag pattern needs a code (3.8); rights read at run time.
reset role;
update public.tenant set asset_tag_pattern = '{CAT}-{SEQ:4}' where id = '00000000-0000-0000-0000-00000000000a';
select tests.act_as('00000000-0000-0000-0000-0000000000a1', '00000000-0000-0000-0000-00000000000a');
select public.import_validate('00000000-0000-0000-0000-0000000084b1');
select ok('tag_needs_category_code' = any (pg_temp.codes(12)), 'pattern with {CAT}: a category without a code is an error');
select is(pg_temp.res(2), 'ok', 'pattern with {CAT}: Compressors has a code');

-- V8: saving the mapping again makes the batch mapped and drops the summary.
select lives_ok($$select public.import_save_mapping('00000000-0000-0000-0000-0000000084b1',
  (select mapping from public.import_batch where id = '00000000-0000-0000-0000-0000000084b1'))$$, 'save a validated batch');
select is((select status || coalesce(summary::text, '-') from public.import_batch where id = '00000000-0000-0000-0000-0000000084b1'),
  'mapped-', 'save: mapped, no summary');

-- A staged batch cannot be validated; review may validate (V12).
reset role;
insert into public.import_batch (id, tenant_id, file_name, file_size, file_sha256, sheet_name, sheet_names, header_row, columns, row_count)
values ('00000000-0000-0000-0000-0000000084b2', '00000000-0000-0000-0000-00000000000a', 'x.xlsx', 1, repeat('a', 64), 'S', '{S}', 1, '{A}', 0);
select tests.act_as('00000000-0000-0000-0000-0000000000a1', '00000000-0000-0000-0000-00000000000a');
select throws_ok($$select public.import_validate('00000000-0000-0000-0000-0000000084b2')$$, '22023', 'batch is staged', 'staged: map first');

-- No create right: every row is an error.
reset role;
delete from public.user_group_assignment
where user_id = '00000000-0000-0000-0000-0000000000a1' and tenant_id = '00000000-0000-0000-0000-00000000000a';
select tests.grant('00000000-0000-0000-0000-00000000000a', '00000000-0000-0000-0000-0000000000a1', 'excel_import', '{review}');
select tests.grant('00000000-0000-0000-0000-00000000000a', '00000000-0000-0000-0000-0000000000a1', 'asset_core', '{view,update}');
select tests.grant('00000000-0000-0000-0000-00000000000a', '00000000-0000-0000-0000-0000000000a1', 'asset_financials', '{view,update}');
update public.import_batch set mapping = (select jsonb_agg(case when e ->> 'target' in ('warranty_start', 'warranty_end', 'tag')
                                                                then '{"target":"ignore","source":"user"}'::jsonb else e end order by n)
                                           from jsonb_array_elements(mapping) with ordinality x (e, n))
where id = '00000000-0000-0000-0000-0000000084b1';
select tests.act_as('00000000-0000-0000-0000-0000000000a1', '00000000-0000-0000-0000-00000000000a');
select lives_ok($$select public.import_validate('00000000-0000-0000-0000-0000000084b1')$$, 'review: validates');
select is((select (summary ->> 'error')::int from public.import_batch where id = '00000000-0000-0000-0000-0000000084b1'), 13,
  'no asset_core.create: every row is an error');
select is(pg_temp.codes(2), '{no_create_right}', 'row 2: no create right');

-- 20,000 rows inside the 8 s statement timeout of the web role (V1, §15.4).
reset role;
update public.tenant set asset_tag_pattern = 'AST-{SEQ:5}' where id = '00000000-0000-0000-0000-00000000000a';
select tests.grant('00000000-0000-0000-0000-00000000000a', '00000000-0000-0000-0000-0000000000a1', 'asset_core', '{create}');
select tests.grant('00000000-0000-0000-0000-00000000000a', '00000000-0000-0000-0000-0000000000a1', 'coverage_contract', '{create}');
select pg_temp.batch('00000000-0000-0000-0000-0000000084b3', '00000000-0000-0000-0000-00000000000a', 20000);
insert into public.import_row (tenant_id, batch_id, row_number, cells)
select '00000000-0000-0000-0000-00000000000a', '00000000-0000-0000-0000-0000000084b3', n + 1,
       jsonb_build_array(null, 'Machine ' || n, case when n % 2 = 0 then 'CMP' else 'Compressors' end,
                         case when n % 3 = 0 then 'P2' else 'Plant 2 / Bay 3' end, 'Active', 1,
                         '0' || (1 + n % 9) || '-0' || (1 + n % 9) || '-2025', (n * 10)::text, 'INR', 'ATL84',
                         '2025-01-01', '2028-01-01', case when n % 2 = 0 then 'Diesel' else 'electric' end,
                         'SN-' || n, 'Atlas')
from generate_series(1, 20000) n;
create temp table t0 as select clock_timestamp() as t;
grant select on t0 to authenticated;
select tests.act_as('00000000-0000-0000-0000-0000000000a1', '00000000-0000-0000-0000-00000000000a');
select is((public.import_validate('00000000-0000-0000-0000-0000000084b3') ->> 'ok')::int, 20000, '20,000 rows all ok');
select cmp_ok(extract(epoch from clock_timestamp() - (select t from t0)), '<', 8::numeric, '20,000 rows validate inside the 8 s web statement timeout');

select * from finish();
rollback;
