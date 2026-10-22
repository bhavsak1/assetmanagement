-- Story 3.7: tenant asset statuses, category sets, asset.status_id, moves (data-model-goal3.md §18).
-- Uses the seed (tenant A active, B read_only; a1 in A and B, no groups) and supabase/test_harness.sql.
begin;
select plan(67);

-- Fixtures, as postgres. Statuses f01..f0a in tenant A (the 5 default rows come from the tenant trigger).
insert into public.asset_status (id, tenant_id, code, label, system_status, tone, is_active) values
  ('00000000-0000-0000-0000-00000037f001', '00000000-0000-0000-0000-00000000000a', 'in_store',   'In store',   'in_stock',          'neutral', true),
  ('00000000-0000-0000-0000-00000037f002', '00000000-0000-0000-0000-00000000000a', 'running',    'Running',    'active',            'ok',      true),
  ('00000000-0000-0000-0000-00000037f003', '00000000-0000-0000-0000-00000000000a', 'standby',    'Standby',    'active',            'ok',      true),
  ('00000000-0000-0000-0000-00000037f004', '00000000-0000-0000-0000-00000000000a', 'breakdown',  'Breakdown',  'under_maintenance', 'warn',    true),
  ('00000000-0000-0000-0000-00000037f005', '00000000-0000-0000-0000-00000000000a', 'preventive', 'Preventive', 'under_maintenance', 'warn',    true),
  ('00000000-0000-0000-0000-00000037f006', '00000000-0000-0000-0000-00000000000a', 'idle',       'Idle',       'inactive',          'neutral', true),
  ('00000000-0000-0000-0000-00000037f007', '00000000-0000-0000-0000-00000000000a', 'scrapped',   'Scrapped',   'disposed',          'error',   true),
  ('00000000-0000-0000-0000-00000037f008', '00000000-0000-0000-0000-00000000000a', 'sold',       'Sold',       'disposed',          'error',   true),
  ('00000000-0000-0000-0000-00000037f009', '00000000-0000-0000-0000-00000000000a', 'lab',        'Calibration lab', 'active',       'ok',      true),
  ('00000000-0000-0000-0000-00000037f00a', '00000000-0000-0000-0000-00000000000a', 'old_status', 'Old status', 'active',            'ok',      false);
-- c1 has the "Machine tools" set; c2 its child, c3 its grandchild (inherit); c4 no set anywhere; c6 another set.
insert into public.asset_category (id, tenant_id, parent_id, name, status_ids) values
  ('00000000-0000-0000-0000-00000037c001', '00000000-0000-0000-0000-00000000000a', null, 'Machine tools',
   '{00000000-0000-0000-0000-00000037f001,00000000-0000-0000-0000-00000037f002,00000000-0000-0000-0000-00000037f003,00000000-0000-0000-0000-00000037f004,00000000-0000-0000-0000-00000037f005,00000000-0000-0000-0000-00000037f006,00000000-0000-0000-0000-00000037f007,00000000-0000-0000-0000-00000037f008}'),
  ('00000000-0000-0000-0000-00000037c004', '00000000-0000-0000-0000-00000000000a', null, 'Furniture', null),
  ('00000000-0000-0000-0000-00000037c006', '00000000-0000-0000-0000-00000000000a', null, 'Lab gear',
   '{00000000-0000-0000-0000-00000037f001,00000000-0000-0000-0000-00000037f009,00000000-0000-0000-0000-00000037f007}');
insert into public.asset_category (id, tenant_id, parent_id, name) values
  ('00000000-0000-0000-0000-00000037c002', '00000000-0000-0000-0000-00000000000a', '00000000-0000-0000-0000-00000037c001', 'Lathes'),
  ('00000000-0000-0000-0000-00000037c005', '00000000-0000-0000-0000-00000000000a', null, 'Spare');
insert into public.asset_category (id, tenant_id, parent_id, name) values
  ('00000000-0000-0000-0000-00000037c003', '00000000-0000-0000-0000-00000000000a', '00000000-0000-0000-0000-00000037c002', 'CNC lathes');

