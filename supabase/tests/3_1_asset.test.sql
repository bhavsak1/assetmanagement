-- Story 3.1: asset table, tag, status action, custom values, masked read view, parent rules,
-- fiscal-year lock, access path. docs/data-model-goal3.md. Uses the seed (tenant A active,
-- B read_only; a1 in A and B, no groups) and supabase/test_harness.sql.
begin;
select plan(90);

-- Fixtures, inserted as postgres before any act_as: no signed-in user, so the user rules do not apply.
insert into public.asset_category (id, tenant_id, parent_id, name, code, is_active) values
  ('00000000-0000-0000-0000-0000000031c1', '00000000-0000-0000-0000-00000000000a', null, 'Machines', 'MC', true),
  ('00000000-0000-0000-0000-0000000031c2', '00000000-0000-0000-0000-00000000000a', '00000000-0000-0000-0000-0000000031c1', 'CNC', null, true),
  ('00000000-0000-0000-0000-0000000031c3', '00000000-0000-0000-0000-00000000000a', null, 'Old', null, false),
  ('00000000-0000-0000-0000-0000000031c4', '00000000-0000-0000-0000-00000000000a', null, 'Vehicles', null, true),
  ('00000000-0000-0000-0000-0000000031cb', '00000000-0000-0000-0000-00000000000b', null, 'B cat', null, true);
insert into public.location (id, tenant_id, parent_id, name, code) values
  ('00000000-0000-0000-0000-0000000031e1', '00000000-0000-0000-0000-00000000000a', null, 'Pune', 'PNE'),
  ('00000000-0000-0000-0000-0000000031e2', '00000000-0000-0000-0000-00000000000a', '00000000-0000-0000-0000-0000000031e1', 'Bay 3', null);
insert into public.field_definition (tenant_id, entity, category_id, key, label, type, options, is_required, security_domain_id)
select '00000000-0000-0000-0000-00000000000a', 'asset', f.category_id::uuid, f.key, f.key, f.type, f.options::jsonb, f.required,
       (select id from public.security_domain where code = f.domain)
from (values
  ('00000000-0000-0000-0000-0000000031c1', 'rated_kw',     'number', '[]', false, 'asset_core'),
  ('00000000-0000-0000-0000-0000000031c1', 'fluid',        'list',
   '[{"code":"oil","label":"Oil","is_active":true},{"code":"water","label":"Water","is_active":false}]', false, 'asset_core'),
  (null,                                   'installed_on', 'date',   '[]', false, 'asset_core'),
  (null,                                   'cost_rate',    'number', '[]', false, 'asset_financials'),
  ('00000000-0000-0000-0000-0000000031c4', 'plate',        'text',   '[]', false, 'asset_core'),
  ('00000000-0000-0000-0000-0000000031c2', 'inspect_no',   'text',   '[]', true,  'asset_core')
) as f (category_id, key, type, options, required, domain);

insert into public.asset (id, tenant_id, name, category_id, location_id, purchase_value, purchase_currency, custom_values) values
  ('00000000-0000-0000-0000-0000000031a1', '00000000-0000-0000-0000-00000000000a', 'Lathe 04', '00000000-0000-0000-0000-0000000031c1',
   '00000000-0000-0000-0000-0000000031e1', 1000, 'INR', '{"cost_rate": 99, "rated_kw": 15}'),
  ('00000000-0000-0000-0000-0000000031b1', '00000000-0000-0000-0000-00000000000b', 'B asset', '00000000-0000-0000-0000-0000000031cb',
   null, null, null, '{}');
-- A chain five levels deep: d1 > d2 > d3 > d4 > d5.
insert into public.asset (id, tenant_id, name, category_id, parent_asset_id)
select ('00000000-0000-0000-0000-0000000031d' || n)::uuid, '00000000-0000-0000-0000-00000000000a', 'Level ' || n,
       '00000000-0000-0000-0000-0000000031c1',
       case when n > 1 then ('00000000-0000-0000-0000-0000000031d' || n - 1)::uuid end
from generate_series(1, 5) n;

