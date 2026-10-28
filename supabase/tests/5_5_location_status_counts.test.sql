-- Story 5.5: Locations status counts (location_status_counts). docs/data-model-goal5.md §15.1.
-- Uses the seed (tenant A active in Asia/Kolkata, B read_only; a1 in A and B, no groups)
-- and supabase/test_harness.sql.
begin;
select plan(11);

create function pg_temp.d(n int) returns date language sql as $$
  select (now() at time zone 'Asia/Kolkata')::date + n;
$$;
-- Location name by id, read past RLS (a1 holds no location grant).
create function pg_temp.loc(p_id uuid) returns text language sql security definer as $$
  select coalesce((select name from public.location where id = p_id), '-');
$$;
-- 'location:in_stock/active/under_maintenance/inactive/disposed:overdue' rows, by location name.
create function pg_temp.counts() returns text language sql as $$
  select string_agg(pg_temp.loc(c.location_id) || ':' || concat_ws('/', c.in_stock, c.active, c.under_maintenance,
                    c.inactive, c.disposed) || ':' || c.overdue, ',' order by pg_temp.loc(c.location_id))
  from public.location_status_counts() c;
$$;

-- Fixtures, as postgres. Pune > Plant 1. Plant 1: one asset per status plus a deleted one; Pune: one active;
-- one in stock with no location; a tenant B asset.
insert into public.location (id, tenant_id, parent_id, name) values
  ('00000000-0000-0000-0000-00000055d001', '00000000-0000-0000-0000-00000000000a', null, 'Pune'),
  ('00000000-0000-0000-0000-00000055d002', '00000000-0000-0000-0000-00000000000a', '00000000-0000-0000-0000-00000055d001', 'Plant 1'),
  ('00000000-0000-0000-0000-00000055d00b', '00000000-0000-0000-0000-00000000000b', null, 'B site');
insert into public.asset_category (id, tenant_id, name) values
  ('00000000-0000-0000-0000-00000055c001', '00000000-0000-0000-0000-00000000000a', 'Machines'),
  ('00000000-0000-0000-0000-00000055c00b', '00000000-0000-0000-0000-00000000000b', 'B cat');
insert into public.asset (id, tenant_id, tag, name, status, location_id, category_id)
select ('00000000-0000-0000-0000-00000055a0' || k)::uuid, t::uuid, 'T-' || k, 'A ' || k, s, l::uuid, c::uuid
from (values
  ('01', '00000000-0000-0000-0000-00000000000a', 'in_stock',          '00000000-0000-0000-0000-00000055d002', '00000000-0000-0000-0000-00000055c001'),
  ('02', '00000000-0000-0000-0000-00000000000a', 'active',            '00000000-0000-0000-0000-00000055d002', '00000000-0000-0000-0000-00000055c001'),
  ('03', '00000000-0000-0000-0000-00000000000a', 'under_maintenance', '00000000-0000-0000-0000-00000055d002', '00000000-0000-0000-0000-00000055c001'),
  ('04', '00000000-0000-0000-0000-00000000000a', 'inactive',          '00000000-0000-0000-0000-00000055d002', '00000000-0000-0000-0000-00000055c001'),
  ('05', '00000000-0000-0000-0000-00000000000a', 'disposed',          '00000000-0000-0000-0000-00000055d002', '00000000-0000-0000-0000-00000055c001'),
  ('06', '00000000-0000-0000-0000-00000000000a', 'active',            '00000000-0000-0000-0000-00000055d002', '00000000-0000-0000-0000-00000055c001'),
  ('07', '00000000-0000-0000-0000-00000000000a', 'active',            '00000000-0000-0000-0000-00000055d001', '00000000-0000-0000-0000-00000055c001'),
  ('08', '00000000-0000-0000-0000-00000000000a', 'in_stock',          null,                                   '00000000-0000-0000-0000-00000055c001'),
  ('bb', '00000000-0000-0000-0000-00000000000b', 'active',            '00000000-0000-0000-0000-00000055d00b', '00000000-0000-0000-0000-00000055c00b')
) v (k, t, s, l, c);
insert into public.obligation (tenant_id, asset_id, name, obligation_type, interval_count, interval_unit, anchor, first_due_date)
select t, a, n, 'service', 1, 'year', 'completion', pg_temp.d(f)
from (values
  ('00000000-0000-0000-0000-00000000000a'::uuid, '00000000-0000-0000-0000-00000055a002'::uuid, 'od1', -10),
  ('00000000-0000-0000-0000-00000000000a'::uuid, '00000000-0000-0000-0000-00000055a003'::uuid, 'od2', -3),
  ('00000000-0000-0000-0000-00000000000a'::uuid, '00000000-0000-0000-0000-00000055a002'::uuid, 'ds1', 5),
  ('00000000-0000-0000-0000-00000000000a'::uuid, '00000000-0000-0000-0000-00000055a002'::uuid, 'rm', -5),
  ('00000000-0000-0000-0000-00000000000a'::uuid, '00000000-0000-0000-0000-00000055a007'::uuid, 'od3', -5),
  ('00000000-0000-0000-0000-00000000000a'::uuid, '00000000-0000-0000-0000-00000055a006'::uuid, 'del', -5),
  ('00000000-0000-0000-0000-00000000000b'::uuid, '00000000-0000-0000-0000-00000055a0bb'::uuid, 'bod', -5)
) v (t, a, n, f);
update public.asset set deleted_at = now() where id = '00000000-0000-0000-0000-00000055a006';
update public.obligation set deleted_at = now() where name = 'rm';

