-- Story 3.5: transfer_asset() and the Retire path on change_asset_status() (data-model-goal3.md Â§16).
-- Uses the seed (tenant A active, B read_only; a1 in A and B, no groups) and supabase/test_harness.sql.
begin;
select plan(21);

-- Fixtures, as postgres before any act_as: no signed-in user, so the user rules do not apply.
insert into public.asset_category (id, tenant_id, name) values
  ('00000000-0000-0000-0000-0000000035c1', '00000000-0000-0000-0000-00000000000a', 'Machines'),
  ('00000000-0000-0000-0000-0000000035cb', '00000000-0000-0000-0000-00000000000b', 'B cat');
insert into public.location (id, tenant_id, name, active) values
  ('00000000-0000-0000-0000-0000000035e1', '00000000-0000-0000-0000-00000000000a', 'Plant 1', true),
  ('00000000-0000-0000-0000-0000000035e2', '00000000-0000-0000-0000-00000000000a', 'Plant 2', true),
  ('00000000-0000-0000-0000-0000000035e3', '00000000-0000-0000-0000-00000000000a', 'Old shed', false),
  ('00000000-0000-0000-0000-0000000035eb', '00000000-0000-0000-0000-00000000000b', 'B site', true);
insert into public.asset (id, tenant_id, tag, name, category_id, location_id, parent_asset_id) values
  ('00000000-0000-0000-0000-0000000035a1', '00000000-0000-0000-0000-00000000000a', 'CNC-01', 'CNC 01', '00000000-0000-0000-0000-0000000035c1', '00000000-0000-0000-0000-0000000035e1', null),
  ('00000000-0000-0000-0000-0000000035a2', '00000000-0000-0000-0000-00000000000a', 'SPN-01', 'Spindle', '00000000-0000-0000-0000-0000000035c1', '00000000-0000-0000-0000-0000000035e1', '00000000-0000-0000-0000-0000000035a1'),
  ('00000000-0000-0000-0000-0000000035a3', '00000000-0000-0000-0000-00000000000a', 'PMP-01', 'Pump', '00000000-0000-0000-0000-0000000035c1', '00000000-0000-0000-0000-0000000035e1', null),
  ('00000000-0000-0000-0000-0000000035b1', '00000000-0000-0000-0000-00000000000b', 'B-01', 'B asset', '00000000-0000-0000-0000-0000000035cb', '00000000-0000-0000-0000-0000000035eb', null);
-- A field made mandatory after the assets exist: a transfer is not a save, so it must not block (Â§16.1).
update public.tenant set required_asset_fields = '{serial_number}' where id = '00000000-0000-0000-0000-00000000000a';

-- Planner shape: asset_core view and update, no asset_lifecycle.
select tests.grant('00000000-0000-0000-0000-00000000000a', '00000000-0000-0000-0000-0000000000a1', 'asset_core', '{view,update}');
select tests.act_as('00000000-0000-0000-0000-0000000000a1', '00000000-0000-0000-0000-00000000000a');
select throws_ok($$select public.transfer_asset('00000000-0000-0000-0000-0000000035a1', '00000000-0000-0000-0000-0000000035e2', 'Line move')$$,
  '42501', 'not allowed to transfer asset', 'no asset_lifecycle.execute: refused');
select throws_ok($$update public.asset set location_id = '00000000-0000-0000-0000-0000000035e2' where id = '00000000-0000-0000-0000-0000000035a1'$$,
  '42501', null, 'a plain update cannot change the location (column grant)');

reset role;
select tests.grant('00000000-0000-0000-0000-00000000000a', '00000000-0000-0000-0000-0000000000a1', 'asset_lifecycle', '{execute}');
select tests.act_as('00000000-0000-0000-0000-0000000000a1', '00000000-0000-0000-0000-00000000000a');
select throws_ok($$select public.transfer_asset('00000000-0000-0000-0000-0000000035a1', '00000000-0000-0000-0000-0000000035eb', 'x')$$,
  '23514', 'location is inactive or deleted', 'another tenant''s location: refused');
select throws_ok($$select public.transfer_asset('00000000-0000-0000-0000-0000000035a1', '00000000-0000-0000-0000-0000000035e3', 'x')$$,
  '23514', 'location is inactive or deleted', 'inactive location: refused');
select throws_ok($$select public.transfer_asset('00000000-0000-0000-0000-0000000035a1', '00000000-0000-0000-0000-0000000035e1', 'x')$$,
  '22023', 'asset is already at this location', 'same location: refused');
select throws_ok($$select public.transfer_asset('00000000-0000-0000-0000-0000000035a1', '00000000-0000-0000-0000-0000000035e2', '  ')$$,
  '23502', 'a reason is required for a transfer', 'blank reason: refused');