-- Shape.
select policies_are('public', 'asset', array['asset_select', 'asset_insert', 'asset_update']);
select ok(not has_table_privilege('authenticated', 'public.asset', 'delete'), 'no hard delete grant');
select ok(not has_column_privilege('authenticated', 'public.asset', 'purchase_value', 'select'), 'purchase_value not readable on the table');
select ok(not has_column_privilege('authenticated', 'public.asset', 'custom_values', 'select'), 'custom_values not readable on the table');
select results_eq(
  $$select d.code || '.' || o.code from public.domain_operation o join public.security_domain d on d.id = o.security_domain_id
    where o.code in ('set_tag', 'reopen') order by 1$$,
  $$values ('asset_core.set_tag'), ('asset_lifecycle.reopen')$$,
  'set_tag and reopen seeded as data'
);
select is((select tag from public.asset where id = '00000000-0000-0000-0000-0000000031a1'), 'AST-00001', 'tag generated from the default pattern');
select is((select tag from public.asset where id = '00000000-0000-0000-0000-0000000031b1'), 'AST-00001', 'each tenant has its own counter');

-- Default deny.
select tests.act_as('00000000-0000-0000-0000-0000000000a1', '00000000-0000-0000-0000-00000000000a');
select is((select count(*)::int from public.asset_view), 0, 'no grant, no rows in the view');
select is((select count(*)::int from public.asset), 0, 'no grant, no rows in the table');
select throws_ok(
  $$insert into public.asset (tenant_id, name, category_id) values ('00000000-0000-0000-0000-00000000000a', 'x', '00000000-0000-0000-0000-0000000031c1')$$,
  '42501', null, 'no grant, no insert');

-- view only.
reset role;
select tests.grant('00000000-0000-0000-0000-00000000000a', '00000000-0000-0000-0000-0000000000a1', 'asset_core', '{view}');
select tests.act_as('00000000-0000-0000-0000-0000000000a1', '00000000-0000-0000-0000-00000000000a');
select is((select count(*)::int from public.asset_view where tenant_id <> '00000000-0000-0000-0000-00000000000a'), 0, 'view shows own tenant only');
select is((select count(*)::int from public.asset_view), 6, 'view reads own tenant rows');
select throws_ok(
  $$insert into public.asset (tenant_id, name, category_id) values ('00000000-0000-0000-0000-00000000000a', 'x', '00000000-0000-0000-0000-0000000031c1')$$,
  '42501', null, 'view cannot insert');
select is_empty($$update public.asset set name = 'x' returning 1$$, 'view cannot update');

-- Masking (A6): no asset_financials, so money is null and the financial custom key is gone.
select is((select purchase_value from public.asset_view where id = '00000000-0000-0000-0000-0000000031a1'), null, 'purchase_value masked without asset_financials.view');
select is((select custom_values from public.asset_view where id = '00000000-0000-0000-0000-0000000031a1'), '{"rated_kw": 15}'::jsonb, 'financial custom key masked');
select throws_ok($$select purchase_value from public.asset$$, '42501', null, 'table refuses the money column');

-- create and update.
reset role;
select tests.grant('00000000-0000-0000-0000-00000000000a', '00000000-0000-0000-0000-0000000000a1', 'asset_core', '{create,update}');
select tests.act_as('00000000-0000-0000-0000-0000000000a1', '00000000-0000-0000-0000-00000000000a');
select lives_ok(
  $$insert into public.asset (id, tenant_id, name, category_id, location_id, custom_values) values
    ('00000000-0000-0000-0000-0000000031a2', '00000000-0000-0000-0000-00000000000a', 'Pump 01', '00000000-0000-0000-0000-0000000031c1',
     '00000000-0000-0000-0000-0000000031e2', '{"rated_kw": 7.5, "fluid": "oil", "installed_on": "2024-03-01"}')$$,
  'create inserts an asset with valid custom values');
select is((select tag from public.asset where id = '00000000-0000-0000-0000-0000000031a2'), 'AST-00007', 'next number from the tenant counter');
select lives_ok($$update public.asset set name = 'Pump 01A' where id = '00000000-0000-0000-0000-0000000031a2'$$, 'update edits a row');
select throws_ok($$update public.asset set status = 'inactive' where id = '00000000-0000-0000-0000-0000000031a2'$$, '42501', null, 'status is not a plain update');
select throws_ok($$update public.asset set location_id = null where id = '00000000-0000-0000-0000-0000000031a2'$$, '42501', null, 'location is not a plain update');
select throws_ok($$update public.asset set deleted_at = now() where id = '00000000-0000-0000-0000-0000000031a2'$$, '42501', null, 'update alone cannot soft delete');
select throws_ok($$delete from public.asset where id = '00000000-0000-0000-0000-0000000031a2'$$, '42501', null, 'no hard delete');
select throws_ok(
  $$insert into public.asset (tenant_id, name, category_id, status) values ('00000000-0000-0000-0000-00000000000a', 'x', '00000000-0000-0000-0000-0000000031c1', 'disposed')$$,
  '23514', null, 'a new asset cannot start disposed');