-- Assets: one inserted by system status (inherited set), one by tenant status.
insert into public.asset (id, tenant_id, tag, name, category_id, status) values
  ('00000000-0000-0000-0000-00000037a001', '00000000-0000-0000-0000-00000000000a', 'M-01', 'Lathe 1', '00000000-0000-0000-0000-00000037c003', 'active');
insert into public.asset (id, tenant_id, tag, name, category_id, status_id) values
  ('00000000-0000-0000-0000-00000037a002', '00000000-0000-0000-0000-00000000000a', 'M-02', 'Lathe 2', '00000000-0000-0000-0000-00000037c001', '00000000-0000-0000-0000-00000037f001');
insert into public.asset_status (id, tenant_id, code, label, system_status) values
  ('00000000-0000-0000-0000-00000037fb01', '00000000-0000-0000-0000-00000000000b', 'b_running', 'B running', 'active');

-- asset_status, one block per permission step.
select tests.act_as('00000000-0000-0000-0000-0000000000a1', '00000000-0000-0000-0000-00000000000a');
select is((select count(*)::int from public.asset_status), 0, 'no grant: no statuses');
select throws_ok($$insert into public.asset_status (tenant_id, code, label, system_status) values ('00000000-0000-0000-0000-00000000000a', 'x1', 'X1', 'active')$$,
  '42501', null, 'no grant: insert refused');

reset role;
select tests.grant('00000000-0000-0000-0000-00000000000a', '00000000-0000-0000-0000-0000000000a1', 'asset_core', '{view,update}');
select tests.act_as('00000000-0000-0000-0000-0000000000a1', '00000000-0000-0000-0000-00000000000a');
select is((select count(*)::int from public.asset_status), 15, 'asset_core.view: sees the labels');
select throws_ok($$insert into public.asset_status (tenant_id, code, label, system_status) values ('00000000-0000-0000-0000-00000000000a', 'x1', 'X1', 'active')$$,
  '42501', null, 'asset_core.view: insert refused');

reset role;
select tests.grant('00000000-0000-0000-0000-00000000000a', '00000000-0000-0000-0000-0000000000a1', 'category_config', '{view}');
select tests.act_as('00000000-0000-0000-0000-0000000000a1', '00000000-0000-0000-0000-00000000000a');
select is((select count(*)::int from public.asset_status), 15, 'category_config.view: sees the statuses');
update public.asset_status set label = 'Working' where code = 'running';
select is((select label from public.asset_status where code = 'running'), 'Running', 'category_config.view: update changes nothing');

reset role;
select tests.grant('00000000-0000-0000-0000-00000000000a', '00000000-0000-0000-0000-0000000000a1', 'category_config', '{manage}');
select tests.act_as('00000000-0000-0000-0000-0000000000a1', '00000000-0000-0000-0000-00000000000a');
select lives_ok($$insert into public.asset_status (tenant_id, code, label, system_status, tone) values ('00000000-0000-0000-0000-00000000000a', 'loaned', 'On loan', 'active', 'warn')$$,
  'manage: insert allowed');
select lives_ok($$update public.asset_status set label = 'Working', tone = 'ok' where code = 'active'$$, 'manage: default row can be renamed');
select throws_ok($$update public.asset_status set code = 'run' where code = 'running'$$, '42501', null, 'code is not writable');
select throws_ok($$update public.asset_status set is_active = false where code = 'active'$$,
  '22023', 'the default status of a system status cannot be deactivated', 'default row cannot be deactivated');
select throws_ok($$update public.asset_status set deleted_at = now() where code = 'disposed'$$,
  '22023', 'the default status of a system status cannot be deactivated', 'default row cannot be deleted');
select throws_ok($$delete from public.asset_status where code = 'loaned'$$, '42501', null, 'hard delete refused');
select lives_ok($$update public.asset_status set deleted_at = now() where code = 'loaned'$$, 'manage: soft delete of a non-default row');
select throws_ok($$insert into public.asset_status (tenant_id, code, label, system_status) values ('00000000-0000-0000-0000-00000000000a', 'loaned', 'Loaned again', 'active')$$,
  '23505', null, 'a code is never reused, even after a delete');
