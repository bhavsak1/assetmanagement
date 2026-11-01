-- Story 6.1: scope profiles and row scope (docs/data-model-goal6.md §9).
-- Uses the seed (tenant A active, B read_only; a1 in A and B) and supabase/test_harness.sql.
begin;
select plan(66);

-- Fixtures, as postgres. Pune > Pune block > Pune bay, and Mumbai. Pumps > Small pumps, and Motors.
insert into public.location (id, tenant_id, parent_id, name) values
  ('00000000-0000-0000-0000-0000000061e1', '00000000-0000-0000-0000-00000000000a', null, 'Pune'),
  ('00000000-0000-0000-0000-0000000061e2', '00000000-0000-0000-0000-00000000000a', '00000000-0000-0000-0000-0000000061e1', 'Pune block'),
  ('00000000-0000-0000-0000-0000000061e3', '00000000-0000-0000-0000-00000000000a', '00000000-0000-0000-0000-0000000061e2', 'Pune bay'),
  ('00000000-0000-0000-0000-0000000061e4', '00000000-0000-0000-0000-00000000000a', null, 'Mumbai'),
  ('00000000-0000-0000-0000-0000000061eb', '00000000-0000-0000-0000-00000000000b', null, 'B site');
insert into public.asset_category (id, tenant_id, parent_id, name) values
  ('00000000-0000-0000-0000-0000000061c1', '00000000-0000-0000-0000-00000000000a', null, 'S61 Pumps'),
  ('00000000-0000-0000-0000-0000000061c2', '00000000-0000-0000-0000-00000000000a', null, 'S61 Motors'),
  ('00000000-0000-0000-0000-0000000061c3', '00000000-0000-0000-0000-00000000000a', '00000000-0000-0000-0000-0000000061c1', 'S61 Small pumps');
insert into public.asset (id, tenant_id, tag, name, category_id, location_id) values
  ('00000000-0000-0000-0000-0000000061a1', '00000000-0000-0000-0000-00000000000a', 'S61-P1', 'Pune pump', '00000000-0000-0000-0000-0000000061c1', '00000000-0000-0000-0000-0000000061e1'),
  ('00000000-0000-0000-0000-0000000061a2', '00000000-0000-0000-0000-00000000000a', 'S61-P2', 'Pune bay motor', '00000000-0000-0000-0000-0000000061c2', '00000000-0000-0000-0000-0000000061e3'),
  ('00000000-0000-0000-0000-0000000061a3', '00000000-0000-0000-0000-00000000000a', 'S61-M1', 'Mumbai pump', '00000000-0000-0000-0000-0000000061c1', '00000000-0000-0000-0000-0000000061e4'),
  ('00000000-0000-0000-0000-0000000061a4', '00000000-0000-0000-0000-00000000000a', 'S61-M2', 'Mumbai motor', '00000000-0000-0000-0000-0000000061c2', '00000000-0000-0000-0000-0000000061e4'),
  ('00000000-0000-0000-0000-0000000061a5', '00000000-0000-0000-0000-00000000000a', 'S61-N1', 'Unplaced pump', '00000000-0000-0000-0000-0000000061c1', null),
  ('00000000-0000-0000-0000-0000000061a6', '00000000-0000-0000-0000-00000000000a', 'S61-M3', 'Mumbai small pump', '00000000-0000-0000-0000-0000000061c3', '00000000-0000-0000-0000-0000000061e4');
insert into public.scope_profile (id, tenant_id, name) values
  ('00000000-0000-0000-0000-0000000061f1', '00000000-0000-0000-0000-00000000000a', 'Pune plant'),
  ('00000000-0000-0000-0000-0000000061f2', '00000000-0000-0000-0000-00000000000a', 'Mumbai pumps'),
  ('00000000-0000-0000-0000-0000000061f3', '00000000-0000-0000-0000-00000000000a', 'Empty'),
  ('00000000-0000-0000-0000-0000000061f4', '00000000-0000-0000-0000-00000000000a', 'All pumps'),
  ('00000000-0000-0000-0000-0000000061fb', '00000000-0000-0000-0000-00000000000b', 'B profile');