select throws_ok(
  $$insert into public.asset (tenant_id, name, category_id) values ('00000000-0000-0000-0000-00000000000a', 'x', '00000000-0000-0000-0000-0000000031c3')$$,
  '23514', null, 'inactive category refused');
select throws_ok(
  $$insert into public.asset (tenant_id, name, category_id) values ('00000000-0000-0000-0000-00000000000a', 'x', '00000000-0000-0000-0000-0000000031cb')$$,
  '23514', null, 'category of another tenant refused');

-- Custom values.
select throws_ok($$update public.asset set custom_values = '{"rated_kw": "abc"}' where id = '00000000-0000-0000-0000-0000000031a2'$$,
  '22023', 'custom field rated_kw needs a number value', 'wrong type refused');
select throws_ok($$update public.asset set custom_values = '{"nope": 1}' where id = '00000000-0000-0000-0000-0000000031a2'$$,
  '22023', 'unknown custom field: nope', 'unknown key refused');
select throws_ok($$update public.asset set custom_values = '{"fluid": "water"}' where id = '00000000-0000-0000-0000-0000000031a2'$$,
  '22023', null, 'inactive list option refused');
select throws_ok($$update public.asset set custom_values = '{"installed_on": "2024-02-30"}' where id = '00000000-0000-0000-0000-0000000031a2'$$,
  '22023', null, 'impossible date refused');
select throws_ok($$update public.asset set custom_values = '{"plate": "MH12"}' where id = '00000000-0000-0000-0000-0000000031a2'$$,
  '22023', 'custom field plate does not apply to this category', 'field of another category refused');
select throws_ok($$update public.asset set custom_values = '{"rated_kw": null}' where id = '00000000-0000-0000-0000-0000000031a2'$$,
  '22023', null, 'json null refused');
select throws_ok(
  $$insert into public.asset (tenant_id, name, category_id) values ('00000000-0000-0000-0000-00000000000a', 'x', '00000000-0000-0000-0000-0000000031c2')$$,
  '23502', 'missing mandatory fields: inspect_no', 'missing mandatory custom field refused (inherited category line)');
select lives_ok(
  $$insert into public.asset (tenant_id, name, category_id, custom_values) values
    ('00000000-0000-0000-0000-00000000000a', 'x', '00000000-0000-0000-0000-0000000031c2', '{"inspect_no": "I-1", "rated_kw": 3}')$$,
  'mandatory present and parent field inherited');

-- Hidden key kept: a1 cannot view cost_rate, so a save neither blanks nor changes it.
select lives_ok($$update public.asset set custom_values = '{"rated_kw": 20, "cost_rate": 1}' where id = '00000000-0000-0000-0000-0000000031a1'$$,
  'save from a form that never saw the hidden key');
reset role;
select is((select custom_values from public.asset where id = '00000000-0000-0000-0000-0000000031a1'),
          '{"rated_kw": 20, "cost_rate": 99}'::jsonb, 'hidden key kept as stored, visible key changed');

-- Tenant mandatory system fields (2.5 M1), and M2: a field the user cannot write is skipped.
update public.tenant set required_asset_fields = '{serial_number,purchase_value}' where id = '00000000-0000-0000-0000-00000000000a';
select tests.act_as('00000000-0000-0000-0000-0000000000a1', '00000000-0000-0000-0000-00000000000a');
select throws_ok(
  $$insert into public.asset (tenant_id, name, category_id) values ('00000000-0000-0000-0000-00000000000a', 'x', '00000000-0000-0000-0000-0000000031c1')$$,
  '23502', 'missing mandatory fields: serial_number', 'tenant mandatory field refused; purchase_value skipped (M2)');
select lives_ok(
  $$insert into public.asset (tenant_id, name, category_id, serial_number) values ('00000000-0000-0000-0000-00000000000a', 'x', '00000000-0000-0000-0000-0000000031c1', 'S1')$$,
  'saves without purchase_value when the user cannot write it (M2)');
