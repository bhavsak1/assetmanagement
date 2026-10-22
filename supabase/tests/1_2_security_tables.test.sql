-- Story 1.2. Uses the seed: tenant A and B; test.user (a1) in A and B, test.user2 (a2) in B only.
begin;
select plan(22);

-- RLS on for every new table.
select ok((select relrowsecurity from pg_class where oid = 'public.security_domain'::regclass), 'RLS on security_domain');
select ok((select relrowsecurity from pg_class where oid = 'public.domain_operation'::regclass), 'RLS on domain_operation');
select ok((select relrowsecurity from pg_class where oid = 'public.security_group'::regclass), 'RLS on security_group');
select ok((select relrowsecurity from pg_class where oid = 'public.group_domain_policy'::regclass), 'RLS on group_domain_policy');
select ok((select relrowsecurity from pg_class where oid = 'public.user_group_assignment'::regclass), 'RLS on user_group_assignment');

-- Catalog seeded, and re-running the seed adds nothing. Counts include rls_sample (1.4, 1 domain, 4 ops)
-- and the 3.1 operations asset_core.set_tag and asset_lifecycle.reopen.
select results_eq(
  'select (select count(*)::int from public.security_domain), (select count(*)::int from public.domain_operation)',
  $$values (21, 53)$$, 'catalog seeded'
);
select lives_ok('select private.seed_domain_catalog()', 'catalog seed re-runs');
select results_eq(
  'select (select count(*)::int from public.security_domain), (select count(*)::int from public.domain_operation)',
  $$values (21, 53)$$, 'catalog seed is idempotent'
);

-- Composite FKs: a row can never point at another tenant's group or a non-member.
insert into public.security_group (id, tenant_id, code, name) values
  ('00000000-0000-0000-0000-0000000006a1', '00000000-0000-0000-0000-00000000000a', 'test_group_a', 'Test group A'),
  ('00000000-0000-0000-0000-0000000006b1', '00000000-0000-0000-0000-00000000000b', 'test_group_b', 'Test group B');
insert into public.group_domain_policy (tenant_id, security_group_id, domain_operation_id)
select '00000000-0000-0000-0000-00000000000a', '00000000-0000-0000-0000-0000000006a1', o.id
from public.domain_operation o join public.security_domain d on d.id = o.security_domain_id
where d.code = 'asset_core' and o.code = 'view';
insert into public.user_group_assignment (tenant_id, user_id, security_group_id) values
  ('00000000-0000-0000-0000-00000000000a', '00000000-0000-0000-0000-0000000000a1', '00000000-0000-0000-0000-0000000006a1');

select throws_ok(
  $$insert into public.user_group_assignment (tenant_id, user_id, security_group_id) values
    ('00000000-0000-0000-0000-00000000000a', '00000000-0000-0000-0000-0000000000a1', '00000000-0000-0000-0000-0000000006b1')$$,
  '23503', null, 'assignment cannot use another tenant''s group'
);
select throws_ok(
  $$insert into public.user_group_assignment (tenant_id, user_id, security_group_id) values
    ('00000000-0000-0000-0000-00000000000a', '00000000-0000-0000-0000-0000000000a2', '00000000-0000-0000-0000-0000000006a1')$$,
  '23503', null, 'assignment cannot name a non-member of the tenant'
);
select throws_ok(
  $$insert into public.group_domain_policy (tenant_id, security_group_id, domain_operation_id)
    select '00000000-0000-0000-0000-00000000000a', '00000000-0000-0000-0000-0000000006b1', id from public.domain_operation limit 1$$,
  '23503', null, 'policy cannot use another tenant''s group'
);

-- A disabled member keeps (and may get) assignment rows as history. 1.3 rebuild grants them nothing.
update public.tenant_membership set status = 'disabled'
where tenant_id = '00000000-0000-0000-0000-00000000000b' and user_id = '00000000-0000-0000-0000-0000000000a1';
select lives_ok(
  $$insert into public.user_group_assignment (tenant_id, user_id, security_group_id) values
    ('00000000-0000-0000-0000-00000000000b', '00000000-0000-0000-0000-0000000000a1', '00000000-0000-0000-0000-0000000006b1')$$,
  'disabled member can hold assignment rows'
);

-- a1 in tenant A.
set local role authenticated;
set local request.jwt.claims = '{"sub":"00000000-0000-0000-0000-0000000000a1","role":"authenticated","tenant_id":"00000000-0000-0000-0000-00000000000a"}';

-- Catalog closed to users until 1.3 adds the users_security.view policy (owner decision).
select is((select count(*)::int from public.security_domain), 0, 'security_domain closed to users');
select is((select count(*)::int from public.domain_operation), 0, 'domain_operation closed to users');
select throws_ok($$insert into public.security_domain (code, entity, kind, description) values ('x', 'x', 'entity', 'x')$$,
  '42501', null, 'authenticated cannot add a domain');
select throws_ok($$update public.domain_operation set sort_order = 9$$, '42501', null, 'authenticated cannot change an operation');
select throws_ok($$delete from public.security_domain$$, '42501', null, 'authenticated cannot delete a domain');

-- Tenant tables are closed until 1.3 adds has_permission() policies, so no cross-tenant reads.
select is((select count(*)::int from public.security_group), 0, 'security_group closed');
select is((select count(*)::int from public.group_domain_policy), 0, 'group_domain_policy closed');
select is((select count(*)::int from public.user_group_assignment), 0, 'user_group_assignment closed');
select throws_ok(
  $$insert into public.security_group (tenant_id, code, name) values ('00000000-0000-0000-0000-00000000000b', 'x', 'x')$$,
  '42501', null, 'user cannot create a group'
);

-- a2 (not in A) with a forged tenant A claim still reads nothing.
set local request.jwt.claims = '{"sub":"00000000-0000-0000-0000-0000000000a2","role":"authenticated","tenant_id":"00000000-0000-0000-0000-00000000000a"}';
select is((select count(*)::int from public.security_group where tenant_id = '00000000-0000-0000-0000-00000000000a'), 0, 'forged tenant claim reads no groups');
reset role;

select * from finish();
rollback;