insert into public.scope_profile_rule (id, tenant_id, scope_profile_id, dimension, location_id, category_id) values
  ('00000000-0000-0000-0000-0000000061d1', '00000000-0000-0000-0000-00000000000a', '00000000-0000-0000-0000-0000000061f1', 'location', '00000000-0000-0000-0000-0000000061e1', null),
  ('00000000-0000-0000-0000-0000000061d2', '00000000-0000-0000-0000-00000000000a', '00000000-0000-0000-0000-0000000061f2', 'location', '00000000-0000-0000-0000-0000000061e4', null),
  ('00000000-0000-0000-0000-0000000061d3', '00000000-0000-0000-0000-00000000000a', '00000000-0000-0000-0000-0000000061f2', 'category', null, '00000000-0000-0000-0000-0000000061c1'),
  ('00000000-0000-0000-0000-0000000061d4', '00000000-0000-0000-0000-00000000000a', '00000000-0000-0000-0000-0000000061f4', 'category', null, '00000000-0000-0000-0000-0000000061c1');
-- Children: one obligation, service record and file per Pune pump and Mumbai pump. Contracts: Mumbai only,
-- Pune and Mumbai, none.
insert into public.obligation (id, tenant_id, asset_id, name, obligation_type, interval_count, interval_unit, anchor, first_due_date)
select ('00000000-0000-0000-0001-0000000061' || s)::uuid, '00000000-0000-0000-0000-00000000000a',
       ('00000000-0000-0000-0000-0000000061' || s)::uuid, 'Service', 'service', 3, 'month', 'completion', current_date + 30
from unnest(array['a1', 'a3']) s;
insert into public.service_record (id, tenant_id, obligation_id, asset_id, done_on, advanced)
select ('00000000-0000-0000-0002-0000000061' || s)::uuid, '00000000-0000-0000-0000-00000000000a',
       ('00000000-0000-0000-0001-0000000061' || s)::uuid, ('00000000-0000-0000-0000-0000000061' || s)::uuid,
       current_date - 10, false
from unnest(array['a1', 'a3']) s;
select set_config('request.jwt.claims', '', true);
insert into storage.objects (bucket_id, name, metadata)
select 'attachments', '00000000-0000-0000-0000-00000000000a/asset/' || a.id || '/' || a.id, '{"size": 1, "mimetype": "text/plain"}'
from public.asset a where a.tag in ('S61-P1', 'S61-M1');
insert into public.asset_attachment (id, tenant_id, asset_id, file_name)
select a.id, a.tenant_id, a.id, 'f' from public.asset a where a.tag in ('S61-P1', 'S61-M1');
insert into storage.objects (bucket_id, name, metadata)
select 'attachments', r.tenant_id || '/service_record/' || r.id || '/' || r.id, '{"size": 1, "mimetype": "text/plain"}'
from public.service_record r where r.obligation_id in (select id from public.obligation where name = 'Service' and asset_id::text like '%61a_');
insert into public.service_record_attachment (id, tenant_id, service_record_id, file_name)
select r.id, r.tenant_id, r.id, 'f' from public.service_record r
where r.obligation_id in (select id from public.obligation where name = 'Service' and asset_id::text like '%61a_');
insert into public.vendor (id, tenant_id, name) values
  ('00000000-0000-0000-0000-000000006100', '00000000-0000-0000-0000-00000000000a', 'S61 vendor');
insert into public.coverage (id, tenant_id, coverage_type, vendor_id, reference, start_date, end_date)
select ('00000000-0000-0000-0000-00000000610' || n)::uuid, '00000000-0000-0000-0000-00000000000a', 'amc',
       '00000000-0000-0000-0000-000000006100', 'S61-' || n, current_date - 1, current_date + 300
from generate_series(1, 3) n;
insert into public.coverage_asset (tenant_id, coverage_id, asset_id) values
  ('00000000-0000-0000-0000-00000000000a', '00000000-0000-0000-0000-000000006101', '00000000-0000-0000-0000-0000000061a3'),
  ('00000000-0000-0000-0000-00000000000a', '00000000-0000-0000-0000-000000006102', '00000000-0000-0000-0000-0000000061a1'),
  ('00000000-0000-0000-0000-00000000000a', '00000000-0000-0000-0000-000000006102', '00000000-0000-0000-0000-0000000061a3');

