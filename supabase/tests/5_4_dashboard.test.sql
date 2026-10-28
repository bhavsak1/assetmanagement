-- Story 5.4: Dashboard location counts (location_asset_counts). docs/data-model-goal5.md §14.
-- Uses the seed (tenant A active in Asia/Kolkata, B read_only; a1 in A and B, no groups)
-- and supabase/test_harness.sql. The tiles reuse count_assets and maintenance_counts (3.2, 5.3 tests).
begin;
select plan(9);

create function pg_temp.d(n int) returns date language sql as $$
  select (now() at time zone 'Asia/Kolkata')::date + n;
$$;
-- Location name by id, read past RLS (a1 holds no location grant).
create function pg_temp.loc(p_id uuid) returns text language sql security definer as $$
  select coalesce((select name from public.location where id = p_id), '-');
$$;
-- 'location:assets:overdue' rows, by location name ('-' = no location).
create function pg_temp.counts() returns text language sql as $$
  select string_agg(pg_temp.loc(c.location_id) || ':' || c.assets || ':' || c.overdue, ',' order by pg_temp.loc(c.location_id))
  from public.location_asset_counts() c;
$$;

-- Fixtures, as postgres. Locations: Pune > Plant 1. Assets: Lathe in Plant 1, Pump in Pune, Spare nowhere,
-- Gone deleted in Plant 1, a tenant B asset.
insert into public.location (id, tenant_id, parent_id, name) values
  ('00000000-0000-0000-0000-00000054d001', '00000000-0000-0000-0000-00000000000a', null, 'Pune'),
  ('00000000-0000-0000-0000-00000054d002', '00000000-0000-0000-0000-00000000000a', '00000000-0000-0000-0000-00000054d001', 'Plant 1'),
  ('00000000-0000-0000-0000-00000054d00b', '00000000-0000-0000-0000-00000000000b', null, 'B site');
insert into public.asset_category (id, tenant_id, name) values
  ('00000000-0000-0000-0000-00000054c001', '00000000-0000-0000-0000-00000000000a', 'Machines'),
  ('00000000-0000-0000-0000-00000054c00b', '00000000-0000-0000-0000-00000000000b', 'B cat');
insert into public.asset (id, tenant_id, tag, name, location_id, category_id) values
  ('00000000-0000-0000-0000-00000054a001', '00000000-0000-0000-0000-00000000000a', 'LTH-1', 'Lathe', '00000000-0000-0000-0000-00000054d002', '00000000-0000-0000-0000-00000054c001'),
  ('00000000-0000-0000-0000-00000054a002', '00000000-0000-0000-0000-00000000000a', 'PMP-1', 'Pump', '00000000-0000-0000-0000-00000054d001', '00000000-0000-0000-0000-00000054c001'),
  ('00000000-0000-0000-0000-00000054a003', '00000000-0000-0000-0000-00000000000a', 'SPR-1', 'Spare', null, '00000000-0000-0000-0000-00000054c001'),
  ('00000000-0000-0000-0000-00000054a004', '00000000-0000-0000-0000-00000000000a', 'GON-1', 'Gone', '00000000-0000-0000-0000-00000054d002', '00000000-0000-0000-0000-00000054c001'),
  ('00000000-0000-0000-0000-00000054a0bb', '00000000-0000-0000-0000-00000000000b', 'B-1', 'B asset', '00000000-0000-0000-0000-00000054d00b', '00000000-0000-0000-0000-00000054c00b');