select throws_ok($$insert into public.asset_status (tenant_id, code, label, system_status) values ('00000000-0000-0000-0000-00000000000a', 'active', 'Fake', 'disposed')$$,
  '23514', null, 'a system code only names its own default row');
select throws_ok($$insert into public.asset_status (tenant_id, code, label, system_status) values ('00000000-0000-0000-0000-00000000000a', 'x2', 'X2', 'lost')$$,
  '23514', null, 'unknown system status refused');

reset role;
select tests.grant('00000000-0000-0000-0000-00000000000b', '00000000-0000-0000-0000-0000000000a1', 'category_config');
select tests.act_as('00000000-0000-0000-0000-0000000000a1', '00000000-0000-0000-0000-00000000000b');
select throws_ok($$insert into public.asset_status (tenant_id, code, label, system_status) values ('00000000-0000-0000-0000-00000000000b', 'x3', 'X3', 'active')$$,
  '42501', null, 'read-only tenant: insert refused');

reset role;
select throws_ok($$update public.asset_status set system_status = 'inactive' where code = 'running'$$,
  '22023', 'status code and system status cannot change', 'system status never changes, even for the owner');
select * from tests.cross_tenant('public.asset_status', 'category_config', '{"code":"ct_row","label":"ct-row","system_status":"active"}');

-- Set check (a1 manages categories in A).
select tests.act_as('00000000-0000-0000-0000-0000000000a1', '00000000-0000-0000-0000-00000000000a');
select throws_ok($$update public.asset_category set status_ids = '{00000000-0000-0000-0000-00000037fb01}' where id = '00000000-0000-0000-0000-00000037c005'$$, '23514', 'status set has an unknown or inactive status', 'set: another tenant''s status refused');
select throws_ok($$update public.asset_category set status_ids = '{00000000-0000-0000-0000-00000037f00a}' where id = '00000000-0000-0000-0000-00000037c005'$$,
  '23514', 'status set has an unknown or inactive status', 'set: inactive status refused');
select throws_ok($$update public.asset_category set status_ids = '{00000000-0000-0000-0000-00000037f002,00000000-0000-0000-0000-00000037f002}' where id = '00000000-0000-0000-0000-00000037c005'$$,
  '23514', 'a status set needs at least one status and no duplicates', 'set: duplicate refused');
select throws_ok($$update public.asset_category set status_ids = '{}' where id = '00000000-0000-0000-0000-00000037c005'$$,
  '23514', 'a status set needs at least one status and no duplicates', 'set: empty refused');
select throws_ok($$update public.asset_category set status_ids = '{00000000-0000-0000-0000-00000037f004,00000000-0000-0000-0000-00000037f007}' where id = '00000000-0000-0000-0000-00000037c005'$$,
  '23514', 'status set needs a status mapped to in_stock or active', 'set: no starting status refused');
select lives_ok($$update public.asset_category set status_ids = '{00000000-0000-0000-0000-00000037f001,00000000-0000-0000-0000-00000037f002}' where id = '00000000-0000-0000-0000-00000037c005'$$,
  'set: valid set saved');

-- Inheritance.
select is(public.category_statuses('00000000-0000-0000-0000-00000037c002'), public.category_statuses('00000000-0000-0000-0000-00000037c001'), 'child inherits the parent set');
select is(public.category_statuses('00000000-0000-0000-0000-00000037c003'), public.category_statuses('00000000-0000-0000-0000-00000037c001'), 'grandchild inherits the grandparent set');
select is((public.category_statuses('00000000-0000-0000-0000-00000037c001'))[2], '00000000-0000-0000-0000-00000037f002'::uuid, 'own set keeps its order');
select is(cardinality(public.category_statuses('00000000-0000-0000-0000-00000037c004')),
  (select count(*)::int from public.asset_status where is_active and deleted_at is null), 'no set anywhere: every active status');
select is((select system_status from public.asset_status where id = (public.category_statuses('00000000-0000-0000-0000-00000037c004'))[1]),
  'in_stock', 'no set anywhere: in system order');

