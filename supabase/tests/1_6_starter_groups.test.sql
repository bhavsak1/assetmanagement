-- Story 1.6: starter groups, the permission test matrix, and the Goal 1 review point:
-- tenant A cannot see tenant B, and an Auditor cannot write anything.
-- Uses the seed: tenants A (active) and B (read_only), each with the starter groups and one user per group
-- (id ...0000000<a|b>000<n>: 1 admin, 2 plant manager, 3 planner, 4 technician, 5 auditor).
-- `npm run db:report` prints this file's test names into docs/goal1-test-report.txt.
begin;
select plan(47);

-- The expected grid, kept apart from the migration on purpose: the two must agree.
-- Same as docs/data-model-goal1.md §2.7a. A domain not listed (rls_sample) is granted to no group.
create temp table expected (domain_code, tenant_admin, plant_manager, planner, technician, auditor) as values
  ('asset_core',         '{view,create,update,delete}'::text[], '{view,create,update,delete}'::text[], '{view,update}'::text[], '{view}'::text[], '{view}'::text[]),
  ('asset_financials',   '{view,update}',                 '{view}',                         '{}',                             '{}',                             '{view}'),
  ('asset_lifecycle',    '{execute}',                     '{execute}',                      '{}',                             '{}',                             '{}'),
  ('vendor_core',        '{view,create,update,delete}',   '{view,create,update}',           '{view}',                         '{view}',                         '{view}'),
  ('vendor_tax_ids',     '{view,update}',                 '{view}',                         '{}',                             '{}',                             '{view}'),
  ('coverage_contract',  '{view,create,update,delete}',   '{view,create,update}',           '{view,create,update}',           '{view}',                         '{view}'),
  ('coverage_values',    '{view,update}',                 '{view}',                         '{}',                             '{}',                             '{view}'),
  ('obligation',         '{view,create,update,complete}', '{view,create,update,complete}',  '{view,create,update,complete}',  '{view,complete}',                '{view}'),
  ('service_record',     '{view,create,update,complete}', '{view,create,update,complete}',  '{view,create,update,complete}',  '{view,create,update,complete}',  '{view}'),
  ('location_hierarchy', '{view,manage}',                 '{view,manage}',                  '{view}',                         '{view}',                         '{view}'),
  ('category_config',    '{view,manage}',                 '{view}',                         '{view}',                         '{view}',                         '{view}'),
  ('excel_import',       '{run,review,commit}',           '{run,review,commit}',            '{run,review}',                   '{}',                             '{}'),
  ('import_undo',        '{undo}',                        '{undo}',                         '{}',                             '{}',                             '{}'),
  ('users_security',     '{view,manage}',                 '{}',                             '{}',                             '{}',                             '{view}'),
  ('api_keys',           '{view,manage}',                 '{}',                             '{}',                             '{}',                             '{view}'),
  ('audit_log',          '{view}',                        '{view}',                         '{}',                             '{}',                             '{view}'),
  ('tenant_settings',    '{view,manage}',                 '{view}',                         '{}',                             '{}',                             '{view}'),
  ('ai_usage',           '{view,manage}',                 '{view}',                         '{}',                             '{}',                             '{view}'),
  ('insights_query',     '{ask}',                         '{ask}',                          '{ask}',                          '{}',                             '{}'),
  ('insights_widget',    '{save,share}',                  '{save,share}',                   '{save}',                         '{}',                             '{}');

-- Every catalog operation where has_permission disagrees with the grid for this user. Empty = match.
create function pg_temp.matrix_diff(p_user uuid, p_tenant uuid, p_group text) returns text[] language plpgsql as $$
declare
  v text[];
begin
  perform tests.act_as(p_user, p_tenant);
  -- The claims stay; back to postgres only to read the catalog, which RLS limits to security admins.
  execute 'reset role';
  select coalesce(array_agg(d.code || '.' || o.code order by d.code, o.sort_order), '{}') into v
  from public.domain_operation o
  join public.security_domain d on d.id = o.security_domain_id
  left join expected e on e.domain_code = d.code
  where private.has_permission(d.code, o.code)
        is distinct from (o.code in (select jsonb_array_elements_text(to_jsonb(e) -> p_group)));
  return v;
end;
$$;

-- Public tenant_id tables, and a row count under the current role.
-- A table, not a view: a view lets the planner run count_rows on pg_class rows before the join filters.
create temp table tenant_table as
  select format('%I.%I', 'public', c.relname) as name from pg_class c
  join pg_attribute a on a.attrelid = c.oid and a.attname = 'tenant_id' and not a.attisdropped
  where c.relnamespace = 'public'::regnamespace and c.relkind in ('r', 'p');
grant select on tenant_table to authenticated;
create function pg_temp.count_rows(p_table text, p_where text) returns int language plpgsql as $$
declare
  n int;
