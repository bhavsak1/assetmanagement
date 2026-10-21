-- Story 1.7 spike measurements, LOCAL ONLY. Needs 01_setup.sql and 02_data.sql first.
-- Results land in spike.result; the summary query at the end prints them.

truncate spike.result;
-- A tenant with no groups yet, for timing seed_starter_groups.
insert into public.tenant (id, name, slug, currency_code, locale, time_zone, date_format, fiscal_year_start_month)
values ('00000000-0000-0000-0001-999999999999', 'SPIKE spare', 'spike-spare', 'INR', 'en-IN', 'Asia/Kolkata', 'dd-MM-yyyy', 4)
on conflict do nothing;

do $$
declare
  lt   uuid := (select tenant_id from spike.bench_user where label = 'large_admin');
  st   uuid := (select tenant_id from spike.bench_user where label = 'small_admin');
  lid  uuid := (select id from spike.asset where tenant_id = lt and deleted_at is null order by asset_code limit 1 offset 1000);
  sid  uuid := (select id from spike.asset where tenant_id = st and deleted_at is null order by asset_code limit 1 offset 100);
  loc  uuid := (select id from spike.location where tenant_id = lt and level = 3 limit 1);
  cat  uuid := (select id from spike.category where tenant_id = lt limit 1);
  list text := 'select * from spike.asset where deleted_at is null order by name limit 50';
  cnt  text := 'select count(*) from spike.asset where deleted_at is null';
begin
  -- Reads, large tenant (200k) and small tenant (~1.2k)
  perform spike.bench('01 list 50 by name, large, admin',       'large_admin', list);
  perform spike.bench('02 list 50 by name, small, admin',       'small_admin', list);
  perform spike.bench('03 list 50, large, baseline no RLS',     null,
    format('select * from spike.asset where tenant_id = %L and deleted_at is null order by name limit 50', lt));
  perform spike.bench('04 list page 101 (offset 5000), large',  'large_admin', list || ' offset 5000');
  perform spike.bench('05 count, large, admin',                 'large_admin', cnt);
  perform spike.bench('06 count, small, admin',                 'small_admin', cnt);
  perform spike.bench('07 count, large, explicit tenant filter','large_admin', cnt || format(' and tenant_id = %L', lt));
  perform spike.bench('08 count, large, baseline no RLS',       null, cnt || format(' and tenant_id = %L', lt));
  perform spike.bench('09 lookup by id, large',                 'large_admin', format('select * from spike.asset where id = %L', lid));
  perform spike.bench('10 lookup by id, small',                 'small_admin', format('select * from spike.asset where id = %L', sid));
  perform spike.bench('11 search exact-ish "motor 0012", large','large_admin',
    'select * from spike.asset where name ilike ''%motor 0012%'' and deleted_at is null order by name limit 50');
  perform spike.bench('12 search broad "pump", large',          'large_admin',
    'select * from spike.asset where name ilike ''%pump%'' and deleted_at is null order by name limit 50');
  perform spike.bench('13 search broad "pump", small',          'small_admin',
    'select * from spike.asset where name ilike ''%pump%'' and deleted_at is null order by name limit 50');
  perform spike.bench('14 search by code prefix, large',        'large_admin',
    'select * from spike.asset where asset_code like ''AST-00123%'' and deleted_at is null order by asset_code limit 50');

  -- Writes with the soft-delete guard and audit trigger
  perform spike.bench('20 insert one asset, large',             'large_admin', format(
    'insert into spike.asset (tenant_id, asset_code, name, location_id, category_id, criticality) values (%L, ''AST-NEW-'' || gen_random_uuid(), ''Pump new'', %L, %L, ''B'')',
    lt, loc, cat));
  perform spike.bench('21 update one asset, large',             'large_admin', format('update spike.asset set name = name || '' x'' where id = %L', lid));
  perform spike.bench('22 soft delete one asset, large',        'large_admin', format('update spike.asset set deleted_at = now() where id = %L', lid));
  perform spike.bench('23 update one asset, small',             'small_admin', format('update spike.asset set name = name || '' x'' where id = %L', sid));

  -- Scope (D7 option X, set-form helper in the policy)
  perform spike.bench('30 list 50, large, technician (no scope)','large_tech', list);
  perform spike.bench('31 list 50, large, scoped to 1 site (20%)','large_site', list);
  perform spike.bench('32 list 50, large, scoped to 1 area (0.1%)','large_area', list);
  perform spike.bench('33 count, large, scoped to 1 site',      'large_site', cnt);
  perform spike.bench('34 count, large, scoped to 1 area',      'large_area', cnt);

  -- Many groups (45 assignments, about 3k effective rows)
  perform spike.bench('40 list 50, large, user with 45 groups', 'large_many', list);
  perform spike.bench('41 count, large, user with 45 groups',   'large_many', cnt);
  perform spike.bench('42 has_permission alone, 45 groups',     'large_many', 'select private.has_permission(''asset_core'', ''view'')');
