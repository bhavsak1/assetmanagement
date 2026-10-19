-- Story 1.4: the RLS pattern on rls_sample. Copy this file for each new tenant table.
-- Uses the seed (tenant A active, B read_only; a1 in A and B) and supabase/test_harness.sql.
begin;
select plan(27);

select policies_are('public', 'rls_sample', array['rls_sample_select', 'rls_sample_insert', 'rls_sample_update']);
select ok(not has_table_privilege('authenticated', 'public.rls_sample', 'delete'), 'no hard delete grant');
select results_eq(
  $$select o.code from public.domain_operation o join public.security_domain d on d.id = o.security_domain_id
    where d.code = 'rls_sample' order by o.sort_order$$,
  $$values ('view'), ('create'), ('update'), ('delete')$$,
  'domain seeded as data'
);

insert into public.rls_sample (id, tenant_id, name) values
  ('00000000-0000-0000-0000-0000000009a1', '00000000-0000-0000-0000-00000000000a', 'a-row'),
  ('00000000-0000-0000-0000-0000000009b1', '00000000-0000-0000-0000-00000000000b', 'b-row');

-- Default deny: a member with no grant.
select tests.act_as('00000000-0000-0000-0000-0000000000a1', '00000000-0000-0000-0000-00000000000a');
select is((select count(*)::int from public.rls_sample), 0, 'no grant, no rows');
select throws_ok(
  $$insert into public.rls_sample (tenant_id, name) values ('00000000-0000-0000-0000-00000000000a', 'x')$$,
  '42501', null, 'no grant, no insert'
);

-- view only.
reset role;
select tests.grant('00000000-0000-0000-0000-00000000000a', '00000000-0000-0000-0000-0000000000a1', 'rls_sample', '{view}');
select tests.act_as('00000000-0000-0000-0000-0000000000a1', '00000000-0000-0000-0000-00000000000a');
select results_eq('select name from public.rls_sample', $$values ('a-row')$$, 'view reads own tenant rows');
select throws_ok(
  $$insert into public.rls_sample (tenant_id, name) values ('00000000-0000-0000-0000-00000000000a', 'x')$$,
  '42501', null, 'view cannot insert'
);
select is_empty($$update public.rls_sample set name = 'x' returning 1$$, 'view cannot update');

-- create and update, no delete.
reset role;
select tests.grant('00000000-0000-0000-0000-00000000000a', '00000000-0000-0000-0000-0000000000a1', 'rls_sample', '{create,update}');
select tests.act_as('00000000-0000-0000-0000-0000000000a1', '00000000-0000-0000-0000-00000000000a');
select lives_ok(
  $$insert into public.rls_sample (id, tenant_id, parent_id, name) values
    ('00000000-0000-0000-0000-0000000009a2', '00000000-0000-0000-0000-00000000000a', '00000000-0000-0000-0000-0000000009a1', 'a-new')$$,
  'create inserts a row with a same-tenant parent'
);
select throws_ok(
  $$insert into public.rls_sample (tenant_id, parent_id, name) values
    ('00000000-0000-0000-0000-00000000000a', '00000000-0000-0000-0000-0000000009b1', 'x')$$,
  '23503', null, 'parent in another tenant is refused (composite FK)'
);
select lives_ok($$update public.rls_sample set name = 'a-row-2' where id = '00000000-0000-0000-0000-0000000009a1'$$, 'update edits a row');
select throws_ok(
  $$update public.rls_sample set deleted_at = now() where id = '00000000-0000-0000-0000-0000000009a2'$$,
  '42501', null, 'update alone cannot soft delete'
);
select throws_ok($$delete from public.rls_sample where id = '00000000-0000-0000-0000-0000000009a2'$$, '42501', null, 'no hard delete');

-- delete.
reset role;
select tests.grant('00000000-0000-0000-0000-00000000000a', '00000000-0000-0000-0000-0000000000a1', 'rls_sample', '{delete}');
select tests.act_as('00000000-0000-0000-0000-0000000000a1', '00000000-0000-0000-0000-00000000000a');
select lives_ok($$update public.rls_sample set deleted_at = now() where id = '00000000-0000-0000-0000-0000000009a2'$$, 'delete soft-deletes a row');
select is((select count(*)::int from public.rls_sample where id = '00000000-0000-0000-0000-0000000009a2'), 1, 'soft-deleted row stays readable');
select lives_ok(
  $$insert into public.rls_sample (tenant_id, name) values ('00000000-0000-0000-0000-00000000000a', 'a-new')$$,
  'name is free again after soft delete (partial unique)'
);

-- Tenant B is read_only: reads work, writes do not, even with every grant.
reset role;
select tests.grant('00000000-0000-0000-0000-00000000000b', '00000000-0000-0000-0000-0000000000a1', 'rls_sample');
select tests.act_as('00000000-0000-0000-0000-0000000000a1', '00000000-0000-0000-0000-00000000000b');
select results_eq('select name from public.rls_sample', $$values ('b-row')$$, 'read_only tenant reads');
select throws_ok(
  $$insert into public.rls_sample (tenant_id, name) values ('00000000-0000-0000-0000-00000000000b', 'x')$$,
  '42501', null, 'read_only tenant cannot insert'
);
select is_empty($$update public.rls_sample set name = 'x' returning 1$$, 'read_only tenant cannot update');

-- Cross-tenant harness: 8 tests.
reset role;
select * from tests.cross_tenant('public.rls_sample', 'rls_sample', '{"name":"ct-row"}');

select * from finish();
rollback;
