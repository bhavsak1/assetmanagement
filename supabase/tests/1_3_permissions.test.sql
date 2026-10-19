-- Story 1.3. Uses the seed: tenant A (active) and B (read_only); test.user (a1) in A and B,
-- test.user2 (a2) in B only. Groups, policies and assignments are made here and rolled back.
begin;
select plan(57);

-- Operation id by codes. Security invoker, so as a user it reads the catalog under RLS.
create function pg_temp.op(p_domain text, p_op text) returns uuid language sql as $$
  select o.id from public.domain_operation o join public.security_domain d on d.id = o.security_domain_id
  where d.code = p_domain and o.code = p_op
$$;
create function pg_temp.version(p_tenant char, p_user char) returns int language sql as $$
  select permission_version from public.tenant_membership
  where tenant_id = ('00000000-0000-0000-0000-00000000000' || p_tenant)::uuid
    and user_id = ('00000000-0000-0000-0000-0000000000a' || p_user)::uuid
$$;

select ok((select relrowsecurity from pg_class where oid = 'private.user_effective_permission'::regclass), 'RLS on user_effective_permission');
select ok(not has_table_privilege('authenticated', 'private.user_effective_permission', 'select'), 'authenticated cannot read user_effective_permission');
select ok(not has_function_privilege('authenticated', 'private.rebuild_effective_permission(uuid, uuid)', 'execute'), 'authenticated cannot run the rebuild');
select ok(has_function_privilege('authenticated', 'private.has_permission(text, text)', 'execute'), 'authenticated can run has_permission');
select ok(not has_function_privilege('anon', 'private.has_permission(text, text)', 'execute'), 'anon cannot run has_permission');

-- Groups. A: view (asset_core view+create), vendor (asset_core view, vendor_core view),
-- old (vendor_tax_ids view, assigned outside its window), admin (users_security), sys (system).
-- B: admin (users_security).
insert into public.security_group (id, tenant_id, code, name, group_type) values
  ('00000000-0000-0000-0000-0000000007a1', '00000000-0000-0000-0000-00000000000a', 'test_view',   'Test view',   'role'),
  ('00000000-0000-0000-0000-0000000007a2', '00000000-0000-0000-0000-00000000000a', 'test_vendor', 'Test vendor', 'role'),
  ('00000000-0000-0000-0000-0000000007a3', '00000000-0000-0000-0000-00000000000a', 'test_old',    'Test old',    'role'),
  ('00000000-0000-0000-0000-0000000007a4', '00000000-0000-0000-0000-00000000000a', 'test_admin',  'Test admin',  'role'),
  ('00000000-0000-0000-0000-0000000007a5', '00000000-0000-0000-0000-00000000000a', 'test_sys',    'Test sys',    'system'),
  ('00000000-0000-0000-0000-0000000007b1', '00000000-0000-0000-0000-00000000000b', 'test_admin',  'Test admin',  'role');
insert into public.group_domain_policy (tenant_id, security_group_id, domain_operation_id) values
  ('00000000-0000-0000-0000-00000000000a', '00000000-0000-0000-0000-0000000007a1', pg_temp.op('asset_core', 'view')),
  ('00000000-0000-0000-0000-00000000000a', '00000000-0000-0000-0000-0000000007a1', pg_temp.op('asset_core', 'create')),
  ('00000000-0000-0000-0000-00000000000a', '00000000-0000-0000-0000-0000000007a2', pg_temp.op('asset_core', 'view')),
  ('00000000-0000-0000-0000-00000000000a', '00000000-0000-0000-0000-0000000007a2', pg_temp.op('vendor_core', 'view')),
  ('00000000-0000-0000-0000-00000000000a', '00000000-0000-0000-0000-0000000007a3', pg_temp.op('vendor_tax_ids', 'view')),
  ('00000000-0000-0000-0000-00000000000a', '00000000-0000-0000-0000-0000000007a4', pg_temp.op('users_security', 'view')),
  ('00000000-0000-0000-0000-00000000000a', '00000000-0000-0000-0000-0000000007a4', pg_temp.op('users_security', 'manage')),
  ('00000000-0000-0000-0000-00000000000a', '00000000-0000-0000-0000-0000000007a5', pg_temp.op('audit_log', 'view')),
  ('00000000-0000-0000-0000-00000000000b', '00000000-0000-0000-0000-0000000007b1', pg_temp.op('users_security', 'view')),
  ('00000000-0000-0000-0000-00000000000b', '00000000-0000-0000-0000-0000000007b1', pg_temp.op('users_security', 'manage'));