-- Insert and agreement, as postgres.
reset role;
select is((select status_id from public.asset where id = '00000000-0000-0000-0000-00000037a001'), '00000000-0000-0000-0000-00000037f002'::uuid,
  'insert by system status: first match in the inherited set');
select is((select status from public.asset where id = '00000000-0000-0000-0000-00000037a002'), 'in_stock', 'insert by status_id: status follows it');
select throws_ok($$insert into public.asset (tenant_id, tag, name, category_id, status_id) values ('00000000-0000-0000-0000-00000000000a', 'M-03', 'X', '00000000-0000-0000-0000-00000037c001', '00000000-0000-0000-0000-00000037f009')$$,
  '23514', null, 'insert with a status outside the set refused');
select throws_ok($$update public.asset set status = 'disposed' where id = '00000000-0000-0000-0000-00000037a001'$$,
  '23503', null, 'status and status_id cannot disagree (foreign key)');
select col_not_null('public', 'asset', 'status_id', 'every asset has a status_id');
select is((select count(*)::int from public.asset a join public.asset_status s on s.id = a.status_id where s.system_status <> a.status),
  0, 'status always matches the mapped system status');

-- Moves (18.3), a1 with asset_lifecycle.execute.
select tests.grant('00000000-0000-0000-0000-00000000000a', '00000000-0000-0000-0000-0000000000a1', 'asset_lifecycle', '{execute}');
select tests.act_as('00000000-0000-0000-0000-0000000000a1', '00000000-0000-0000-0000-00000000000a');
select lives_ok($$select public.change_asset_status('00000000-0000-0000-0000-00000037a001', '00000000-0000-0000-0000-00000037f003'::uuid)$$, 'Running to Standby: same system, no reason');
select lives_ok($$select public.change_asset_status('00000000-0000-0000-0000-00000037a001', '00000000-0000-0000-0000-00000037f004'::uuid)$$, 'Standby to Breakdown');
select lives_ok($$select public.change_asset_status('00000000-0000-0000-0000-00000037a001', '00000000-0000-0000-0000-00000037f005'::uuid)$$, 'Breakdown to Preventive');
select throws_ok($$select public.change_asset_status('00000000-0000-0000-0000-00000037a001', '00000000-0000-0000-0000-00000037f006'::uuid, 'x')$$,
  '22023', 'status cannot change from under_maintenance to inactive', 'Preventive to Idle refused (B11)');
select lives_ok($$select public.change_asset_status('00000000-0000-0000-0000-00000037a001', '00000000-0000-0000-0000-00000037f002'::uuid)$$, 'Preventive back to Running');
select throws_ok($$select public.change_asset_status('00000000-0000-0000-0000-00000037a001', '00000000-0000-0000-0000-00000037f009'::uuid)$$,
  '22023', null, 'Running to a status outside the set refused');
select throws_ok($$select public.change_asset_status('00000000-0000-0000-0000-00000037a001', '00000000-0000-0000-0000-00000037f006'::uuid)$$,
  '23502', 'a reason is required for this status change', 'Running to Idle needs a reason');
select lives_ok($$select public.change_asset_status('00000000-0000-0000-0000-00000037a001', '00000000-0000-0000-0000-00000037f006'::uuid, 'No orders')$$, 'Running to Idle with a reason');
select lives_ok($$select public.change_asset_status('00000000-0000-0000-0000-00000037a001', '00000000-0000-0000-0000-00000037f007'::uuid, 'Worn out')$$, 'Idle to Scrapped with a reason');
select throws_ok($$select public.change_asset_status('00000000-0000-0000-0000-00000037a001', '00000000-0000-0000-0000-00000037f008'::uuid, 'Sold it')$$,
  '42501', 'not allowed to reopen a disposed asset', 'Scrapped to Sold needs reopen');
select is((select count(*)::int from public.allowed_asset_statuses('00000000-0000-0000-0000-00000037a001')), 0, 'no reopen: no targets offered');
select throws_ok($$select public.change_asset_status('00000000-0000-0000-0000-00000037a002', '00000000-0000-0000-0000-00000037f004'::uuid)$$,
  '22023', 'status cannot change from in_stock to under_maintenance', 'In store to Breakdown refused (B11)');
