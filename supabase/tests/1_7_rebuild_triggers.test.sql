-- Story 1.7: statement-level policy triggers (G1) and the distinct rebuild (G2).
-- Uses the seed: tenant A, test.user (a1, no groups) and admin.a (Tenant Admin). Rolled back.
begin;
select plan(13);

create function pg_temp.op(p_domain text, p_op text) returns uuid language sql as $$
  select o.id from public.domain_operation o join public.security_domain d on d.id = o.security_domain_id
  where d.code = p_domain and o.code = p_op
$$;
-- Rows a user holds for one operation in tenant A.
create function pg_temp.rows(p_user uuid, p_domain text, p_op text) returns int language sql as $$
  select count(*)::int from private.user_effective_permission
  where tenant_id = '00000000-0000-0000-0000-00000000000a' and user_id = p_user and domain_operation_id = pg_temp.op(p_domain, p_op)
$$;
create function pg_temp.version(p_user uuid) returns int language sql as $$
  select permission_version from public.tenant_membership
  where tenant_id = '00000000-0000-0000-0000-00000000000a' and user_id = p_user
$$;

select is(
  (select count(*)::int from pg_trigger where tgrelid = 'public.group_domain_policy'::regclass
   and tgname like 'refresh_permissions%' and tgtype & 1 = 0),
  3, 'policy rebuild triggers are statement-level (insert, update, delete)'
);
select is(
  (select count(*)::int from pg_trigger where tgrelid = 'public.group_domain_policy'::regclass
   and tgname like 'refresh_permissions%' and tgtype & 1 = 1),
  0, 'no row-level policy rebuild trigger left'
);

-- g1, g2 assigned to a1; g3 assigned to admin.a.
insert into public.security_group (id, tenant_id, code, name) values
  ('00000000-0000-0000-0000-0000000017a1', '00000000-0000-0000-0000-00000000000a', 'test_g1', 'Test g1'),
  ('00000000-0000-0000-0000-0000000017a2', '00000000-0000-0000-0000-00000000000a', 'test_g2', 'Test g2'),
  ('00000000-0000-0000-0000-0000000017a3', '00000000-0000-0000-0000-00000000000a', 'test_g3', 'Test g3');
insert into public.user_group_assignment (tenant_id, user_id, security_group_id) values
  ('00000000-0000-0000-0000-00000000000a', '00000000-0000-0000-0000-0000000000a1', '00000000-0000-0000-0000-0000000017a1'),
  ('00000000-0000-0000-0000-00000000000a', '00000000-0000-0000-0000-0000000000a1', '00000000-0000-0000-0000-0000000017a2'),
  ('00000000-0000-0000-0000-00000000000a', '00000000-0000-0000-0000-0000000a0001', '00000000-0000-0000-0000-0000000017a3');

create temp table v as select pg_temp.version('00000000-0000-0000-0000-0000000000a1') as before;

-- G1: three policies on g1 and one on g2 in one statement.
insert into public.group_domain_policy (tenant_id, security_group_id, domain_operation_id) values
  ('00000000-0000-0000-0000-00000000000a', '00000000-0000-0000-0000-0000000017a1', pg_temp.op('rls_sample', 'view')),
  ('00000000-0000-0000-0000-00000000000a', '00000000-0000-0000-0000-0000000017a1', pg_temp.op('rls_sample', 'create')),
  ('00000000-0000-0000-0000-00000000000a', '00000000-0000-0000-0000-0000000017a1', pg_temp.op('rls_sample', 'update')),
  ('00000000-0000-0000-0000-00000000000a', '00000000-0000-0000-0000-0000000017a2', pg_temp.op('rls_sample', 'view'));
select is(pg_temp.version('00000000-0000-0000-0000-0000000000a1'), (select before + 1 from v),
  'multi-row policy insert over two groups bumps the member once');
select is(pg_temp.rows('00000000-0000-0000-0000-0000000000a1', 'rls_sample', 'create'), 1, 'multi-row insert grants each operation');
select is(pg_temp.rows('00000000-0000-0000-0000-0000000000a1', 'rls_sample', 'update'), 1, 'multi-row insert grants the last operation too');

-- G2: view comes from g1 and g2 with the same window, so one row.
select is(pg_temp.rows('00000000-0000-0000-0000-0000000000a1', 'rls_sample', 'view'), 1, 'the same grant from two groups is one row');

-- Update that moves a policy to another group refreshes both groups' members.
update public.group_domain_policy set security_group_id = '00000000-0000-0000-0000-0000000017a3'
where security_group_id = '00000000-0000-0000-0000-0000000017a1' and domain_operation_id = pg_temp.op('rls_sample', 'create');
select is(pg_temp.rows('00000000-0000-0000-0000-0000000000a1', 'rls_sample', 'create'), 0, 'moved policy: old group member loses it');
select is(pg_temp.rows('00000000-0000-0000-0000-0000000a0001', 'rls_sample', 'create'), 1, 'moved policy: new group member gains it');

-- Soft delete through update.
update public.group_domain_policy set deleted_at = now()
where security_group_id = '00000000-0000-0000-0000-0000000017a1' and domain_operation_id = pg_temp.op('rls_sample', 'update');
select is(pg_temp.rows('00000000-0000-0000-0000-0000000000a1', 'rls_sample', 'update'), 0, 'soft-deleted policy grants nothing');

-- Hard delete (system path). view stays while g2 still grants it.
delete from public.group_domain_policy
where security_group_id = '00000000-0000-0000-0000-0000000017a1' and domain_operation_id = pg_temp.op('rls_sample', 'view');
select is(pg_temp.rows('00000000-0000-0000-0000-0000000000a1', 'rls_sample', 'view'), 1, 'deleting one of two grants keeps the other');
delete from public.group_domain_policy where security_group_id = '00000000-0000-0000-0000-0000000017a2';
select is(pg_temp.rows('00000000-0000-0000-0000-0000000000a1', 'rls_sample', 'view'), 0, 'deleting the last grant revokes it');

-- A statement that touches no rows changes nothing.
update v set before = pg_temp.version('00000000-0000-0000-0000-0000000000a1');
update public.group_domain_policy set updated_at = now() where security_group_id = '00000000-0000-0000-0000-0000000017a2';
select is(pg_temp.version('00000000-0000-0000-0000-0000000000a1'), (select before from v), 'empty statement bumps nobody');

-- has_permission sees the rebuilt rows.
select tests.act_as('00000000-0000-0000-0000-0000000a0001', '00000000-0000-0000-0000-00000000000a');
select ok(private.has_permission('rls_sample', 'create'), 'has_permission reads the statement-trigger rebuild');
reset role;

select * from finish();
rollback;