-- Grant a1 in tenant A operations through a new group, scoped to p_profile (null = tenant-wide).
create function pg_temp.grant_scoped(p_domain text, p_ops text[], p_profile uuid) returns void language plpgsql as $$
declare
  v_before uuid[] := array(select id from public.user_group_assignment
                           where tenant_id = '00000000-0000-0000-0000-00000000000a' and user_id = '00000000-0000-0000-0000-0000000000a1');
begin
  perform tests.grant('00000000-0000-0000-0000-00000000000a', '00000000-0000-0000-0000-0000000000a1', p_domain, p_ops);
  update public.user_group_assignment set scope_profile_id = p_profile
  where tenant_id = '00000000-0000-0000-0000-00000000000a' and user_id = '00000000-0000-0000-0000-0000000000a1'
    and not (id = any (v_before));
end;
$$;
-- Remove every grant of a1 in tenant A.
create function pg_temp.clear() returns void language sql as $$
  update public.user_group_assignment set deleted_at = now()
  where tenant_id = '00000000-0000-0000-0000-00000000000a' and user_id = '00000000-0000-0000-0000-0000000000a1' and deleted_at is null;
$$;
-- Tags a1 sees in asset_view (fixture assets only).
create function pg_temp.seen() returns text[] language sql as $$
  select array(select tag from public.asset_view where tag like 'S61-%' order by tag);
$$;
grant execute on all functions in schema pg_temp to authenticated;

-- 1. Pune manager: Pune and below, not Mumbai, not the unplaced asset (S5).
select pg_temp.grant_scoped('asset_core', '{view}', '00000000-0000-0000-0000-0000000061f1');
select is((select count(*)::int from private.user_effective_permission
           where tenant_id = '00000000-0000-0000-0000-00000000000a' and user_id = '00000000-0000-0000-0000-0000000000a1'
             and scope_profile_id = '00000000-0000-0000-0000-0000000061f1'), 1, 'the rebuild copies scope_profile_id');
select tests.act_as('00000000-0000-0000-0000-0000000000a1', '00000000-0000-0000-0000-00000000000a');
select is(pg_temp.seen(), '{S61-P1,S61-P2}', 'Pune manager: asset_view shows Pune and its bay, not Mumbai');
select is(array(select tag from public.asset where tag like 'S61-%' order by tag), '{S61-P1,S61-P2}', 'asset table: same');
select is((select count(*)::int from public.list_assets(p_term => 'S61')), 2, 'list_assets search: Pune only');
select is((select public.count_assets(p_term => 'S61')), 2, 'count_assets: Pune only');
select is((select count(*)::int from public.asset_history('00000000-0000-0000-0000-0000000061a3')), 0, 'asset_history: Mumbai asset hidden');
select isnt((select count(*)::int from public.asset_history('00000000-0000-0000-0000-0000000061a1')), 0, 'asset_history: Pune asset shown');
select is((select assets from public.location_asset_counts() where location_id = '00000000-0000-0000-0000-0000000061e4'), null,
  'location_asset_counts: no Mumbai assets');
select is((select active from public.location_status_counts() where location_id = '00000000-0000-0000-0000-0000000061e3'), 1,
  'location_status_counts: the Pune bay asset counts');
select is((select active from public.location_status_counts() where location_id = '00000000-0000-0000-0000-0000000061e4'), null,
  'location_status_counts: no Mumbai row');
reset role;

-- 2. Union (§3): Pune, plus Mumbai pumps (location AND category, child categories included).
select pg_temp.grant_scoped('asset_core', '{view}', '00000000-0000-0000-0000-0000000061f2');
select tests.act_as('00000000-0000-0000-0000-0000000000a1', '00000000-0000-0000-0000-00000000000a');
select is(pg_temp.seen(), '{S61-M1,S61-M3,S61-P1,S61-P2}', 'two profiles: Pune plus Mumbai pumps, not Mumbai motors');
reset role;

-- 3. Scoped plus tenant-wide = tenant-wide.
select pg_temp.grant_scoped('asset_core', '{view}', null);
select tests.act_as('00000000-0000-0000-0000-0000000000a1', '00000000-0000-0000-0000-00000000000a');
select is(pg_temp.seen(), '{S61-M1,S61-M2,S61-M3,S61-N1,S61-P1,S61-P2}', 'a tenant-wide grant wins');
reset role;