select is(pg_temp.version('a', '1'), 1, 'no bump while a group has no members');

-- a1 in A: five assignments, one bump each. test_old twice: expired, and starting tomorrow.
insert into public.user_group_assignment (id, tenant_id, user_id, security_group_id, effective_from, effective_to) values
  ('00000000-0000-0000-0000-0000000008a1', '00000000-0000-0000-0000-00000000000a', '00000000-0000-0000-0000-0000000000a1', '00000000-0000-0000-0000-0000000007a1', now(), null),
  ('00000000-0000-0000-0000-0000000008a2', '00000000-0000-0000-0000-00000000000a', '00000000-0000-0000-0000-0000000000a1', '00000000-0000-0000-0000-0000000007a2', now(), null),
  ('00000000-0000-0000-0000-0000000008a3', '00000000-0000-0000-0000-00000000000a', '00000000-0000-0000-0000-0000000000a1', '00000000-0000-0000-0000-0000000007a3', now() - interval '2 days', now() - interval '1 day'),
  ('00000000-0000-0000-0000-0000000008a4', '00000000-0000-0000-0000-00000000000a', '00000000-0000-0000-0000-0000000000a1', '00000000-0000-0000-0000-0000000007a3', now() + interval '1 day', null),
  ('00000000-0000-0000-0000-0000000008a5', '00000000-0000-0000-0000-00000000000a', '00000000-0000-0000-0000-0000000000a1', '00000000-0000-0000-0000-0000000007a4', now(), null);
-- a1 in B (read_only tenant): admin.
insert into public.user_group_assignment (tenant_id, user_id, security_group_id) values
  ('00000000-0000-0000-0000-00000000000b', '00000000-0000-0000-0000-0000000000a1', '00000000-0000-0000-0000-0000000007b1');

-- Rebuild: one row per (assignment, operation), union across groups.
select is(
  (select count(*)::int from private.user_effective_permission
   where tenant_id = '00000000-0000-0000-0000-00000000000a' and user_id = '00000000-0000-0000-0000-0000000000a1'),
  8, 'rebuild writes one row per assignment and operation'
);
select results_eq(
  $$select distinct d.code || '.' || o.code from private.user_effective_permission u
    join public.domain_operation o on o.id = u.domain_operation_id join public.security_domain d on d.id = o.security_domain_id
    where u.tenant_id = '00000000-0000-0000-0000-00000000000a' and u.user_id = '00000000-0000-0000-0000-0000000000a1' order by 1$$,
  $$values ('asset_core.create'), ('asset_core.view'), ('users_security.manage'), ('users_security.view'), ('vendor_core.view'), ('vendor_tax_ids.view')$$,
  'rebuild is the union of every group the member holds'
);
select is(
  (select count(*)::int from private.user_effective_permission where user_id = '00000000-0000-0000-0000-0000000000a2'),
  0, 'member with no assignments has no rows'
);

-- Version bump [D4].
select is(pg_temp.version('a', '1'), 6, 'each assignment bumps the member version');
select is(pg_temp.version('b', '1'), 2, 'assignment in B bumps only the B membership');
insert into public.group_domain_policy (tenant_id, security_group_id, domain_operation_id) values
  ('00000000-0000-0000-0000-00000000000a', '00000000-0000-0000-0000-0000000007a1', pg_temp.op('asset_core', 'update'));