select throws_ok($$select public.transfer_asset('00000000-0000-0000-0000-0000000035b1', '00000000-0000-0000-0000-0000000035e2', 'x')$$,
  'P0002', 'asset not found', 'another tenant''s asset: not found');
select lives_ok($$select public.transfer_asset('00000000-0000-0000-0000-0000000035a1', '00000000-0000-0000-0000-0000000035e2', 'Line move to Plant 2')$$,
  'transfer allowed, despite a mandatory gap');
select is((select h.new_data ->> 'location_reason' from public.asset_history('00000000-0000-0000-0000-0000000035a1') h limit 1),
  'Line move to Plant 2', 'the Audit tab shows the transfer with its reason');

reset role;
select results_eq(
  $$select location_id, location_reason, location_changed_at is not null, tag from public.asset where id = '00000000-0000-0000-0000-0000000035a1'$$,
  $$values ('00000000-0000-0000-0000-0000000035e2'::uuid, 'Line move to Plant 2', true, 'CNC-01')$$,
  'location, reason and time set; tag unchanged');
select is((select location_id from public.asset where id = '00000000-0000-0000-0000-0000000035a2'),
  '00000000-0000-0000-0000-0000000035e1'::uuid, 'child stays put (T3, OQ-07)');
select is((select count(*)::int from public.audit_log where table_name = 'asset' and record_id = '00000000-0000-0000-0000-0000000035a1'
             and action = 'update' and old_data ->> 'location_id' = '00000000-0000-0000-0000-0000000035e1'
             and new_data ->> 'location_id' = '00000000-0000-0000-0000-0000000035e2'
             and actor_user_id = '00000000-0000-0000-0000-0000000000a1'),
  1, 'one audit row: from, to, by');
select is((select payload from private.outbox_event where event_type = 'asset.transferred' and aggregate_id = '00000000-0000-0000-0000-0000000035a1'),
  '{"from": "00000000-0000-0000-0000-0000000035e1", "to": "00000000-0000-0000-0000-0000000035e2", "reason": "Line move to Plant 2"}'::jsonb,
  'one asset.transferred event');

-- Retire (change_asset_status to disposed).
select tests.act_as('00000000-0000-0000-0000-0000000000a1', '00000000-0000-0000-0000-00000000000a');
select throws_ok($$select public.change_asset_status('00000000-0000-0000-0000-0000000035a3', 'disposed', '')$$,
  '23502', 'a reason is required for this status change', 'retire without a reason: refused');
select lives_ok($$select public.change_asset_status('00000000-0000-0000-0000-0000000035a3', 'disposed', 'Scrapped')$$, 'retire with a reason');
select throws_ok($$select public.transfer_asset('00000000-0000-0000-0000-0000000035a3', '00000000-0000-0000-0000-0000000035e2', 'x')$$,
  '22023', 'a disposed asset cannot be transferred', 'disposed asset: transfer refused');
select throws_ok($$select public.change_asset_status('00000000-0000-0000-0000-0000000035a3', 'active', 'Back')$$,
  '42501', 'not allowed to reopen a disposed asset', 'disposed is terminal without reopen');
reset role;
select tests.grant('00000000-0000-0000-0000-00000000000a', '00000000-0000-0000-0000-0000000000a1', 'asset_lifecycle', '{reopen}');
select tests.act_as('00000000-0000-0000-0000-0000000000a1', '00000000-0000-0000-0000-00000000000a');
select throws_ok($$select public.change_asset_status('00000000-0000-0000-0000-0000000035a3', 'active', ' ')$$,
  '23502', 'a reason is required for this status change', 'reopen without a reason: refused');
select lives_ok($$select public.change_asset_status('00000000-0000-0000-0000-0000000035a3', 'active', 'Repaired spare')$$, 'admin reopen with a reason');

-- read_only tenant: every action refused.
reset role;
select tests.grant('00000000-0000-0000-0000-00000000000b', '00000000-0000-0000-0000-0000000000a1', 'asset_core');
select tests.grant('00000000-0000-0000-0000-00000000000b', '00000000-0000-0000-0000-0000000000a1', 'asset_lifecycle');
insert into public.location (id, tenant_id, name) values ('00000000-0000-0000-0000-0000000035ec', '00000000-0000-0000-0000-00000000000b', 'B site 2');
select tests.act_as('00000000-0000-0000-0000-0000000000a1', '00000000-0000-0000-0000-00000000000b');
select throws_ok($$select public.transfer_asset('00000000-0000-0000-0000-0000000035b1', '00000000-0000-0000-0000-0000000035ec', 'x')$$,
  '42501', 'not allowed to transfer asset', 'read_only tenant cannot transfer');
select throws_ok($$select public.change_asset_status('00000000-0000-0000-0000-0000000035b1', 'disposed', 'x')$$,
  '42501', null, 'read_only tenant cannot retire');

select * from finish();
rollback;
