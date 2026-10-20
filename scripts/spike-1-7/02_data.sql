-- Story 1.7 spike data, LOCAL ONLY. About 1M assets over 200 tenants with a skewed size curve.
-- Security rows go through the real triggers (rebuild, audit). The asset load skips triggers
-- (session_replication_role = replica) so it does not write 1M audit rows; the bench measures triggers.

-- Tenant sizes: three large (200k, 150k, 100k), then a power-law tail.
create table spike.tenant_plan as
select n, ('00000000-0000-0000-0001-' || lpad(n::text, 12, '0'))::uuid as tenant_id,
       case n when 1 then 200000 when 2 then 150000 when 3 then 100000
              else greatest(200, round(58000 / power(n - 3, 0.85)))::int end as n_assets
from generate_series(1, 200) n;
alter table spike.tenant_plan add column n_users int, add column n_sites int, add column n_buildings int, add column n_areas int;
update spike.tenant_plan set
  n_users     = greatest(5, least(400, n_assets / 500)),
  n_sites     = greatest(1, n_assets / 40000),
  n_buildings = least(10, greatest(2, n_assets / 2000)),
  n_areas     = least(20, greatest(3, n_assets / 1000));

insert into public.tenant (id, name, slug, currency_code, time_zone, date_format)
select tenant_id, 'SPIKE Tenant ' || n, 'spike-' || lpad(n::text, 3, '0'), 'INR', 'Asia/Kolkata', 'dd-MM-yyyy'
from spike.tenant_plan;
select private.seed_starter_groups(tenant_id) from spike.tenant_plan;

-- Users: auth row, profile, membership. No password: nobody signs in as them.
create table spike.plan_user as
select p.tenant_id, p.n as tenant_n, u as user_n,
       ('00000000-0000-0000-0002-' || lpad(p.n::text, 4, '0') || lpad(u::text, 8, '0'))::uuid as user_id
from spike.tenant_plan p cross join lateral generate_series(1, p.n_users) u;

insert into auth.users (instance_id, id, aud, role, email, encrypted_password, created_at, updated_at,
                        confirmation_token, recovery_token, email_change, email_change_token_new)
select '00000000-0000-0000-0000-000000000000', user_id, 'authenticated', 'authenticated',
       'spike.' || tenant_n || '.' || user_n || '@example.com', '', now(), now(), '', '', '', ''
from spike.plan_user;
insert into public.user_profile (id, display_name, email)
select user_id, 'SPIKE ' || tenant_n || '.' || user_n, 'spike.' || tenant_n || '.' || user_n || '@example.com' from spike.plan_user;
insert into public.tenant_membership (tenant_id, user_id) select tenant_id, user_id from spike.plan_user;

-- One starter group each, round robin. Each insert fires the real rebuild trigger.
insert into public.user_group_assignment (tenant_id, user_id, security_group_id)
select u.tenant_id, u.user_id, g.id
from spike.plan_user u
join public.security_group g on g.tenant_id = u.tenant_id
 and g.template_code = 'starter.' || (array['tenant_admin', 'plant_manager', 'planner', 'technician', 'auditor'])[1 + u.user_n % 5];

-- Locations: site > building > area, then the closure table.
insert into spike.location (tenant_id, level, name)
select tenant_id, 1, 'S' || s from spike.tenant_plan, generate_series(1, n_sites) s;
insert into spike.location (tenant_id, parent_id, level, name)
select l.tenant_id, l.id, 2, l.name || '-B' || b
from spike.location l join spike.tenant_plan p using (tenant_id), generate_series(1, p.n_buildings) b where l.level = 1;
insert into spike.location (tenant_id, parent_id, level, name)
select l.tenant_id, l.id, 3, l.name || '-A' || a
from spike.location l join spike.tenant_plan p using (tenant_id), generate_series(1, p.n_areas) a where l.level = 2;

insert into spike.location_closure (tenant_id, ancestor_id, descendant_id, depth)
select tenant_id, id, id, 0 from spike.location
union all
select c.tenant_id, c.parent_id, c.id, 1 from spike.location c where c.parent_id is not null
union all
select c.tenant_id, p.parent_id, c.id, 2 from spike.location c join spike.location p on p.id = c.parent_id where p.parent_id is not null;
create index on spike.location_closure (tenant_id, descendant_id);

insert into spike.category (tenant_id, name) select tenant_id, 'Category ' || c from spike.tenant_plan, generate_series(1, 40) c;
insert into spike.vendor   (tenant_id, name) select tenant_id, 'Vendor ' || v   from spike.tenant_plan, generate_series(1, 60) v;

-- Numbered lookups so each asset can pick an area, category and vendor by number.
create temp table area_n as select tenant_id, id, row_number() over (partition by tenant_id order by id) rn from spike.location where level = 3;
create temp table cat_n  as select tenant_id, id, row_number() over (partition by tenant_id order by id) rn from spike.category;
create temp table ven_n  as select tenant_id, id, row_number() over (partition by tenant_id order by id) rn from spike.vendor;
create index on area_n (tenant_id, rn); create index on cat_n (tenant_id, rn); create index on ven_n (tenant_id, rn);
analyze area_n; analyze cat_n; analyze ven_n;

