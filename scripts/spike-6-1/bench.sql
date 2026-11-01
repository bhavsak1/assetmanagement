-- Story 6.1 performance check, LOCAL ONLY (docs/data-model-goal6.md §8). Runs in one transaction and rolls
-- back, so the local database is unchanged. About 2 minutes. Needs the seed and test harness (npm run db:reset).
--   docker exec -i supabase_db_assetly psql -U postgres -q < scripts/spike-6-1/bench.sql
-- One tenant with 200k assets over 5 sites > 4 buildings > 10 areas, 10 categories. User a1 is given
-- asset_core.view tenant-wide, scoped to one site (20%), to one area (0.5%), and with two profiles.
begin;
set local session_replication_role = default;

insert into public.tenant (id, name, slug, currency_code, locale, time_zone, date_format, fiscal_year_start_month)
values ('00000000-0000-0000-0061-000000000001', 'BENCH 6.1', 'bench-6-1', 'INR', 'en-IN', 'Asia/Kolkata', 'dd-MM-yyyy', 4);
insert into public.tenant_membership (tenant_id, user_id)
values ('00000000-0000-0000-0061-000000000001', '00000000-0000-0000-0000-0000000000a1');

-- Locations through the real closure triggers: site s, building s.b, area s.b.a.
create temp table loc (path text primary key, id uuid default gen_random_uuid(), parent text);
insert into loc (path, parent) select s::text, null from generate_series(1, 5) s;
insert into loc (path, parent) select s || '.' || b, s::text from generate_series(1, 5) s, generate_series(1, 4) b;
insert into loc (path, parent) select s || '.' || b || '.' || a, s || '.' || b
from generate_series(1, 5) s, generate_series(1, 4) b, generate_series(1, 10) a;
insert into public.location (id, tenant_id, parent_id, name)
select l.id, '00000000-0000-0000-0061-000000000001', p.id, 'L ' || l.path
from loc l left join loc p on p.path = l.parent order by length(l.path);
insert into public.asset_category (id, tenant_id, name)
select ('00000000-0000-0000-0061-1000000000' || lpad(c::text, 2, '0'))::uuid, '00000000-0000-0000-0061-000000000001', 'Cat ' || c
from generate_series(1, 10) c;

-- 200k assets, 1,000 per area. Triggers off for the load only (no audit rows, tags given).
set local session_replication_role = replica;
insert into public.asset (tenant_id, status_id, tag, name, category_id, location_id)
select '00000000-0000-0000-0061-000000000001',
       (select s.id from public.asset_status s where s.tenant_id = '00000000-0000-0000-0061-000000000001'
        and s.system_status = 'active' order by s.id limit 1), 'B-' || n, (array['Pump ', 'Motor ', 'Valve '])[n % 3 + 1] || n,
       ('00000000-0000-0000-0061-1000000000' || lpad((n % 10 + 1)::text, 2, '0'))::uuid,
       (select id from loc where path = ((n / 1000) / 40 + 1) || '.' || ((n / 1000) / 10 % 4 + 1) || '.' || ((n / 1000) % 10 + 1))
from generate_series(0, 199999) n;
set local session_replication_role = default;
analyze public.asset;

insert into public.scope_profile (id, tenant_id, name) values
  ('00000000-0000-0000-0061-2000000000f1', '00000000-0000-0000-0061-000000000001', 'Site 1'),
  ('00000000-0000-0000-0061-2000000000f2', '00000000-0000-0000-0061-000000000001', 'Area 1.1.1'),
  ('00000000-0000-0000-0061-2000000000f3', '00000000-0000-0000-0061-000000000001', 'Site 2 cat 1');
insert into public.scope_profile_rule (tenant_id, scope_profile_id, dimension, location_id, category_id)
select '00000000-0000-0000-0061-000000000001'::uuid, '00000000-0000-0000-0061-2000000000f1'::uuid, 'location', id, null::uuid from loc where path = '1'
union all
select '00000000-0000-0000-0061-000000000001', '00000000-0000-0000-0061-2000000000f2', 'location', id, null from loc where path = '1.1.1'
union all
select '00000000-0000-0000-0061-000000000001', '00000000-0000-0000-0061-2000000000f3', 'location', id, null from loc where path = '2'
union all
select '00000000-0000-0000-0061-000000000001', '00000000-0000-0000-0061-2000000000f3', 'category', null, '00000000-0000-0000-0061-100000000001';

create temp table result (scenario text, query text, rows int, p50_ms numeric, p95_ms numeric);

-- Give a1 asset_core.view with these profiles (null = tenant-wide), replacing earlier grants.
create function pg_temp.scenario(p_profiles uuid[]) returns void language plpgsql as $$
declare p uuid;
begin
  update public.user_group_assignment set deleted_at = now()
  where tenant_id = '00000000-0000-0000-0061-000000000001' and deleted_at is null;
  foreach p in array p_profiles loop
    perform tests.grant('00000000-0000-0000-0061-000000000001', '00000000-0000-0000-0000-0000000000a1', 'asset_core', '{view}');
    update public.user_group_assignment set scope_profile_id = p
    where tenant_id = '00000000-0000-0000-0061-000000000001' and deleted_at is null and scope_profile_id is null
      and id = (select id from public.user_group_assignment where tenant_id = '00000000-0000-0000-0061-000000000001'
                and deleted_at is null order by created_at desc, id limit 1);
  end loop;
end;
$$;

-- 21 runs as a1, the first dropped as warm-up.
create function pg_temp.bench(p_scenario text, p_query text, p_sql text) returns void language plpgsql as $$
declare
  t0 timestamptz;
  ts numeric[] := '{}';
  n  int;
begin
  for i in 0 .. 20 loop
    perform tests.act_as('00000000-0000-0000-0000-0000000000a1', '00000000-0000-0000-0061-000000000001');
    t0 := clock_timestamp();
    execute p_sql;
    get diagnostics n = row_count;
    if i > 0 then ts := ts || (extract(epoch from clock_timestamp() - t0) * 1000)::numeric; end if;
    reset role;
  end loop;
  insert into result
  select p_scenario, p_query, n,
         round((select percentile_cont(0.5) within group (order by t) from unnest(ts) t)::numeric, 1),
         round((select percentile_cont(0.95) within group (order by t) from unnest(ts) t)::numeric, 1);
end;
$$;

create function pg_temp.run(p_scenario text) returns void language sql as $$
  select pg_temp.bench(p_scenario, 'list 50 by name', 'select * from public.list_assets()');
  select pg_temp.bench(p_scenario, 'count', 'select public.count_assets()');
  select pg_temp.bench(p_scenario, 'search "pump 12"', 'select * from public.list_assets(p_term => ''pump 12'')');
  select pg_temp.bench(p_scenario, 'location tiles', 'select * from public.location_asset_counts()');
$$;

select pg_temp.scenario(array[null]::uuid[]);                                      select pg_temp.run('tenant-wide');
select pg_temp.scenario(array['00000000-0000-0000-0061-2000000000f1']::uuid[]);  select pg_temp.run('one site (20%)');
select pg_temp.scenario(array['00000000-0000-0000-0061-2000000000f2']::uuid[]);  select pg_temp.run('one area (0.5%)');
select pg_temp.scenario(array['00000000-0000-0000-0061-2000000000f1', '00000000-0000-0000-0061-2000000000f3']::uuid[]);
select pg_temp.run('two profiles (22%)');

select * from result order by scenario, query;
rollback;