insert into public.obligation (tenant_id, asset_id, name, obligation_type, interval_count, interval_unit, anchor, first_due_date)
select t, a, n, 'service', 1, 'year', 'completion', pg_temp.d(f)
from (values
  ('00000000-0000-0000-0000-00000000000a'::uuid, '00000000-0000-0000-0000-00000054a001'::uuid, 'od1', -10),
  ('00000000-0000-0000-0000-00000000000a'::uuid, '00000000-0000-0000-0000-00000054a001'::uuid, 'od2', -3),
  ('00000000-0000-0000-0000-00000000000a'::uuid, '00000000-0000-0000-0000-00000054a001'::uuid, 'ds1', 5),
  ('00000000-0000-0000-0000-00000000000a'::uuid, '00000000-0000-0000-0000-00000054a001'::uuid, 'rm', -5),
  ('00000000-0000-0000-0000-00000000000a'::uuid, '00000000-0000-0000-0000-00000054a002'::uuid, 'od3', -5),
  ('00000000-0000-0000-0000-00000000000a'::uuid, '00000000-0000-0000-0000-00000054a004'::uuid, 'del', -5),
  ('00000000-0000-0000-0000-00000000000b'::uuid, '00000000-0000-0000-0000-00000054a0bb'::uuid, 'bod', -5)
) v (t, a, n, f);
update public.asset set deleted_at = now() where id = '00000000-0000-0000-0000-00000054a004';
update public.obligation set deleted_at = now() where name = 'rm';

-- Permission steps for a1 in tenant A.
select tests.act_as('00000000-0000-0000-0000-0000000000a1', '00000000-0000-0000-0000-00000000000a');
select is((select count(*)::int from public.location_asset_counts()), 0, 'no grant: nothing');
reset role;
select tests.grant('00000000-0000-0000-0000-00000000000a', '00000000-0000-0000-0000-0000000000a1', 'asset_core', '{view}');
select tests.act_as('00000000-0000-0000-0000-0000000000a1', '00000000-0000-0000-0000-00000000000a');
select is(pg_temp.counts(), '-:1:0,Plant 1:1:0,Pune:1:0', 'asset_core.view only: assets counted, overdue 0');
reset role;
select tests.grant('00000000-0000-0000-0000-00000000000a', '00000000-0000-0000-0000-0000000000a1', 'obligation', '{view}');
select tests.act_as('00000000-0000-0000-0000-0000000000a1', '00000000-0000-0000-0000-00000000000a');
select is(pg_temp.counts(), '-:1:0,Plant 1:1:2,Pune:1:1',
  'per asset location; deleted asset, deleted obligation, due soon and tenant B not counted');
select is((select sum(assets)::int from public.location_asset_counts()), public.count_assets(), 'assets add up to count_assets()');
select is((select sum(overdue)::int from public.location_asset_counts()), (select overdue from public.maintenance_counts()),
  'overdue adds up to maintenance_counts().overdue');
select is((select assets from public.location_asset_counts() where location_id = '00000000-0000-0000-0000-00000054d002'),
  public.count_assets(p_location_id => '00000000-0000-0000-0000-00000054d002'), 'a leaf matches count_assets(p_location_id)');
select is((select overdue from public.maintenance_counts(p_location_id => '00000000-0000-0000-0000-00000054d001')), 3,
  'the web roll-up (Pune = Pune + Plant 1 = 3 overdue) matches maintenance_counts for the subtree');

-- Cross-tenant: a1 in tenant B sees only B.
reset role;
select tests.grant('00000000-0000-0000-0000-00000000000b', '00000000-0000-0000-0000-0000000000a1', 'obligation', '{view}');
select tests.grant('00000000-0000-0000-0000-00000000000b', '00000000-0000-0000-0000-0000000000a1', 'asset_core', '{view}');
select tests.act_as('00000000-0000-0000-0000-0000000000a1', '00000000-0000-0000-0000-00000000000b');
select is(pg_temp.counts(), 'B site:1:1', 'tenant B: only B rows');
reset role;
select tests.act_as('00000000-0000-0000-0000-0000000000a1', '00000000-0000-0000-0000-00000000000a');
select isnt((select string_agg(location_id::text, ',') from public.location_asset_counts()) like '%54d00b%', true,
  'tenant A: no tenant B location');

select * from finish();
rollback;