-- Permission steps for a1 in tenant A.
select tests.act_as('00000000-0000-0000-0000-0000000000a1', '00000000-0000-0000-0000-00000000000a');
select is((select count(*)::int from public.location_status_counts()), 0, 'no grant: nothing');
reset role;
select tests.grant('00000000-0000-0000-0000-00000000000a', '00000000-0000-0000-0000-0000000000a1', 'asset_core', '{view}');
select tests.act_as('00000000-0000-0000-0000-0000000000a1', '00000000-0000-0000-0000-00000000000a');
select is(pg_temp.counts(), '-:1/0/0/0/0:0,Plant 1:1/1/1/1/1:0,Pune:0/1/0/0/0:0',
  'asset_core.view only: one count per system status, deleted asset out, overdue 0');
reset role;
select tests.grant('00000000-0000-0000-0000-00000000000a', '00000000-0000-0000-0000-0000000000a1', 'obligation', '{view}');
select tests.act_as('00000000-0000-0000-0000-0000000000a1', '00000000-0000-0000-0000-00000000000a');
select is(pg_temp.counts(), '-:1/0/0/0/0:0,Plant 1:1/1/1/1/1:2,Pune:0/1/0/0/0:1',
  'overdue per asset location; deleted obligation, deleted asset, due soon and tenant B not counted');

-- Counts match the lists the tiles open.
select is((select active from public.location_status_counts() where location_id = '00000000-0000-0000-0000-00000055d002'),
  public.count_assets(p_status => 'active', p_location_id => '00000000-0000-0000-0000-00000055d002'),
  'a leaf status count matches count_assets(p_status, p_location_id)');
select is((select disposed from public.location_status_counts() where location_id = '00000000-0000-0000-0000-00000055d002'),
  public.count_assets(p_status => 'disposed', p_location_id => '00000000-0000-0000-0000-00000055d002'),
  'disposed matches count_assets too');
select is((select sum(in_stock + active + under_maintenance + inactive + disposed)::int from public.location_status_counts()),
  (select sum(assets)::int from public.location_asset_counts()), 'the statuses add up to location_asset_counts()');
select is((select sum(overdue)::int from public.location_status_counts()),
  (select sum(overdue)::int from public.location_asset_counts()), 'overdue equals location_asset_counts()');
select is((select overdue from public.maintenance_counts(p_location_id => '00000000-0000-0000-0000-00000055d001')), 3,
  'the web roll-up (Pune = Pune + Plant 1 = 3 overdue) matches maintenance_counts for the subtree');
select is(public.count_assets(p_status => 'active', p_location_id => '00000000-0000-0000-0000-00000055d001'), 2,
  'the web roll-up (Pune active = 1 + 1) matches count_assets for the subtree');

-- Cross-tenant: a1 in tenant B sees only B.
reset role;
select tests.grant('00000000-0000-0000-0000-00000000000b', '00000000-0000-0000-0000-0000000000a1', 'obligation', '{view}');
select tests.grant('00000000-0000-0000-0000-00000000000b', '00000000-0000-0000-0000-0000000000a1', 'asset_core', '{view}');
select tests.act_as('00000000-0000-0000-0000-0000000000a1', '00000000-0000-0000-0000-00000000000b');
select is(pg_temp.counts(), 'B site:0/1/0/0/0:1', 'tenant B: only B rows');
reset role;
select tests.act_as('00000000-0000-0000-0000-0000000000a1', '00000000-0000-0000-0000-00000000000a');
select isnt((select string_agg(location_id::text, ',') from public.location_status_counts()) like '%55d00b%', true,
  'tenant A: no tenant B location');

select * from finish();
rollback;