begin
  execute format('select count(*) from %s where %s', p_table, p_where) into n;
  return n;
end;
$$;

-- Run as the Auditor: reads work, update, soft delete and hard delete do not. 4 tests.
create function pg_temp.read_only(p_table text) returns setof text language plpgsql as $$
begin
  return next isnt_empty(format('select 1 from %s', p_table), 'Auditor reads ' || p_table);
  return next is_empty(format('update %s set deleted_at = deleted_at returning 1', p_table), 'Auditor cannot update ' || p_table);
  return next is_empty(format('update %s set deleted_at = now() returning 1', p_table), 'Auditor cannot soft delete ' || p_table);
  return next throws_ok(format('delete from %s', p_table), '42501', null, 'Auditor cannot hard delete ' || p_table);
end;
$$;

-- Provisioning function.
select ok(not has_function_privilege('authenticated', 'private.seed_starter_groups(uuid)', 'execute'), 'users cannot run the starter group seed');
select results_eq(
  $$select t.slug, g.code, g.template_code from public.security_group g join public.tenant t on t.id = g.tenant_id
    where g.template_code like 'starter.%' order by 1, 2$$,
  $$values ('test-tenant-a', 'auditor', 'starter.auditor'), ('test-tenant-a', 'planner', 'starter.planner'),
           ('test-tenant-a', 'plant_manager', 'starter.plant_manager'), ('test-tenant-a', 'technician', 'starter.technician'),
           ('test-tenant-a', 'tenant_admin', 'starter.tenant_admin'),
           ('test-tenant-b', 'auditor', 'starter.auditor'), ('test-tenant-b', 'planner', 'starter.planner'),
           ('test-tenant-b', 'plant_manager', 'starter.plant_manager'), ('test-tenant-b', 'technician', 'starter.technician'),
           ('test-tenant-b', 'tenant_admin', 'starter.tenant_admin')$$,
  'both test tenants have the five starter groups'
);

create temp table before_rerun as
  select (select count(*) from public.security_group) as groups, (select count(*) from public.group_domain_policy) as policies;
select private.seed_starter_groups('00000000-0000-0000-0000-00000000000a');
select private.seed_starter_groups('00000000-0000-0000-0000-00000000000a');
select is((select count(*) from public.security_group), (select groups from before_rerun), 'running the seed again adds no groups');
select is((select count(*) from public.group_domain_policy), (select policies from before_rerun), 'running the seed again adds no policies');

insert into public.tenant (id, name, slug, currency_code, locale, time_zone, date_format) values
  ('00000000-0000-0000-0000-00000000000c', 'TEST Tenant C', 'test-tenant-c', 'EUR', 'en-GB', 'Europe/London', 'dd/MM/yyyy');
select private.seed_starter_groups('00000000-0000-0000-0000-00000000000c');
select results_eq(
  $$select g.code, count(*) from public.security_group g join public.group_domain_policy p on p.security_group_id = g.id
    where g.tenant_id = '00000000-0000-0000-0000-00000000000c' group by 1 order by 1$$,
  $$select g.code, count(*) from public.security_group g join public.group_domain_policy p on p.security_group_id = g.id
    where g.tenant_id = '00000000-0000-0000-0000-00000000000a' and g.template_code like 'starter.%' group by 1 order by 1$$,
  'a new tenant gets the same starter groups and grants'
);

-- The permission test matrix: every starter group by every catalog domain and operation, in both tenants.
select is(pg_temp.matrix_diff(('00000000-0000-0000-0000-0000000' || t || '000' || n)::uuid,
                              ('00000000-0000-0000-0000-00000000000' || t)::uuid, g),
          '{}', format('tenant %s %s: has_permission matches the matrix', upper(t), g))
from (values ('a'), ('b')) tt (t)
cross join (values (1, 'tenant_admin'), (2, 'plant_manager'), (3, 'planner'), (4, 'technician'), (5, 'auditor')) gg (n, g)
order by t, n;

select is_empty(
  $$select 1 from public.group_domain_policy p join public.security_group g on g.id = p.security_group_id
    join public.domain_operation o on o.id = p.domain_operation_id
    where g.template_code = 'starter.auditor' and o.code <> 'view'$$,
  'Auditor holds view operations only'
);

-- Review point 1: a user of tenant A sees no tenant B row in any public tenant_id table.
insert into public.rls_sample (tenant_id, name) values
  ('00000000-0000-0000-0000-00000000000a', 'a-row'), ('00000000-0000-0000-0000-00000000000b', 'b-row');
insert into public.asset_category (tenant_id, name) values
  ('00000000-0000-0000-0000-00000000000a', 'a-row'), ('00000000-0000-0000-0000-00000000000b', 'b-row');
