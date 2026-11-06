-- Story 10.4: import_decide_values and import_validate reading accepted matches (docs/data-model-goal10.md §4.2).
-- Seed: tenant A active, B read_only; a1 in A and B.
begin;
select plan(17);

insert into public.asset_category (id, tenant_id, name) values
  ('00000000-0000-0000-0000-0000000104c1', '00000000-0000-0000-0000-00000000000a', 'Air compressor 104');
insert into public.location (id, tenant_id, parent_id, name) values
  ('00000000-0000-0000-0000-0000000104e1', '00000000-0000-0000-0000-00000000000a', null, 'Plant 2 Nashik 104');
insert into public.vendor (id, tenant_id, name, roles) values
  ('00000000-0000-0000-0000-0000000104f1', '00000000-0000-0000-0000-00000000000a', 'Siemens India 104', '{oem}'),
  ('00000000-0000-0000-0000-0000000104fb', '00000000-0000-0000-0000-00000000000b', 'Siemens B 104', '{oem}');
update public.asset_category set oem_vendor_ids = '{00000000-0000-0000-0000-0000000104f1}'
where id = '00000000-0000-0000-0000-0000000104c1';
insert into public.import_batch (id, tenant_id, file_name, file_size, file_sha256, sheet_name, sheet_names, header_row,
                                 columns, row_count, status, mapping)
values ('00000000-0000-0000-0000-0000000104b1', '00000000-0000-0000-0000-00000000000a', 'messy.xlsx', 100, repeat('a', 64),
        'Sheet1', '{Sheet1}', 1, '{Name,Cat,Plnt,Make}', 3, 'mapped',
        '[{"target":"name","source":"rules"},{"target":"category","source":"ai"},{"target":"location","source":"ai"},{"target":"oem_vendor","source":"ai"}]'),
       ('00000000-0000-0000-0000-0000000104bb', '00000000-0000-0000-0000-00000000000b', 'b.xlsx', 100, repeat('a', 64),
        'Sheet1', '{Sheet1}', 1, '{Name}', 0, 'mapped', '[{"target":"name","source":"rules"}]');
insert into public.import_row (tenant_id, batch_id, row_number, cells) values
  ('00000000-0000-0000-0000-00000000000a', '00000000-0000-0000-0000-0000000104b1', 2, '["Comp 1","Comprsr","Plnt-2 Nsk","Siemens Ind."]'),
  ('00000000-0000-0000-0000-00000000000a', '00000000-0000-0000-0000-0000000104b1', 3, '["Comp 2"," Comprsr","Plnt-2 Nsk",null]'),
  ('00000000-0000-0000-0000-00000000000a', '00000000-0000-0000-0000-0000000104b1', 4, '["Comp 3","Comprsr",null,"Siemens Ind."]');
create function pg_temp.codes() returns text[] language sql as $$
  select coalesce(array_agg(distinct m ->> 'code'), '{}')
  from public.import_row r, jsonb_array_elements(coalesce(r.messages, '[]')) m
  where r.batch_id = '00000000-0000-0000-0000-0000000104b1';
$$;
grant execute on function pg_temp.codes() to authenticated;

-- excel_import.run alone may validate but not decide.
select tests.grant('00000000-0000-0000-0000-00000000000a', '00000000-0000-0000-0000-0000000000a1', 'excel_import', '{run}');
select tests.grant('00000000-0000-0000-0000-00000000000a', '00000000-0000-0000-0000-0000000000a1', 'asset_core', '{view,create}');
select tests.act_as('00000000-0000-0000-0000-0000000000a1', '00000000-0000-0000-0000-00000000000a');
select lives_ok($$select public.import_validate('00000000-0000-0000-0000-0000000104b1')$$, 'validate runs');
select is(pg_temp.codes(), '{not_found}', 'the odd values are not found');
select throws_ok($$select public.import_decide_values('00000000-0000-0000-0000-0000000104b1',
  '[{"column":"category","raw":"Comprsr","target_id":"00000000-0000-0000-0000-0000000104c1","status":"accepted"}]')$$,
  '42501', null, 'no excel_import.review: cannot decide');

reset role;
select tests.grant('00000000-0000-0000-0000-00000000000a', '00000000-0000-0000-0000-0000000000a1', 'excel_import', '{review}');
select tests.grant('00000000-0000-0000-0000-00000000000a', '00000000-0000-0000-0000-0000000000a1', 'category_config', '{view}');
select tests.grant('00000000-0000-0000-0000-00000000000a', '00000000-0000-0000-0000-0000000000a1', 'location_hierarchy', '{view}');
select tests.act_as('00000000-0000-0000-0000-0000000000a1', '00000000-0000-0000-0000-00000000000a');

select throws_ok($$select public.import_decide_values('00000000-0000-0000-0000-0000000104b1',
  '[{"column":"criticality","raw":"x","target_id":"00000000-0000-0000-0000-0000000104c1","status":"accepted"}]')$$,
  '22023', 'decisions: each entry needs column, raw, target_id and status', 'only category, location, vendor, status');
select throws_ok($$select public.import_decide_values('00000000-0000-0000-0000-0000000104b1',
  '[{"column":"category","raw":"Comprsr","target_id":"00000000-0000-0000-0000-0000000104c1","status":"accepted","confidence":2}]')$$,
  '22023', 'decisions: confidence is a number from 0 to 1', 'confidence 0 to 1');
