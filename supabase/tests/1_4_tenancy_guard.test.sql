-- Story 1.4: CI guard (CLAUDE.md §6.2, §6.8), plus the hand-written cross-tenant tests for the two
-- non-catalog tables without tenant_id, tenant and user_profile (data-model-goal1.md §2).
begin;
select plan(7);

select is(
  array(select c.oid::regclass::text from pg_class c
        where c.relnamespace = 'public'::regnamespace and c.relkind in ('r', 'p') and not c.relrowsecurity
        order by 1),
  '{}'::text[], 'every public table has RLS on'
);
select is(
  array(select format('%I.%I', n.nspname, c.relname) from pg_class c
        join pg_namespace n on n.oid = c.relnamespace
        join pg_attribute a on a.attrelid = c.oid and a.attname = 'tenant_id' and not a.attisdropped
        where n.nspname in ('public', 'private') and c.relkind in ('r', 'p') and not c.relrowsecurity
        order by 1),
  '{}'::text[], 'every tenant_id table has RLS on'
);
-- public only: private tables are not exposed to the API and stay closed on purpose (no policies).
select is(
  array(select c.relname::text from pg_class c
        join pg_attribute a on a.attrelid = c.oid and a.attname = 'tenant_id' and not a.attisdropped
        where c.relnamespace = 'public'::regnamespace and c.relkind in ('r', 'p')
          and not exists (select 1 from pg_policy p where p.polrelid = c.oid)
        order by 1),
  '{}'::text[], 'every public tenant_id table has a policy'
);

-- a2 is in tenant B only. a1 shares tenant B with a2.
select tests.act_as('00000000-0000-0000-0000-0000000000a2', '00000000-0000-0000-0000-00000000000b');
select is_empty($$update public.tenant set name = 'x' returning 1$$, 'user cannot update any tenant');
select is_empty($$delete from public.tenant returning 1$$, 'user cannot delete any tenant');
select is((select count(*)::int from public.user_profile where id = '00000000-0000-0000-0000-0000000000a1'), 0, 'user cannot read another user profile');
select is_empty(
  $$update public.user_profile set display_name = 'x' where id = '00000000-0000-0000-0000-0000000000a1' returning 1$$,
  'user cannot update another user profile'
);

select * from finish();
rollback;