select results_eq($$select * from public.allowed_asset_statuses('00000000-0000-0000-0000-00000037a002')$$,
  $$values ('00000000-0000-0000-0000-00000037f002'::uuid), ('00000000-0000-0000-0000-00000037f003'), ('00000000-0000-0000-0000-00000037f007'), ('00000000-0000-0000-0000-00000037f008')$$,
  'In store: targets in set order');
select lives_ok($$select public.change_asset_status('00000000-0000-0000-0000-00000037a002', 'active')$$, 'text version still works');
select is((select status_id from public.asset where id = '00000000-0000-0000-0000-00000037a002'), '00000000-0000-0000-0000-00000037f002'::uuid,
  'text version picks the first status of that system status in the set');

reset role;
select tests.grant('00000000-0000-0000-0000-00000000000a', '00000000-0000-0000-0000-0000000000a1', 'asset_lifecycle', '{reopen}');
select tests.act_as('00000000-0000-0000-0000-0000000000a1', '00000000-0000-0000-0000-00000000000a');
select throws_ok($$select public.change_asset_status('00000000-0000-0000-0000-00000037a001', '00000000-0000-0000-0000-00000037f008'::uuid)$$,
  '23502', 'a reason is required for this status change', 'reopen needs a reason');
select lives_ok($$select public.change_asset_status('00000000-0000-0000-0000-00000037a001', '00000000-0000-0000-0000-00000037f008'::uuid, 'It was sold')$$, 'Scrapped to Sold: correction with reopen');
select throws_ok($$select public.change_asset_status('00000000-0000-0000-0000-00000037a001', '00000000-0000-0000-0000-00000037f005'::uuid, 'x')$$,
  '22023', 'status cannot change from disposed to under_maintenance', 'Sold to Preventive refused');
select lives_ok($$select public.change_asset_status('00000000-0000-0000-0000-00000037a001', '00000000-0000-0000-0000-00000037f002'::uuid, 'Bought back')$$, 'Sold to Running: reopen');
reset role;
select ok(exists (select 1 from private.outbox_event where aggregate_id = '00000000-0000-0000-0000-00000037a001'
                  and event_type = 'asset.status_changed' and payload ->> 'from' = 'disposed' and payload ->> 'to' = 'active'
                  and payload ->> 'from_id' = '00000000-0000-0000-0000-00000037f008' and payload ->> 'to_id' = '00000000-0000-0000-0000-00000037f002'),
  'outbox event carries system and tenant statuses');
select tests.act_as('00000000-0000-0000-0000-0000000000a1', '00000000-0000-0000-0000-00000000000a');

-- Category change (R8) and the column grant.
select lives_ok($$update public.asset set category_id = '00000000-0000-0000-0000-00000037c006' where id = '00000000-0000-0000-0000-00000037a001'$$, 'category change allowed');
select is((select status_id from public.asset where id = '00000000-0000-0000-0000-00000037a001'), '00000000-0000-0000-0000-00000037f009'::uuid,
  'category change: remapped to the same system status in the new set');
select throws_ok($$update public.asset set status_id = '00000000-0000-0000-0000-00000037f003' where id = '00000000-0000-0000-0000-00000037a001'$$,
  '42501', null, 'status_id is not writable by a plain update');

-- Seeding for a new tenant.
reset role;
insert into public.tenant (id, name, slug, currency_code, locale, time_zone, date_format, fiscal_year_start_month) values
  ('00000000-0000-0000-0000-00000037000c', 'TEST Tenant C', 'test-tenant-c', 'INR', 'en-IN', 'Asia/Kolkata', 'dd-MM-yyyy', 4);
select private.seed_asset_statuses('00000000-0000-0000-0000-00000037000c');
select results_eq($$select code from public.asset_status where tenant_id = '00000000-0000-0000-0000-00000037000c' order by code$$,
  array['active', 'disposed', 'in_stock', 'inactive', 'under_maintenance'], 'new tenant: 5 default statuses, once');

select * from finish();
rollback;
