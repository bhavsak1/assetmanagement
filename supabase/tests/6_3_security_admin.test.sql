-- Story 6.3: Security screen database paths (docs/data-model-goal6.md §22).
-- Uses the seed: tenant A (...0a) with one user per starter group (admin.a ...a0001 is the only one with
-- users_security.manage, auditor.a ...a0005 has view), test.user a1 with no groups, tenant B (...0b).
begin;
select plan(29);

-- Fixtures, as postgres. Pune and Mumbai with one asset each; group G63 assigned to a1 with no grants.
insert into public.location (id, tenant_id, parent_id, name) values
  ('00000000-0000-0000-0000-0000000063e1', '00000000-0000-0000-0000-00000000000a', null, 'S63 Pune'),
  ('00000000-0000-0000-0000-0000000063e2', '00000000-0000-0000-0000-00000000000a', null, 'S63 Mumbai');
insert into public.asset_category (id, tenant_id, parent_id, name) values
  ('00000000-0000-0000-0000-0000000063c1', '00000000-0000-0000-0000-00000000000a', null, 'S63 Pumps');
insert into public.asset (id, tenant_id, tag, name, category_id, location_id) values
  ('00000000-0000-0000-0000-0000000063a1', '00000000-0000-0000-0000-00000000000a', 'S63-P1', 'Pune pump', '00000000-0000-0000-0000-0000000063c1', '00000000-0000-0000-0000-0000000063e1'),
  ('00000000-0000-0000-0000-0000000063a2', '00000000-0000-0000-0000-00000000000a', 'S63-M1', 'Mumbai pump', '00000000-0000-0000-0000-0000000063c1', '00000000-0000-0000-0000-0000000063e2');
insert into public.security_group (id, tenant_id, code, name, group_type) values
  ('00000000-0000-0000-0000-0000000063b1', '00000000-0000-0000-0000-00000000000a', 's63', 'S63 group', 'role'),
  ('00000000-0000-0000-0000-0000000063b2', '00000000-0000-0000-0000-00000000000a', 's63_sys', 'S63 system', 'system');
insert into public.user_group_assignment (id, tenant_id, user_id, security_group_id) values
  ('00000000-0000-0000-0000-0000000063d1', '00000000-0000-0000-0000-00000000000a', '00000000-0000-0000-0000-0000000000a1', '00000000-0000-0000-0000-0000000063b1');

-- Runs a statement and the deferred checks now, as a commit would.
create function pg_temp.at_commit(p_sql text) returns void language plpgsql as $$
begin
  execute p_sql;
  set constraints all immediate;
  set constraints all deferred;
end;
$$;
create function pg_temp.ops(p_domain text, p_ops text[]) returns uuid[] language sql as $$
  select coalesce(array_agg(o.id), '{}') from public.domain_operation o
  join public.security_domain d on d.id = o.security_domain_id where d.code = p_domain and o.code = any (p_ops);
$$;
create function pg_temp.live(p_group uuid) returns setof text language sql as $$
  select o.code from public.group_domain_policy p join public.domain_operation o on o.id = p.domain_operation_id
  where p.security_group_id = p_group and p.deleted_at is null order by o.code;
$$;
create function pg_temp.version(p_user uuid) returns int language sql as $$
  select permission_version from public.tenant_membership
  where tenant_id = '00000000-0000-0000-0000-00000000000a' and user_id = p_user;
$$;
-- 6.4: the grid now writes a draft; save = draft, then activate it (6_4_change_sets.test.sql).
create function pg_temp.save(p_group uuid, p_ops uuid[]) returns void language plpgsql as $$
declare v uuid;
begin
  perform public.set_group_policies(p_group, p_ops);
  select id into v from public.policy_change_set where status = 'draft';
  if v is not null then perform public.activate_change_set(v); end if;
end;
$$;
create temp table v0 as select pg_temp.version('00000000-0000-0000-0000-0000000000a1') as v;
grant select on v0 to authenticated;

-- security_members [G4].
select ok(not has_function_privilege('anon', 'public.security_members()', 'execute'), 'anon cannot list members');
select tests.act_as('00000000-0000-0000-0000-0000000a0002', '00000000-0000-0000-0000-00000000000a');
select is_empty($$select * from public.security_members()$$, 'members: nothing without users_security.view');
select tests.act_as('00000000-0000-0000-0000-0000000a0005', '00000000-0000-0000-0000-00000000000a');
select is((select count(*) from public.security_members()), 6::bigint, 'members: view lists the six members of A');
select ok(not exists (select 1 from public.security_members() where email = 'test.user2@example.com'),
  'members: a member of B only never shows');