select throws_ok(
  $$insert into public.asset (tenant_id, name, category_id, serial_number, purchase_value, purchase_currency)
    values ('00000000-0000-0000-0000-00000000000a', 'x', '00000000-0000-0000-0000-0000000031c1', 'S2', 5, 'INR')$$,
  '42501', null, 'money refused without asset_financials.update');
reset role;
update public.tenant set required_asset_fields = '{}' where id = '00000000-0000-0000-0000-00000000000a';

-- asset_financials: view unmasks, update writes.
select tests.grant('00000000-0000-0000-0000-00000000000a', '00000000-0000-0000-0000-0000000000a1', 'asset_financials', '{view,update}');
select tests.act_as('00000000-0000-0000-0000-0000000000a1', '00000000-0000-0000-0000-00000000000a');
select is((select purchase_value from public.asset_view where id = '00000000-0000-0000-0000-0000000031a1'), 1000.0000, 'purchase_value shown with asset_financials.view');
select is((select custom_values ->> 'cost_rate' from public.asset_view where id = '00000000-0000-0000-0000-0000000031a1'), '99', 'financial custom key shown');
select lives_ok($$update public.asset set purchase_value = 1200 where id = '00000000-0000-0000-0000-0000000031a1'$$, 'money written with asset_financials.update');

-- Tag (A1).
select throws_ok(
  $$insert into public.asset (tenant_id, name, category_id, tag) values ('00000000-0000-0000-0000-00000000000a', 'x', '00000000-0000-0000-0000-0000000031c1', 'MY-1')$$,
  '42501', null, 'typed tag refused without set_tag');
select throws_ok($$update public.asset set tag = 'MY-1' where id = '00000000-0000-0000-0000-0000000031a2'$$, '42501', null, 'tag change refused without set_tag');
select throws_ok($$select public.set_asset_tag_pattern('{LOC}-{SEQ:4}')$$, '42501', null, 'tag pattern needs tenant_settings.manage');
reset role;
select tests.grant('00000000-0000-0000-0000-00000000000a', '00000000-0000-0000-0000-0000000000a1', 'asset_core', '{set_tag}');
select tests.grant('00000000-0000-0000-0000-00000000000a', '00000000-0000-0000-0000-0000000000a1', 'tenant_settings', '{manage}');
select tests.act_as('00000000-0000-0000-0000-0000000000a1', '00000000-0000-0000-0000-00000000000a');
select lives_ok(
  $$insert into public.asset (tenant_id, name, category_id, tag) values ('00000000-0000-0000-0000-00000000000a', 'x', '00000000-0000-0000-0000-0000000031c1', 'MY-1')$$,
  'typed tag with set_tag');
select throws_ok(
  $$insert into public.asset (tenant_id, name, category_id, tag) values ('00000000-0000-0000-0000-00000000000a', 'x', '00000000-0000-0000-0000-0000000031c1', 'my-1')$$,
  '23505', null, 'tag unique per tenant, ignoring case');
select throws_ok($$select public.set_asset_tag_pattern('{SEQ:4}-X')$$, '23514', null, 'pattern must end with {SEQ:n}');
select lives_ok($$select public.set_asset_tag_pattern('{LOC}-{CAT}-{DATE:yyyymm}-{SEQ:3}')$$, 'tag pattern set');
select lives_ok(
  $$insert into public.asset (id, tenant_id, name, category_id, location_id, custom_values) values
    ('00000000-0000-0000-0000-0000000031a3', '00000000-0000-0000-0000-00000000000a', 'x', '00000000-0000-0000-0000-0000000031c2',
     '00000000-0000-0000-0000-0000000031e2', '{"inspect_no": "I-2"}'),
    ('00000000-0000-0000-0000-0000000031a4', '00000000-0000-0000-0000-00000000000a', 'y', '00000000-0000-0000-0000-0000000031c2',
     '00000000-0000-0000-0000-0000000031e2', '{"inspect_no": "I-3"}')$$,
  'insert with codes from parent location and parent category');
select results_eq(
  $$select tag from public.asset where id in ('00000000-0000-0000-0000-0000000031a3', '00000000-0000-0000-0000-0000000031a4') order by tag$$,
  format($$values ('PNE-MC-%1$s-001'), ('PNE-MC-%1$s-002')$$, to_char(now() at time zone 'Asia/Kolkata', 'YYYYMM')),
  'pattern parts resolved; counter per prefix');
