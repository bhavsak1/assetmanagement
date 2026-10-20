-- Story 1.7 spike: candidate fixes, LOCAL ONLY. Run after 03_bench.sql. Labels start with F.
-- Finding: the tenant check is an InitPlan, so the planner does not know the tenant and plans for an
-- average tenant (about 4.7k rows). In the 200k tenant that means read-everything-then-sort.

-- F1: the app's data layer also sends tenant_id = <active tenant> (PostgREST .eq). RLS still enforces;
-- the filter only gives the planner the real value.
do $$
declare
  lt  uuid := (select tenant_id from spike.bench_user where label = 'large_admin');
  f   text := format(' and tenant_id = %L', lt);
begin
  perform spike.bench('F1 01 list 50, large, admin + tenant filter',       'large_admin',
    'select * from spike.asset where deleted_at is null' || f || ' order by name limit 50');
  perform spike.bench('F1 04 page 101 (offset 5000), large + tenant filter', 'large_admin',
    'select * from spike.asset where deleted_at is null' || f || ' order by name limit 50 offset 5000');
  perform spike.bench('F1 11 search "motor 0012", large + tenant filter',  'large_admin',
    'select * from spike.asset where name ilike ''%motor 0012%'' and deleted_at is null' || f || ' order by name limit 50');
  perform spike.bench('F1 12 search "pump", large + tenant filter',        'large_admin',
    'select * from spike.asset where name ilike ''%pump%'' and deleted_at is null' || f || ' order by name limit 50');
  perform spike.bench('F1 31 list 50, site scope + tenant filter',         'large_site',
    'select * from spike.asset where deleted_at is null' || f || ' order by name limit 50');
  perform spike.bench('F1 32 list 50, area scope + tenant filter',         'large_area',
    'select * from spike.asset where deleted_at is null' || f || ' order by name limit 50');
  perform spike.bench('F1 40 list 50, 45 groups + tenant filter',          'large_many',
    'select * from spike.asset where deleted_at is null' || f || ' order by name limit 50');
end;
$$;

-- F2: sort index made partial like the filter the app always sends (deleted_at is null). No app change.
drop index spike.asset_name_idx;
create index asset_name_idx on spike.asset (tenant_id, name) where deleted_at is null;
analyze spike.asset;
do $$
declare
  list text := 'select * from spike.asset where deleted_at is null order by name limit 50';
begin
  perform spike.bench('F2 01 list 50, large, admin, partial index',  'large_admin', list);
  perform spike.bench('F2 02 list 50, small, admin, partial index',  'small_admin', list);
  perform spike.bench('F2 04 page 101, large, partial index',        'large_admin', list || ' offset 5000');
  perform spike.bench('F2 31 list 50, site scope, partial index',    'large_site', list);
  perform spike.bench('F2 32 list 50, area scope, partial index',    'large_area', list);
  perform spike.bench('F2 12 search "pump", large, partial index',   'large_admin',
    'select * from spike.asset where name ilike ''%pump%'' and deleted_at is null order by name limit 50');
end;
$$;

-- F4: search. The trigram index has no tenant, so the planner walks the tenant's btree instead.
-- A GIN index on (tenant_id, name trigram) via btree_gin keeps the search inside the tenant.
create extension if not exists btree_gin with schema extensions;
drop index spike.asset_name_trgm;
create index asset_name_trgm on spike.asset using gin (tenant_id, name extensions.gin_trgm_ops) where deleted_at is null;
analyze spike.asset;
do $$
declare
  f text := format(' and tenant_id = %L', (select tenant_id from spike.bench_user where label = 'large_admin'));
begin
  perform spike.bench('F4 11 search "motor 0012", large, tenant gin',           'large_admin',
    'select * from spike.asset where name ilike ''%motor 0012%'' and deleted_at is null order by name limit 50');
  perform spike.bench('F4 12 search "pump", large, tenant gin',                 'large_admin',
    'select * from spike.asset where name ilike ''%pump%'' and deleted_at is null order by name limit 50');
  perform spike.bench('F4 13 search "pump", small, tenant gin',                 'small_admin',
    'select * from spike.asset where name ilike ''%pump%'' and deleted_at is null order by name limit 50');
  perform spike.bench('F4 15 search "motor 0012", large, tenant gin + filter',  'large_admin',
    'select * from spike.asset where name ilike ''%motor 0012%'' and deleted_at is null' || f || ' order by name limit 50');
  perform spike.bench('F4 16 search "pump", large, tenant gin + filter',        'large_admin',
    'select * from spike.asset where name ilike ''%pump%'' and deleted_at is null' || f || ' order by name limit 50');
end;
$$;

-- F5: ilike is not leakproof, so under RLS it runs after the policy and never uses an index.
-- An id-only search helper (security definer, same tenant, permission and scope checks) feeds an
-- ordinary query; RLS still checks every row it returns.
create function spike.search_asset_ids(p_term text)
returns setof uuid language sql stable security definer set search_path = '' as $$
  select a.id from spike.asset a
  where a.tenant_id = (select private.current_tenant_id())
    and (select private.has_permission('asset_core', 'view'))
    and a.deleted_at is null
    and a.name ilike '%' || p_term || '%'
    and ((select spike.scope_location_ids('asset_core', 'view')) is null
         or a.location_id = any ((select spike.scope_location_ids('asset_core', 'view'))::uuid[]));
$$;
grant execute on function spike.search_asset_ids(text) to authenticated;
do $$
begin
  perform spike.bench('F5 11 search "motor 0012", large, id helper', 'large_admin',
    'select * from spike.asset where id in (select spike.search_asset_ids(''motor 0012'')) and deleted_at is null order by name limit 50');
  perform spike.bench('F5 12 search "pump", large, id helper',       'large_admin',
    'select * from spike.asset where id in (select spike.search_asset_ids(''pump'')) and deleted_at is null order by name limit 50');
  perform spike.bench('F5 13 search "pump", small, id helper',       'small_admin',
    'select * from spike.asset where id in (select spike.search_asset_ids(''pump'')) and deleted_at is null order by name limit 50');
  perform spike.bench('F5 14 search "motor", large, site scope, id helper', 'large_site',
    'select * from spike.asset where id in (select spike.search_asset_ids(''motor'')) and deleted_at is null order by name limit 50');
end;
$$;

-- F3: the 1.3 row-trigger shortcut. Saving 20 policy rows at once on a group with 80 members
-- rebuilds each member 20 times. Measured as is; the fix (statement triggers) is a proposal.
do $$
declare
  lt uuid := (select tenant_id from spike.bench_user where label = 'large_admin');
  tg uuid := (select id from public.security_group where tenant_id = lt and template_code = 'starter.technician');
begin
  perform spike.bench('F3 save 20 policies on Technician (80 users)', null, format(
    'insert into public.group_domain_policy (tenant_id, security_group_id, domain_operation_id)
     select %L, %L, o.id from public.domain_operation o
     where not exists (select 1 from public.group_domain_policy p where p.security_group_id = %L
                       and p.domain_operation_id = o.id and p.deleted_at is null)
     order by o.id limit 20', lt, tg, tg), 5);
end;
$$;

select label, plan_rows as rows, p50_ms, p95_ms, max_ms from spike.result where label like 'F%' order by label;
