-- Story 8.1: the service login role holds no rights of its own (docs/data-model-goal8.md §2).
begin;
select plan(6);

select is(
  (select row(rolcanlogin, rolinherit, rolsuper, rolbypassrls, rolcreaterole, rolcreatedb)::text
   from pg_roles where rolname = 'assetly_api'),
  '(t,f,f,f,f,f)', 'assetly_api: login, noinherit, no superuser, bypassrls, createrole or createdb'
);
select is(
  array(select r.rolname::text from pg_auth_members m
        join pg_roles r on r.oid = m.roleid
        where m.member = 'assetly_api'::regrole order by 1),
  '{authenticated}'::text[], 'assetly_api is a member of authenticated only'
);
select is(
  (select count(*)::int from information_schema.role_table_grants where grantee = 'assetly_api'),
  0, 'assetly_api has no table grants of its own'
);

-- noinherit: privileges of authenticated apply only after set role, never by default.
select ok(not has_table_privilege('assetly_api', 'public.tenant', 'select'), 'without set role it cannot read tenant');
select ok(not has_table_privilege('assetly_api', 'public.asset', 'select'), 'without set role it cannot read asset');
select ok(not pg_has_role('assetly_api', 'service_role', 'member'), 'it cannot become service_role');

select * from finish();
rollback;