select throws_ok(
  $$insert into public.asset (tenant_id, name, category_id) values ('00000000-0000-0000-0000-00000000000a', 'x', '00000000-0000-0000-0000-0000000031c1')$$,
  '22023', null, '{LOC} with no location refused');

-- Status action (A2, A3).
select throws_ok($$select public.change_asset_status('00000000-0000-0000-0000-0000000031a2', 'under_maintenance')$$,
  '42501', null, 'status change needs asset_lifecycle.execute');
reset role;
select tests.grant('00000000-0000-0000-0000-00000000000a', '00000000-0000-0000-0000-0000000000a1', 'asset_lifecycle', '{execute}');
select tests.act_as('00000000-0000-0000-0000-0000000000a1', '00000000-0000-0000-0000-00000000000a');
select lives_ok($$select public.change_asset_status('00000000-0000-0000-0000-0000000031a2', 'under_maintenance')$$, 'active to under_maintenance');
select throws_ok($$select public.change_asset_status('00000000-0000-0000-0000-0000000031a2', 'inactive', 'x')$$,
  '22023', 'status cannot change from under_maintenance to inactive', 'under_maintenance to inactive refused (B11)');
select lives_ok($$select public.change_asset_status('00000000-0000-0000-0000-0000000031a2', 'active')$$, 'under_maintenance back to active');
select throws_ok($$select public.change_asset_status('00000000-0000-0000-0000-0000000031a2', 'inactive', '  ')$$,
  '23502', null, 'inactive without a reason refused');
select lives_ok($$select public.change_asset_status('00000000-0000-0000-0000-0000000031a2', 'inactive', 'Spare for line 2')$$, 'inactive with a reason');
select is((select status_reason from public.asset where id = '00000000-0000-0000-0000-0000000031a2'), 'Spare for line 2', 'reason stored');
select throws_ok($$select public.change_asset_status('00000000-0000-0000-0000-0000000031a2', 'disposed')$$,
  '23502', null, 'disposed without a reason refused');
select lives_ok($$select public.change_asset_status('00000000-0000-0000-0000-0000000031a2', 'disposed', 'Scrapped')$$, 'disposed with a reason');
select throws_ok($$select public.change_asset_status('00000000-0000-0000-0000-0000000031a2', 'active', 'Repaired')$$,
  '42501', null, 'reopen needs asset_lifecycle.reopen');
reset role;
select is((select count(*)::int from private.outbox_event where event_type = 'asset.status_changed'
           and aggregate_id = '00000000-0000-0000-0000-0000000031a2'), 4, 'one asset.status_changed event per change');
select is((select count(*)::int from public.audit_log where table_name = 'asset' and record_id = '00000000-0000-0000-0000-0000000031a2'
           and new_data ->> 'status' = 'disposed'), 1, 'status change audited');
select tests.grant('00000000-0000-0000-0000-00000000000a', '00000000-0000-0000-0000-0000000000a1', 'asset_lifecycle', '{reopen}');
select tests.act_as('00000000-0000-0000-0000-0000000000a1', '00000000-0000-0000-0000-00000000000a');
select throws_ok($$select public.change_asset_status('00000000-0000-0000-0000-0000000031a2', 'active')$$,
  '23502', null, 'reopen without a reason refused');
select throws_ok($$select public.change_asset_status('00000000-0000-0000-0000-0000000031a2', 'under_maintenance', 'x')$$,
  '22023', null, 'reopen to under_maintenance refused');
select lives_ok($$select public.change_asset_status('00000000-0000-0000-0000-0000000031a2', 'active', 'Repaired and back in use')$$, 'reopen with reopen and a reason');

-- Parent and child (OQ-07).
select throws_ok(
  $$insert into public.asset (tenant_id, name, category_id, tag, parent_asset_id) values
    ('00000000-0000-0000-0000-00000000000a', 'L6', '00000000-0000-0000-0000-0000000031c1', 'L-6', '00000000-0000-0000-0000-0000000031d5')$$,
  '23514', 'assets can nest at most 5 levels deep', 'sixth level refused');
select throws_ok($$update public.asset set parent_asset_id = '00000000-0000-0000-0000-0000000031d3' where id = '00000000-0000-0000-0000-0000000031d1'$$,
  '23514', 'an asset cannot be inside itself', 'cycle refused');
select throws_ok($$update public.asset set parent_asset_id = '00000000-0000-0000-0000-0000000031a1' where id = '00000000-0000-0000-0000-0000000031d1'$$,
  '23514', 'assets can nest at most 5 levels deep', 'moving a 5-level subtree under another asset refused');