-- 4. Category only: every pump, wherever it is, unplaced included.
select pg_temp.clear();
select pg_temp.grant_scoped('asset_core', '{view}', '00000000-0000-0000-0000-0000000061f4');
select tests.act_as('00000000-0000-0000-0000-0000000000a1', '00000000-0000-0000-0000-00000000000a');
select is(pg_temp.seen(), '{S61-M1,S61-M3,S61-N1,S61-P1}', 'category rule: pumps and small pumps anywhere');
reset role;

-- 5. Empty profile grants nothing (S4); a profile whose rules are all removed likewise.
select pg_temp.clear();
select pg_temp.grant_scoped('asset_core', '{view}', '00000000-0000-0000-0000-0000000061f3');
select tests.act_as('00000000-0000-0000-0000-0000000000a1', '00000000-0000-0000-0000-00000000000a');
select is(pg_temp.seen(), '{}', 'empty profile: nothing');
select ok((select private.has_permission('asset_core', 'view')), 'has_permission still true (scope is a separate clause)');
reset role;

-- 6. Rule edits act at once, with no rebuild.
select pg_temp.clear();
select pg_temp.grant_scoped('asset_core', '{view}', '00000000-0000-0000-0000-0000000061f1');
insert into public.scope_profile_rule (id, tenant_id, scope_profile_id, dimension, location_id) values
  ('00000000-0000-0000-0000-0000000061d5', '00000000-0000-0000-0000-00000000000a', '00000000-0000-0000-0000-0000000061f1', 'location', '00000000-0000-0000-0000-0000000061e4');
select tests.act_as('00000000-0000-0000-0000-0000000000a1', '00000000-0000-0000-0000-00000000000a');
select is(pg_temp.seen(), '{S61-M1,S61-M2,S61-M3,S61-P1,S61-P2}', 'rule added: Mumbai shows');
reset role;
update public.scope_profile_rule set deleted_at = now() where id in ('00000000-0000-0000-0000-0000000061d5', '00000000-0000-0000-0000-0000000061d1');
select tests.act_as('00000000-0000-0000-0000-0000000000a1', '00000000-0000-0000-0000-00000000000a');
select is(pg_temp.seen(), '{}', 'last rule removed: nothing (S4)');
reset role;
update public.scope_profile_rule set deleted_at = null where id = '00000000-0000-0000-0000-0000000061d1';

-- 7. Expired scoped assignment gives nothing; a profile in use cannot be deleted.
select throws_ok($$update public.scope_profile set deleted_at = now() where id = '00000000-0000-0000-0000-0000000061f1'$$,
  '23503', 'scope profile is assigned', 'an assigned profile cannot be deleted');
update public.user_group_assignment set effective_from = now() - interval '2 days', effective_to = now() - interval '1 day'
where tenant_id = '00000000-0000-0000-0000-00000000000a' and user_id = '00000000-0000-0000-0000-0000000000a1' and deleted_at is null;
select tests.act_as('00000000-0000-0000-0000-0000000000a1', '00000000-0000-0000-0000-00000000000a');
select is(pg_temp.seen(), '{}', 'expired scoped assignment: nothing');
reset role;

-- 8. Children follow their asset, under each child grant's own scope (S2). Asset view is tenant-wide here.
select pg_temp.clear();
select pg_temp.grant_scoped('asset_core', '{view}', null);
select pg_temp.grant_scoped('obligation', '{view}', '00000000-0000-0000-0000-0000000061f1');
select pg_temp.grant_scoped('service_record', '{view}', '00000000-0000-0000-0000-0000000061f1');
select pg_temp.grant_scoped('coverage_contract', '{view}', '00000000-0000-0000-0000-0000000061f1');
select pg_temp.grant_scoped('asset_attachment', '{view}', '00000000-0000-0000-0000-0000000061f1');
select tests.act_as('00000000-0000-0000-0000-0000000000a1', '00000000-0000-0000-0000-00000000000a');
select is(array(select asset_id from public.obligation where asset_id::text like '%61a_'),
  '{00000000-0000-0000-0000-0000000061a1}'::uuid[], 'obligation: Pune only, though asset view is tenant-wide');
select is((select sum((select count(*) from public.list_obligations(b, p_term => 'S61')))::int
           from unnest(array['overdue', 'due_soon', 'scheduled']) b), 1, 'list_obligations: Pune only');
select is(array(select asset_id from public.service_record where asset_id::text like '%61a_'),
  '{00000000-0000-0000-0000-0000000061a1}'::uuid[], 'service_record: Pune only');