select is(pg_temp.version('a', '1'), 7, 'policy insert bumps the group''s members');
update public.group_domain_policy set deleted_at = now()
where security_group_id = '00000000-0000-0000-0000-0000000007a1' and domain_operation_id = pg_temp.op('asset_core', 'update');
select is(pg_temp.version('a', '1'), 8, 'policy soft delete bumps the group''s members');
select is(pg_temp.version('b', '2'), 1, 'other members are not bumped');

-- has_permission as a1 in A.
set local role authenticated;
set local request.jwt.claims = '{"sub":"00000000-0000-0000-0000-0000000000a1","role":"authenticated","tenant_id":"00000000-0000-0000-0000-00000000000a"}';
select ok(private.has_permission('asset_core', 'view'), 'granted operation is true');
select ok(private.has_permission('asset_core', 'create'), 'operation from one group only is true');
select ok(private.has_permission('vendor_core', 'view'), 'operation from another group is true (union)');
select ok(not private.has_permission('vendor_core', 'create'), 'operation no group grants is false');
select ok(not private.has_permission('asset_core', 'update'), 'soft-deleted policy grants nothing');
select ok(not private.has_permission('no_such_domain', 'view'), 'unknown domain is false');
select ok(not private.has_permission('vendor_tax_ids', 'view'), 'expired and future assignments grant nothing');
select ok(not private.has_permission('audit_log', 'view'), 'unassigned group grants nothing');
select ok(private.tenant_can_write(), 'active tenant can write');
reset role;

-- Additive, no deny: dropping one group leaves what another group grants.
update public.user_group_assignment set deleted_at = now() where id = '00000000-0000-0000-0000-0000000008a2';
set local role authenticated;
select ok(private.has_permission('asset_core', 'view'), 'still granted by the other group');
select ok(not private.has_permission('vendor_core', 'view'), 'operation only the removed group gave is gone');

-- Policies as a1 in A, a security admin.
select results_eq(
  'select (select count(*)::int from public.security_domain), (select count(*)::int from public.domain_operation)',
  $$values (21, 51)$$, 'security admin reads the catalog (incl. rls_sample, 1.4)'
);
select is((select count(*)::int from public.security_group), 5, 'admin reads only current tenant groups');
select is((select count(*)::int from public.group_domain_policy where tenant_id <> '00000000-0000-0000-0000-00000000000a'), 0, 'admin reads no other tenant policies');
select is((select count(*)::int from public.user_group_assignment where tenant_id <> '00000000-0000-0000-0000-00000000000a'), 0, 'admin reads no other tenant assignments');
select is((select count(*)::int from public.tenant_membership where tenant_id = '00000000-0000-0000-0000-00000000000a'), 1, 'admin reads current tenant members');
select lives_ok(
  $$insert into public.security_group (tenant_id, code, name) values ('00000000-0000-0000-0000-00000000000a', 'test_new', 'Test new')$$,
  'admin creates a group'
);
select throws_ok(
  $$insert into public.security_group (tenant_id, code, name) values ('00000000-0000-0000-0000-00000000000b', 'test_x', 'x')$$,
  '42501', null, 'admin cannot create a group in another tenant'
);
select throws_ok(
  $$insert into public.security_group (tenant_id, code, name, group_type) values ('00000000-0000-0000-0000-00000000000a', 'test_x', 'x', 'system')$$,
  '42501', null, 'admin cannot create a system group'
);
select is_empty($$update public.security_group set name = 'x' where id = '00000000-0000-0000-0000-0000000007a5' returning 1$$, 'admin cannot edit a system group');
select throws_ok(
  $$update public.security_group set group_type = 'system' where id = '00000000-0000-0000-0000-0000000007a1'$$,
  '42501', null, 'admin cannot turn a group into a system group'
);
select throws_ok($$delete from public.security_group where id = '00000000-0000-0000-0000-0000000007a1'$$, '42501', null, 'no hard delete of a group');
select lives_ok(
  $$insert into public.group_domain_policy (tenant_id, security_group_id, domain_operation_id)
    values ('00000000-0000-0000-0000-00000000000a', '00000000-0000-0000-0000-0000000007a1', pg_temp.op('asset_core', 'delete'))$$,
  'admin grants an operation'
);
select ok(private.has_permission('asset_core', 'delete'), 'new grant applies in the same transaction');
select throws_ok(
  $$insert into public.group_domain_policy (tenant_id, security_group_id, domain_operation_id)
    values ('00000000-0000-0000-0000-00000000000a', '00000000-0000-0000-0000-0000000007a5', pg_temp.op('asset_core', 'view'))$$,
  '42501', null, 'admin cannot grant to a system group'
);
select throws_ok($$delete from public.group_domain_policy$$, '42501', null, 'no hard delete of a policy');
select lives_ok(
  $$update public.user_group_assignment set effective_to = now() + interval '1 hour' where id = '00000000-0000-0000-0000-0000000008a1'$$,
  'admin changes an assignment'
);
select throws_ok($$delete from public.user_group_assignment$$, '42501', null, 'no hard delete of an assignment');
select throws_ok(
  $$update public.tenant_membership set permission_version = 99 where tenant_id = '00000000-0000-0000-0000-00000000000a'$$,
  '42501', null, 'admin cannot set permission_version'
);
select is((select count(*)::int from public.tenant_entitlement), 2, 'entitlement policy still reads current tenant');