select throws_ok($$select public.import_decide_values('00000000-0000-0000-0000-0000000104b1',
  '[{"column":"category","raw":"Comprsr","target_id":"00000000-0000-0000-0000-0000000104c1","status":"accepted"},
    {"column":"category","raw":"Comprsr","target_id":"00000000-0000-0000-0000-0000000104c1","status":"rejected"}]')$$,
  '22023', 'decisions: a value is decided twice', 'one decision per value');
select throws_ok($$select public.import_decide_values('00000000-0000-0000-0000-0000000104b1',
  '[{"column":"category","raw":"Comprsr","target_id":"00000000-0000-0000-0000-0000000104e1","status":"accepted"}]')$$,
  '22023', 'decisions: unknown or not allowed record', 'a location id is not a category');
select throws_ok($$select public.import_decide_values('00000000-0000-0000-0000-0000000104b1',
  '[{"column":"vendor","raw":"Siemens Ind.","target_id":"00000000-0000-0000-0000-0000000104f1","status":"accepted"}]')$$,
  '22023', 'decisions: unknown or not allowed record', 'no vendor_core.view: vendor refused');

reset role;
select tests.grant('00000000-0000-0000-0000-00000000000a', '00000000-0000-0000-0000-0000000000a1', 'vendor_core', '{view}');
select tests.act_as('00000000-0000-0000-0000-0000000000a1', '00000000-0000-0000-0000-00000000000a');
select throws_ok($$select public.import_decide_values('00000000-0000-0000-0000-0000000104b1',
  '[{"column":"vendor","raw":"Siemens Ind.","target_id":"00000000-0000-0000-0000-0000000104fb","status":"accepted"}]')$$,
  '22023', 'decisions: unknown or not allowed record', 'another tenant''s vendor refused');

-- The service's suggestions: stored, results untouched.
select lives_ok($$select public.import_decide_values('00000000-0000-0000-0000-0000000104b1',
  '[{"column":"category","raw":"Comprsr","target_id":"00000000-0000-0000-0000-0000000104c1","status":"suggested","confidence":0.78,"reason":"abbreviation"},
    {"column":"location","raw":"Plnt-2 Nsk","target_id":"00000000-0000-0000-0000-0000000104e1","status":"suggested","confidence":0.84,"reason":"abbreviation"},
    {"column":"vendor","raw":"Siemens Ind.","target_id":"00000000-0000-0000-0000-0000000104f1","status":"suggested","confidence":0.92,"reason":"name_variant"}]')$$,
  'suggestions stored');
select is((select status from public.import_batch where id = '00000000-0000-0000-0000-0000000104b1'), 'validated',
  'suggestions alone keep the results');

-- The user accepts two, rejects one; validation re-runs and every row with an accepted value resolves.
select lives_ok($$select public.import_decide_values('00000000-0000-0000-0000-0000000104b1',
  '[{"column":"category","raw":"Comprsr","target_id":"00000000-0000-0000-0000-0000000104c1","status":"accepted","confidence":0.78,"reason":"abbreviation"},
    {"column":"vendor","raw":"Siemens Ind.","target_id":"00000000-0000-0000-0000-0000000104f1","status":"accepted","confidence":0.92,"reason":"name_variant"},
    {"column":"location","raw":"Plnt-2 Nsk","target_id":"00000000-0000-0000-0000-0000000104e1","status":"rejected","confidence":0.84,"reason":"abbreviation"}]')$$,
  'decisions saved');
select is((select status from public.import_batch where id = '00000000-0000-0000-0000-0000000104b1'), 'mapped',
  'a decision means validate again');
select (public.import_validate('00000000-0000-0000-0000-0000000104b1')) is not null as validated;
select results_eq($$select r.row_number, r.payload -> 'asset' ->> 'category_id', r.payload -> 'asset' ->> 'oem_vendor_id', pg_temp.codes() = '{not_found}'
  from public.import_row r where r.batch_id = '00000000-0000-0000-0000-0000000104b1' and r.row_number = 4$$,
  $$values (4, '00000000-0000-0000-0000-0000000104c1', '00000000-0000-0000-0000-0000000104f1', true)$$,
  'accepted values resolve on every matching row; the rejected location stays not found');

-- A record deactivated after the decision is not used.
reset role;
update public.vendor set is_active = false where id = '00000000-0000-0000-0000-0000000104f1';
select tests.act_as('00000000-0000-0000-0000-0000000000a1', '00000000-0000-0000-0000-00000000000a');
select (public.import_validate('00000000-0000-0000-0000-0000000104b1')) is not null as validated;
select is((select r.result from public.import_row r where r.batch_id = '00000000-0000-0000-0000-0000000104b1' and r.row_number = 4),
  'error', 'an inactive record no longer resolves');

-- Read-only tenant, and the audit trail.
reset role;
select tests.grant('00000000-0000-0000-0000-00000000000b', '00000000-0000-0000-0000-0000000000a1', 'excel_import', '{review}');
select tests.act_as('00000000-0000-0000-0000-0000000000a1', '00000000-0000-0000-0000-00000000000b');
select throws_ok($$select public.import_decide_values('00000000-0000-0000-0000-0000000104bb',
  '[{"column":"vendor","raw":"x","target_id":"00000000-0000-0000-0000-0000000104fb","status":"accepted"}]')$$,
  '42501', null, 'read-only tenant: cannot decide');
reset role;
select ok(exists (select 1 from public.audit_log where tenant_id = '00000000-0000-0000-0000-00000000000a'
  and record_id = '00000000-0000-0000-0000-0000000104b1' and new_data -> 'value_suggestions' @> '[{"status":"accepted"}]'),
  'decisions audited');

select * from finish();
rollback;