select is(array(select asset_id from public.service_record_view where asset_id::text like '%61a_'),
  '{00000000-0000-0000-0000-0000000061a1}'::uuid[], 'service_record_view: Pune only');
select is(array(select asset_id from public.coverage_asset where coverage_id::text like '%61__'),
  '{00000000-0000-0000-0000-0000000061a1}'::uuid[], 'coverage_asset: Pune link only');
select is(array(select reference from public.coverage_view where reference like 'S61-%' order by reference),
  '{S61-2,S61-3}', 'coverage_view: Mumbai-only contract hidden; shared and unlinked shown (OQ-26)');
select is(array(select asset_id from public.asset_attachment where asset_id::text like '%61a_'),
  '{00000000-0000-0000-0000-0000000061a1}'::uuid[], 'asset_attachment: Pune only');
select is(array(select r.asset_id from public.service_record_attachment f join public.service_record r on r.id = f.service_record_id
                where r.asset_id::text like '%61a_'),
  '{00000000-0000-0000-0000-0000000061a1}'::uuid[], 'service_record_attachment: Pune only');
select is((select count(*)::int from storage.objects where bucket_id = 'attachments' and name like '%/asset/%61a3/%'), 0,
  'storage: Mumbai files not readable');
select is((select count(*)::int from storage.objects where bucket_id = 'attachments' and name like '%/asset/%61a1/%'), 1,
  'storage: Pune asset file readable');
reset role;

-- 9. Writes (S6), all scoped to Pune.
select pg_temp.clear();
select pg_temp.grant_scoped('asset_core', '{view,create,update}', '00000000-0000-0000-0000-0000000061f1');
select pg_temp.grant_scoped('asset_lifecycle', '{execute}', '00000000-0000-0000-0000-0000000061f1');
select pg_temp.grant_scoped('obligation', '{view,complete}', '00000000-0000-0000-0000-0000000061f1');
select pg_temp.grant_scoped('service_record', '{view,update}', '00000000-0000-0000-0000-0000000061f1');
select pg_temp.grant_scoped('asset_attachment', '{create}', '00000000-0000-0000-0000-0000000061f1');
select tests.act_as('00000000-0000-0000-0000-0000000000a1', '00000000-0000-0000-0000-00000000000a');
update public.asset set name = 'x' where id = '00000000-0000-0000-0000-0000000061a3';
update public.asset set name = 'Pune pump 2' where id = '00000000-0000-0000-0000-0000000061a1';
reset role;
select is(array(select name from public.asset where id in ('00000000-0000-0000-0000-0000000061a1', '00000000-0000-0000-0000-0000000061a3') order by tag),
  '{Mumbai pump,Pune pump 2}', 'update of a Mumbai asset touches nothing; a Pune one works');
select tests.act_as('00000000-0000-0000-0000-0000000000a1', '00000000-0000-0000-0000-00000000000a');
select throws_ok($$insert into public.asset (tenant_id, name, category_id, location_id) values
  ('00000000-0000-0000-0000-00000000000a', 'x', '00000000-0000-0000-0000-0000000061c1', '00000000-0000-0000-0000-0000000061e4')$$,
  '42501', 'new row violates row-level security policy for table "asset"', 'insert in Mumbai refused');
select lives_ok($$insert into public.asset (tenant_id, name, category_id, location_id) values
  ('00000000-0000-0000-0000-00000000000a', 'x', '00000000-0000-0000-0000-0000000061c1', '00000000-0000-0000-0000-0000000061e2')$$,
  'insert in a Pune block works');
select throws_ok($$select public.transfer_asset('00000000-0000-0000-0000-0000000061a1', '00000000-0000-0000-0000-0000000061e4', 'Move')$$,
  '42501', 'location is outside your scope', 'transfer Pune to Mumbai refused');
select throws_ok($$select public.transfer_asset('00000000-0000-0000-0000-0000000061a3', '00000000-0000-0000-0000-0000000061e1', 'Move')$$,
  'P0002', 'asset not found', 'transfer of a Mumbai asset: not found');
select lives_ok($$select public.transfer_asset('00000000-0000-0000-0000-0000000061a1', '00000000-0000-0000-0000-0000000061e3', 'Move')$$,
  'transfer within Pune works');