-- a1 in B: admin there too, but B is read_only.
set local request.jwt.claims = '{"sub":"00000000-0000-0000-0000-0000000000a1","role":"authenticated","tenant_id":"00000000-0000-0000-0000-00000000000b"}';
select ok(not private.tenant_can_write(), 'read_only tenant cannot write');
select ok(not private.has_permission('asset_core', 'view'), 'grant in tenant A is false in tenant B');
select is((select count(*)::int from public.security_group), 1, 'read_only tenant still reads');
select throws_ok(
  $$insert into public.security_group (tenant_id, code, name) values ('00000000-0000-0000-0000-00000000000b', 'test_x', 'x')$$,
  '42501', null, 'read_only tenant cannot create a group'
);
select is_empty($$update public.security_group set name = 'x' returning 1$$, 'read_only tenant cannot edit a group');

-- a2 in B, no grants: nothing.
set local request.jwt.claims = '{"sub":"00000000-0000-0000-0000-0000000000a2","role":"authenticated","tenant_id":"00000000-0000-0000-0000-00000000000b"}';
select is((select count(*)::int from public.security_domain), 0, 'catalog closed without users_security.view');
select is((select count(*)::int from public.security_group), 0, 'groups closed without users_security.view');

-- Cross-tenant: a2 with a forged tenant A claim.
set local request.jwt.claims = '{"sub":"00000000-0000-0000-0000-0000000000a2","role":"authenticated","tenant_id":"00000000-0000-0000-0000-00000000000a"}';
select ok(not private.has_permission('users_security', 'view'), 'forged tenant claim grants nothing');
select is((select count(*)::int from public.user_group_assignment), 0, 'forged tenant claim reads no assignments');
reset role;

-- Disabled membership: rows removed, version bumped, nothing granted.
update public.tenant_membership set status = 'disabled'
where tenant_id = '00000000-0000-0000-0000-00000000000b' and user_id = '00000000-0000-0000-0000-0000000000a1';
select is(
  (select count(*)::int from private.user_effective_permission
   where tenant_id = '00000000-0000-0000-0000-00000000000b' and user_id = '00000000-0000-0000-0000-0000000000a1'),
  0, 'disabled member has no rows'
);
select is(pg_temp.version('b', '1'), 3, 'disabling a member bumps the version');
update public.tenant set status = 'suspended' where id = '00000000-0000-0000-0000-00000000000b';
set local role authenticated;
set local request.jwt.claims = '{"sub":"00000000-0000-0000-0000-0000000000a1","role":"authenticated","tenant_id":"00000000-0000-0000-0000-00000000000b"}';
select ok(not private.has_permission('users_security', 'view'), 'disabled member''s assignment grants nothing');
select ok(not private.tenant_can_write(), 'suspended tenant cannot write');
reset role;

select * from finish();
rollback;