select is((select display_name from public.security_members() where user_id = '00000000-0000-0000-0000-0000000000a1'),
  'Test User', 'members: name comes from user_profile');

-- set_group_policies [G3].
select throws_ok($$select public.set_group_policies('00000000-0000-0000-0000-0000000063b1', pg_temp.ops('asset_core', '{view}'))$$,
  '42501', 'not allowed', 'set policies: view only is refused');
select tests.act_as('00000000-0000-0000-0000-0000000a0001', '00000000-0000-0000-0000-00000000000a');
select lives_ok($$select pg_temp.at_commit($q$select pg_temp.save('00000000-0000-0000-0000-0000000063b1', pg_temp.ops('asset_core', '{view,update}'))$q$)$$,
  'set policies: admin grants view and update');
select results_eq($$select pg_temp.live('00000000-0000-0000-0000-0000000063b1')$$, array['update', 'view'], 'set policies: two live grants');
reset role;
select is((select count(*) from private.user_effective_permission
           where tenant_id = '00000000-0000-0000-0000-00000000000a' and user_id = '00000000-0000-0000-0000-0000000000a1'),
  2::bigint, 'set policies: the member is rebuilt');
select ok(pg_temp.version('00000000-0000-0000-0000-0000000000a1') > (select v from v0), 'set policies: permission_version moves');
create temp table view_row as
  select p.id from public.group_domain_policy p join public.domain_operation o on o.id = p.domain_operation_id
  join public.security_domain d on d.id = o.security_domain_id
  where p.security_group_id = '00000000-0000-0000-0000-0000000063b1' and p.deleted_at is null and d.code = 'asset_core' and o.code = 'view';
grant select on view_row to authenticated;
select tests.act_as('00000000-0000-0000-0000-0000000a0001', '00000000-0000-0000-0000-00000000000a');
select lives_ok($$select pg_temp.save('00000000-0000-0000-0000-0000000063b1', pg_temp.ops('asset_core', '{view,create}'))$$,
  'set policies: swap update for create');
select results_eq($$select pg_temp.live('00000000-0000-0000-0000-0000000063b1')$$, array['create', 'view'], 'set policies: update removed, create added');
select ok(exists (select 1 from public.group_domain_policy where id = (select id from view_row) and deleted_at is null),
  'set policies: an unchanged grant keeps its row');
select lives_ok($$select pg_temp.save('00000000-0000-0000-0000-0000000063b1', pg_temp.ops('asset_core', '{view,create}'))$$,
  'set policies: same set again');
select is((select count(*) from public.group_domain_policy where security_group_id = '00000000-0000-0000-0000-0000000063b1'),
  3::bigint, 'set policies: the same set writes no row');
select throws_ok($$select public.set_group_policies('00000000-0000-0000-0000-0000000063b2', pg_temp.ops('asset_core', '{view}'))$$,
  '42501', 'system groups cannot be edited', 'set policies: system group refused');
select throws_ok($$select public.set_group_policies((select id from public.security_group where code = 'tenant_admin' and tenant_id = '00000000-0000-0000-0000-00000000000b'), '{}')$$,
  'P0002', 'group not found', 'set policies: another tenant''s group is not found');
select lives_ok($$select pg_temp.save('00000000-0000-0000-0000-0000000063b1', null)$$, 'set policies: null clears');
select is_empty($$select pg_temp.live('00000000-0000-0000-0000-0000000063b1')$$, 'set policies: no live grant left');

-- Group delete with live assignments [G7].
select throws_ok($$update public.security_group set deleted_at = now() where id = '00000000-0000-0000-0000-0000000063b1'$$,
  '23503', 'security group is assigned', 'group delete: refused while assigned');
update public.user_group_assignment set effective_to = now() - interval '1 second', effective_from = now() - interval '1 day'
  where id = '00000000-0000-0000-0000-0000000063d1';
select lives_ok($$update public.security_group set deleted_at = now() where id = '00000000-0000-0000-0000-0000000063b1'$$,
  'group delete: allowed once its assignments ended');

-- Review point through the UI's paths: a Pune-only Plant Manager sees no Mumbai asset.
insert into public.scope_profile (id, tenant_id, name) values
  ('00000000-0000-0000-0000-0000000063f1', '00000000-0000-0000-0000-00000000000a', 'S63 Pune only');