set session_replication_role = replica;
insert into spike.asset (tenant_id, asset_code, name, location_id, category_id, vendor_id, criticality)
select p.tenant_id,
       'AST-' || lpad(i::text, 7, '0'),
       (array['Pump', 'Motor', 'Compressor', 'Boiler', 'Conveyor', 'Chiller', 'Generator', 'Transformer', 'Valve', 'Fan',
              'Lathe', 'CNC Mill', 'Forklift', 'Crane', 'Welder', 'Press', 'Mixer', 'Dryer', 'Tank', 'Panel'])[1 + (i * 7) % 20]
         || ' ' || lpad(((i * 7919) % 1000000)::text, 6, '0'),
       a.id, c.id, case when i % 10 < 7 then v.id end,
       (array['A', 'B', 'C', 'C'])[1 + i % 4]
from spike.tenant_plan p
cross join lateral generate_series(1, p.n_assets) i
join area_n a on a.tenant_id = p.tenant_id and a.rn = 1 + (i * 31) % (p.n_sites * p.n_buildings * p.n_areas)
join cat_n  c on c.tenant_id = p.tenant_id and c.rn = 1 + (i * 13) % 40
join ven_n  v on v.tenant_id = p.tenant_id and v.rn = 1 + (i * 17) % 60;
set session_replication_role = origin;
-- About 2% soft-deleted, as history.
update spike.asset set deleted_at = now() where (hashtext(id::text) % 50) = 0;

-- Indexes a Goal 3 asset table would carry (proposed in the report).
create unique index asset_code_uq on spike.asset (tenant_id, asset_code) where deleted_at is null;
create index asset_name_idx     on spike.asset (tenant_id, name);
create index asset_location_idx on spike.asset (tenant_id, location_id);
create index asset_name_trgm    on spike.asset using gin (name extensions.gin_trgm_ops);

-- Scoped users (D7): 10% of users in the three large tenants, scoped to their site (some) or one area.
create table spike.plan_scope as
select u.tenant_id, u.user_id, u.user_n,
       case when u.user_n % 20 = 0 then 'area' else 'site' end as kind
from spike.plan_user u where u.tenant_n <= 3 and u.user_n % 10 = 0;

insert into spike.scope_profile (tenant_id, name)
select distinct tenant_id, l.name from spike.plan_scope s
join spike.location l using (tenant_id) where l.name in ('S1', 'S1-B1-A1');
insert into spike.scope_profile_rule (tenant_id, scope_profile_id, dimension, location_id)
select sp.tenant_id, sp.id, 'location', l.id
from spike.scope_profile sp join spike.location l on l.tenant_id = sp.tenant_id and l.name = sp.name;

-- Stand-in for 6.1's rebuild filling scope_profile_id from the assignment.
update private.user_effective_permission uep
set scope_profile_id = sp.id
from spike.plan_scope s
join spike.scope_profile sp on sp.tenant_id = s.tenant_id and sp.name = case s.kind when 'site' then 'S1' else 'S1-B1-A1' end
where uep.tenant_id = s.tenant_id and uep.user_id = s.user_id;

-- A user with many groups: all five starter groups plus 40 copies of Tenant Admin.
do $$
declare
  t uuid := (select tenant_id from spike.tenant_plan where n = 1);
  u uuid := (select user_id from spike.plan_user where tenant_n = 1 and user_n = 7);
  g uuid;
begin
  for i in 1 .. 40 loop
    insert into public.security_group (tenant_id, code, name) values (t, 'spike_copy_' || i, 'Spike copy ' || i) returning id into g;
    insert into public.group_domain_policy (tenant_id, security_group_id, domain_operation_id)
    select t, g, p.domain_operation_id from public.group_domain_policy p
    join public.security_group s on s.id = p.security_group_id
    where s.tenant_id = t and s.template_code = 'starter.tenant_admin';
    insert into public.user_group_assignment (tenant_id, user_id, security_group_id) values (t, u, g);
  end loop;
  insert into public.user_group_assignment (tenant_id, user_id, security_group_id)
  select t, u, id from public.security_group where tenant_id = t and template_code like 'starter.%';
end;
$$;

-- Bench users. Large = tenant 1 (200k). Small = tenant 100.
insert into spike.bench_user (label, user_id, tenant_id)
select 'large_admin',   user_id, tenant_id from spike.plan_user where tenant_n = 1 and user_n = 5   -- 5 % 5 = 0: tenant_admin
union all select 'large_tech',   user_id, tenant_id from spike.plan_user where tenant_n = 1 and user_n = 3
union all select 'large_site',   user_id, tenant_id from spike.plan_user where tenant_n = 1 and user_n = 10
union all select 'large_area',   user_id, tenant_id from spike.plan_user where tenant_n = 1 and user_n = 20
union all select 'large_many',   user_id, tenant_id from spike.plan_user where tenant_n = 1 and user_n = 7
union all select 'small_admin',  user_id, tenant_id from spike.plan_user where tenant_n = 100 and user_n = 5;

vacuum analyze spike.asset;
analyze public.tenant, public.tenant_membership, public.user_group_assignment, public.security_group, public.group_domain_policy, private.user_effective_permission, spike.location, spike.location_closure, spike.scope_profile_rule;

-- Self-check: shape is what the report claims.
do $$
begin
  assert (select count(*) from spike.asset) between 900000 and 1200000, 'asset count off';
  assert (select count(*) from spike.asset where tenant_id = (select tenant_id from spike.tenant_plan where n = 1)) = 200000, 'large tenant off';
  assert (select count(*) from spike.bench_user) = 6, 'bench users missing';
  assert (select count(*) from private.user_effective_permission where scope_profile_id is not null) > 0, 'no scoped grants';
end;
$$;
select count(*) as tenants, sum(n_assets) as assets, sum(n_users) as users, max(n_assets) as largest, min(n_assets) as smallest,
       percentile_cont(0.5) within group (order by n_assets) as median from spike.tenant_plan;