-- delete.
reset role;
select tests.grant('00000000-0000-0000-0000-00000000000a', '00000000-0000-0000-0000-0000000000a1', 'asset_core', '{delete}');
select tests.act_as('00000000-0000-0000-0000-0000000000a1', '00000000-0000-0000-0000-00000000000a');
select lives_ok($$update public.asset set deleted_at = now() where id = '00000000-0000-0000-0000-0000000031a4'$$, 'delete soft-deletes a row');
select is((select count(*)::int from public.asset_view where id = '00000000-0000-0000-0000-0000000031a4'), 0, 'view hides soft-deleted rows');
select is((select count(*)::int from public.asset where id = '00000000-0000-0000-0000-0000000031a4'), 1, 'table keeps soft-deleted rows readable');

-- Access path (spike 1.7 F2). Sorts and seq scans off, so a plan that cannot use the index shows it.
create function pg_temp.plan(q text) returns text language plpgsql as $$
declare
  r text;
  v text := '';
begin
  for r in execute 'explain ' || q loop
    v := v || r || E'\n';
  end loop;
  return v;
end;
$$;
-- Fresh table has no statistics, so give the planner some, then act as the user again.
reset role;
analyze public.asset;
select tests.act_as('00000000-0000-0000-0000-0000000000a1', '00000000-0000-0000-0000-00000000000a');
set local enable_seqscan = off;
set local enable_sort = off;
set local enable_bitmapscan = off;
select matches(pg_temp.plan('select id, name from public.asset_view order by name limit 50'),
  'Index (Only )?Scan using asset_name_idx', 'list by name walks asset_name_idx');
select doesnt_match(pg_temp.plan('select id, name from public.asset_view order by name limit 50'),
  'Sort', 'list by name needs no sort');
select matches(pg_temp.plan($$select id from public.asset_view where tag = 'AST-00001'$$),
  'asset_tag_uq', 'tag lookup uses asset_tag_uq');
reset enable_seqscan;
reset enable_sort;
reset enable_bitmapscan;

-- Read-only tenant B: reads work, writes do not, even with every grant.
reset role;
select tests.grant('00000000-0000-0000-0000-00000000000b', '00000000-0000-0000-0000-0000000000a1', 'asset_core');
select tests.grant('00000000-0000-0000-0000-00000000000b', '00000000-0000-0000-0000-0000000000a1', 'asset_lifecycle');
select tests.act_as('00000000-0000-0000-0000-0000000000a1', '00000000-0000-0000-0000-00000000000b');
select results_eq('select name from public.asset_view', $$values ('B asset')$$, 'read_only tenant reads');
select throws_ok(
  $$insert into public.asset (tenant_id, name, category_id) values ('00000000-0000-0000-0000-00000000000b', 'x', '00000000-0000-0000-0000-0000000031cb')$$,
  '42501', null, 'read_only tenant cannot insert');
select throws_ok($$select public.change_asset_status('00000000-0000-0000-0000-0000000031b1', 'inactive', 'x')$$,
  '42501', null, 'read_only tenant cannot change status');

-- Fiscal-year lock (2.5 S3).
reset role;
update public.tenant set asset_tag_pattern = 'AST-{SEQ:5}' where id = '00000000-0000-0000-0000-00000000000a';
select throws_ok($$update public.tenant set fiscal_year_start_month = 1 where id = '00000000-0000-0000-0000-00000000000a'$$,
  '23514', null, 'fiscal year start locked once the tenant has assets');
insert into public.tenant (id, name, slug, currency_code, locale, time_zone, date_format, fiscal_year_start_month) values
  ('00000000-0000-0000-0000-00000000000c', 'TEST Tenant C', 'test-tenant-c', 'EUR', 'en-GB', 'Europe/London', 'dd/MM/yyyy', 1);
select lives_ok($$update public.tenant set fiscal_year_start_month = 4 where id = '00000000-0000-0000-0000-00000000000c'$$,
  'fiscal year start can change before the first asset');

-- Cross-tenant harness: 8 tests. Tenant B's row needs a tenant B category.
select * from tests.cross_tenant('public.asset', 'asset_core',
  '{"name":"ct-row","category_id":"00000000-0000-0000-0000-0000000031c1"}',
  '{"category_id":"00000000-0000-0000-0000-0000000031cb"}');

select * from finish();
rollback;