insert into public.scope_profile_rule (tenant_id, scope_profile_id, dimension, location_id) values
  ('00000000-0000-0000-0000-00000000000a', '00000000-0000-0000-0000-0000000063f1', 'location', '00000000-0000-0000-0000-0000000063e1');
insert into public.user_group_assignment (tenant_id, user_id, security_group_id, scope_profile_id)
select '00000000-0000-0000-0000-00000000000a', '00000000-0000-0000-0000-0000000000a1', g.id, '00000000-0000-0000-0000-0000000063f1'
from public.security_group g where g.tenant_id = '00000000-0000-0000-0000-00000000000a' and g.code = 'plant_manager';
select tests.act_as('00000000-0000-0000-0000-0000000000a1', '00000000-0000-0000-0000-00000000000a');
select results_eq($$select tag from public.asset where tag like 'S63-%'$$, array['S63-P1'], 'review point: Pune manager sees Pune only');

-- Lock-out guard [G5, G6]. admin.a is A's only security manager.
select tests.act_as('00000000-0000-0000-0000-0000000a0001', '00000000-0000-0000-0000-00000000000a');
create function pg_temp.admin_ops_without_manage() returns uuid[] language sql as $q$
  select array_agg(p.domain_operation_id) from public.group_domain_policy p
  join public.security_group g on g.id = p.security_group_id
  where g.tenant_id = '00000000-0000-0000-0000-00000000000a' and g.code = 'tenant_admin' and p.deleted_at is null
    and p.domain_operation_id <> all (pg_temp.ops('users_security', '{manage}'));
$q$;
select throws_ok($$select pg_temp.at_commit($q$select pg_temp.save(id, pg_temp.admin_ops_without_manage())
    from public.security_group where tenant_id = '00000000-0000-0000-0000-00000000000a' and code = 'tenant_admin'$q$)$$,
  '42501', 'last security admin', 'lock-out: revoking manage from the last admin group');
select throws_ok($$select pg_temp.at_commit($q$update public.user_group_assignment set deleted_at = now()
    where tenant_id = '00000000-0000-0000-0000-00000000000a' and user_id = '00000000-0000-0000-0000-0000000a0001'$q$)$$,
  '42501', 'last security admin', 'lock-out: removing the last admin assignment');
select throws_ok($$select pg_temp.at_commit($q$update public.user_group_assignment set effective_to = now() + interval '1 day'
    where tenant_id = '00000000-0000-0000-0000-00000000000a' and user_id = '00000000-0000-0000-0000-0000000a0001'$q$)$$,
  '42501', 'last security admin', 'lock-out: an end date on the last admin assignment');
select throws_ok($$select pg_temp.at_commit($q$update public.tenant_membership set status = 'disabled'
    where tenant_id = '00000000-0000-0000-0000-00000000000a' and user_id = '00000000-0000-0000-0000-0000000a0001'$q$)$$,
  '42501', 'last security admin', 'lock-out: disabling the last admin');
select ok(private.has_permission('users_security', 'manage'), 'lock-out: refused changes left the admin in place');

-- A second manager makes the same removal pass.
reset role;
insert into public.user_group_assignment (tenant_id, user_id, security_group_id)
select tenant_id, '00000000-0000-0000-0000-0000000000a1', id from public.security_group
where tenant_id = '00000000-0000-0000-0000-00000000000a' and code = 'tenant_admin';
select tests.act_as('00000000-0000-0000-0000-0000000a0001', '00000000-0000-0000-0000-00000000000a');
select lives_ok($$select pg_temp.at_commit($q$update public.user_group_assignment set deleted_at = now()
    where tenant_id = '00000000-0000-0000-0000-00000000000a' and user_id = '00000000-0000-0000-0000-0000000a0001'$q$)$$,
  'lock-out: an admin can leave when another remains');

-- System jobs (no auth.uid()) are not blocked: they repair tenants.
reset role;
select set_config('request.jwt.claims', '', true);
select lives_ok($$select pg_temp.at_commit($q$update public.user_group_assignment set deleted_at = now()
    where tenant_id = '00000000-0000-0000-0000-00000000000a' and user_id = '00000000-0000-0000-0000-0000000000a1'$q$)$$,
  'lock-out: postgres may remove the last admin');

select * from finish();
rollback;