end;
$$;

-- Row-form scope helper (per row), for comparison. Swapped in, then the set form is put back.
alter policy asset_select on spike.asset
  using (tenant_id = (select private.current_tenant_id())
         and (select private.has_permission('asset_core', 'view'))
         and spike.in_scope_row('asset_core', 'view', location_id));
select spike.bench('35 ROW-FORM list 50, large, scoped to 1 site', 'large_site', 'select * from spike.asset where deleted_at is null order by name limit 50', 5);
select spike.bench('36 ROW-FORM list 50, large, scoped to 1 area', 'large_area', 'select * from spike.asset where deleted_at is null order by name limit 50', 5);
select spike.bench('37 ROW-FORM count, large, scoped to 1 site',   'large_site', 'select count(*) from spike.asset where deleted_at is null', 5);
select spike.bench('38 ROW-FORM count, large, admin (no scope)',   'large_admin', 'select count(*) from spike.asset where deleted_at is null', 5);
alter policy asset_select on spike.asset
  using (tenant_id = (select private.current_tenant_id())
         and (select private.has_permission('asset_core', 'view'))
         and ((select spike.scope_location_ids('asset_core', 'view')) is null
              or location_id = any ((select spike.scope_location_ids('asset_core', 'view'))::uuid[])));

-- Permission rebuilds (as postgres, through the real triggers), large tenant
do $$
declare
  lt   uuid := (select tenant_id from spike.bench_user where label = 'large_admin');
  tech uuid := (select user_id from spike.bench_user where label = 'large_tech');
  many uuid := (select user_id from spike.bench_user where label = 'large_many');
  tg   uuid := (select id from public.security_group where tenant_id = lt and template_code = 'starter.technician');
  ag   uuid := (select id from public.security_group where tenant_id = lt and template_code = 'starter.auditor');
  op   uuid := (select o.id from public.domain_operation o join public.security_domain d on d.id = o.security_domain_id
                where d.code = 'asset_core' and o.code = 'create');
begin
  perform spike.bench('50 rebuild: assign 1 group to 1 user',            null, format(
    'insert into public.user_group_assignment (tenant_id, user_id, security_group_id) values (%L, %L, %L)', lt, tech, ag), 20);
  perform spike.bench('51 rebuild: refresh user with 45 groups',         null, format('select private.refresh_member(%L, %L)', lt, many), 20);
  perform spike.bench('52 rebuild: add 1 policy to Technician (80 users)', null, format(
    'insert into public.group_domain_policy (tenant_id, security_group_id, domain_operation_id) values (%L, %L, %L)', lt, tg, op), 10);
  perform spike.bench('53 rebuild: soft delete Technician group',        null, format(
    'update public.security_group set deleted_at = now() where id = %L', tg), 10);
  perform spike.bench('54 rebuild: refresh all 400 users of tenant',     null, format(
    'select private.refresh_member(tenant_id, user_id) from public.tenant_membership where tenant_id = %L', lt), 5);
  perform spike.bench('55 seed_starter_groups, new tenant',              null,
    'select private.seed_starter_groups(''00000000-0000-0000-0001-999999999999'')', 20);
end;
$$;

select label, plan_rows as rows, p50_ms, p95_ms, max_ms from spike.result order by label;