select throws_ok($$select public.change_asset_status('00000000-0000-0000-0000-0000000061a3', 'inactive', 'x')$$,
  'P0002', 'asset not found', 'status change on a Mumbai asset: not found');
select is((select count(*)::int from public.allowed_asset_statuses('00000000-0000-0000-0000-0000000061a3')), 0,
  'allowed_asset_statuses: none for a Mumbai asset');
select throws_ok($$select public.complete_obligation('00000000-0000-0000-0001-0000000061a3', current_date)$$,
  'P0002', 'obligation not found', 'completion of a Mumbai obligation: not found');
select lives_ok($$select public.complete_obligation('00000000-0000-0000-0001-0000000061a1', current_date)$$,
  'completion of a Pune obligation works');
select throws_ok($$select public.undo_completion('00000000-0000-0000-0002-0000000061a3')$$,
  'P0002', 'service record not found', 'undo of a Mumbai record: not found');
select ok(not private.can_upload_attachment('00000000-0000-0000-0000-00000000000a/asset/00000000-0000-0000-0000-0000000061a3/'
                                            || gen_random_uuid()), 'upload for a Mumbai asset refused');
select ok(private.can_upload_attachment('00000000-0000-0000-0000-00000000000a/asset/00000000-0000-0000-0000-0000000061a1/'
                                        || gen_random_uuid()), 'upload for a Pune asset allowed');
reset role;

-- 10. Category rule on writes: a Mumbai-pumps user cannot recategorise a pump to a motor.
select pg_temp.clear();
select pg_temp.grant_scoped('asset_core', '{view,update}', '00000000-0000-0000-0000-0000000061f2');
select tests.act_as('00000000-0000-0000-0000-0000000000a1', '00000000-0000-0000-0000-00000000000a');
select throws_ok($$update public.asset set category_id = '00000000-0000-0000-0000-0000000061c2' where id = '00000000-0000-0000-0000-0000000061a3'$$,
  '42501', 'new row violates row-level security policy for table "asset"', 'moving an asset out of category scope refused');
reset role;

-- 11. scope_profile and scope_profile_rule: the 1.4 permission steps and the cross-tenant harness.
select pg_temp.clear();
select tests.act_as('00000000-0000-0000-0000-0000000000a1', '00000000-0000-0000-0000-00000000000a');
select is_empty($$select 1 from public.scope_profile$$, 'no grant: no profiles');
select throws_ok($$insert into public.scope_profile (tenant_id, name) values ('00000000-0000-0000-0000-00000000000a', 'x')$$,
  '42501', null, 'no grant: insert refused');
reset role;
select pg_temp.grant_scoped('users_security', '{view}', null);
select tests.act_as('00000000-0000-0000-0000-0000000000a1', '00000000-0000-0000-0000-00000000000a');
select is((select count(*)::int from public.scope_profile_rule where scope_profile_id = '00000000-0000-0000-0000-0000000061f2'), 2,
  'users_security.view: rules readable');
select throws_ok($$insert into public.scope_profile (tenant_id, name) values ('00000000-0000-0000-0000-00000000000a', 'x')$$,
  '42501', null, 'view only: insert refused');
reset role;
select pg_temp.grant_scoped('users_security', '{manage}', null);
select tests.act_as('00000000-0000-0000-0000-0000000000a1', '00000000-0000-0000-0000-00000000000a');
select lives_ok($$insert into public.scope_profile (tenant_id, name) values ('00000000-0000-0000-0000-00000000000a', 'Chennai')$$,
  'manage: insert works');
select throws_ok($$delete from public.scope_profile where name = 'Chennai'$$, '42501', null, 'no hard delete');
reset role;
select is((select category from public.audit_log where table_name = 'scope_profile' order by occurred_at desc limit 1), 'security',
  'profile changes are security audit rows');

select * from tests.cross_tenant('public.scope_profile', 'users_security', '{"name":"ct-row"}');
select * from tests.cross_tenant('public.scope_profile_rule', 'users_security',
  '{"scope_profile_id":"00000000-0000-0000-0000-0000000061f3","dimension":"location","location_id":"00000000-0000-0000-0000-0000000061e4"}',
  '{"scope_profile_id":"00000000-0000-0000-0000-0000000061fb","location_id":"00000000-0000-0000-0000-0000000061eb"}');

select * from finish();
rollback;