insert into public.field_definition (tenant_id, entity, key, label, type, security_domain_id)
select t, 'asset', 'row_key', 'row', 'text', (select id from public.security_domain where code = 'asset_core')
from unnest(array['00000000-0000-0000-0000-00000000000a', '00000000-0000-0000-0000-00000000000b']::uuid[]) t;
insert into public.location (tenant_id, name) values
  ('00000000-0000-0000-0000-00000000000a', 'a-site'), ('00000000-0000-0000-0000-00000000000b', 'b-site');
select is(array(select name from tenant_table where pg_temp.count_rows(name, $$tenant_id = '00000000-0000-0000-0000-00000000000b'$$) = 0 order by 1),
          '{}', 'every public tenant_id table holds tenant B rows to hide');
-- One test per tenant A user, each acting as that user over every table. Plain queries, so RLS decides.
select tests.act_as('00000000-0000-0000-0000-0000000a0001', '00000000-0000-0000-0000-00000000000a');
select is(array(select name from tenant_table where pg_temp.count_rows(name, $$tenant_id <> '00000000-0000-0000-0000-00000000000a'$$) > 0 order by 1),
          '{}', 'tenant A tenant_admin sees no tenant B row in any public tenant_id table');
select tests.act_as('00000000-0000-0000-0000-0000000a0002', '00000000-0000-0000-0000-00000000000a');
select is(array(select name from tenant_table where pg_temp.count_rows(name, $$tenant_id <> '00000000-0000-0000-0000-00000000000a'$$) > 0 order by 1),
          '{}', 'tenant A plant_manager sees no tenant B row in any public tenant_id table');
select tests.act_as('00000000-0000-0000-0000-0000000a0003', '00000000-0000-0000-0000-00000000000a');
select is(array(select name from tenant_table where pg_temp.count_rows(name, $$tenant_id <> '00000000-0000-0000-0000-00000000000a'$$) > 0 order by 1),
          '{}', 'tenant A planner sees no tenant B row in any public tenant_id table');
select tests.act_as('00000000-0000-0000-0000-0000000a0004', '00000000-0000-0000-0000-00000000000a');
select is(array(select name from tenant_table where pg_temp.count_rows(name, $$tenant_id <> '00000000-0000-0000-0000-00000000000a'$$) > 0 order by 1),
          '{}', 'tenant A technician sees no tenant B row in any public tenant_id table');
select tests.act_as('00000000-0000-0000-0000-0000000a0005', '00000000-0000-0000-0000-00000000000a');
select is(array(select name from tenant_table where pg_temp.count_rows(name, $$tenant_id <> '00000000-0000-0000-0000-00000000000a'$$) > 0 order by 1),
          '{}', 'tenant A auditor sees no tenant B row in any public tenant_id table');
reset role;

-- Review point 2: an Auditor can read, but every insert, update and soft delete fails.
-- The 1.4 template domain is in no starter group, so give the Auditor view on it to prove reads work there too.
select tests.grant('00000000-0000-0000-0000-00000000000a', '00000000-0000-0000-0000-0000000a0005', 'rls_sample', '{view}');
select tests.act_as('00000000-0000-0000-0000-0000000a0005', '00000000-0000-0000-0000-00000000000a');
select * from pg_temp.read_only('public.rls_sample');
select * from pg_temp.read_only('public.security_group');
select * from pg_temp.read_only('public.group_domain_policy');
select * from pg_temp.read_only('public.user_group_assignment');
select * from pg_temp.read_only('public.tenant_membership');
select throws_ok(
  $$insert into public.rls_sample (tenant_id, name) values ('00000000-0000-0000-0000-00000000000a', 'x')$$,
  '42501', null, 'Auditor cannot insert into public.rls_sample'
);
select throws_ok(
  $$insert into public.security_group (tenant_id, code, name) values ('00000000-0000-0000-0000-00000000000a', 'x', 'x')$$,
  '42501', null, 'Auditor cannot insert into public.security_group'
);
select throws_ok(
  $$insert into public.group_domain_policy (tenant_id, security_group_id, domain_operation_id)
    select g.tenant_id, g.id, o.id from public.security_group g, public.domain_operation o
    join public.security_domain d on d.id = o.security_domain_id
    where g.code = 'auditor' and d.code = 'asset_core' and o.code = 'update'$$,
  '42501', null, 'Auditor cannot insert into public.group_domain_policy'
);
select throws_ok(
  $$insert into public.user_group_assignment (tenant_id, user_id, security_group_id)
    select g.tenant_id, '00000000-0000-0000-0000-0000000a0005', g.id from public.security_group g where g.code = 'tenant_admin'$$,
  '42501', null, 'Auditor cannot insert into public.user_group_assignment'
);
select throws_ok(
  $$insert into public.tenant_membership (tenant_id, user_id)
    values ('00000000-0000-0000-0000-00000000000a', '00000000-0000-0000-0000-0000000000a2')$$,
  '42501', null, 'Auditor cannot insert into public.tenant_membership'
);

select * from finish();
rollback;
