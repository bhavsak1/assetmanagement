-- Story 1.1. Uses the seed: tenant A (active) and B (read_only); test.user (a1) in A and B,
-- test.user2 (a2) in B only.
begin;
select plan(23);

-- RLS on for every new table.
select ok((select relrowsecurity from pg_class where oid = 'public.tenant'::regclass), 'RLS on tenant');
select ok((select relrowsecurity from pg_class where oid = 'public.user_profile'::regclass), 'RLS on user_profile');
select ok((select relrowsecurity from pg_class where oid = 'public.tenant_membership'::regclass), 'RLS on tenant_membership');
select ok((select relrowsecurity from pg_class where oid = 'public.tenant_entitlement'::regclass), 'RLS on tenant_entitlement');
select ok((select relrowsecurity from pg_class where oid = 'private.tenant_session'::regclass), 'RLS on tenant_session');

-- Seeded status and entitlement (OQ-30).
select results_eq(
  'select slug, status from public.tenant order by slug',
  $$values ('test-tenant-a', 'active'), ('test-tenant-b', 'read_only')$$,
  'tenant status seeded'
);
select is((select count(*)::int from public.tenant_entitlement), 3, 'entitlements seeded');

-- Hook grants: only supabase_auth_admin may run it.
select ok(has_function_privilege('supabase_auth_admin', 'private.custom_access_token_hook(jsonb)', 'execute'), 'auth admin can run hook');
select ok(not has_function_privilege('authenticated', 'private.custom_access_token_hook(jsonb)', 'execute'), 'authenticated cannot run hook');

-- Login sessions for the action and hook tests.
insert into auth.sessions (id, user_id) values
  ('00000000-0000-0000-0000-0000000005a1', '00000000-0000-0000-0000-0000000000a1'),
  ('00000000-0000-0000-0000-0000000005a2', '00000000-0000-0000-0000-0000000000a2');

-- a2, no tenant picked yet.
set local role authenticated;
set local request.jwt.claims = '{"sub":"00000000-0000-0000-0000-0000000000a2","role":"authenticated","session_id":"00000000-0000-0000-0000-0000000005a2"}';

select is((select count(*)::int from public.tenant_membership), 1, 'user reads only own membership');
select results_eq('select slug from public.tenant', $$values ('test-tenant-b')$$, 'user reads only tenants they belong to');
select is((select count(*)::int from public.user_profile), 1, 'user reads only own profile');
select is((select count(*)::int from public.tenant_entitlement), 0, 'no tenant claim, no entitlements');
select throws_ok(
  $$select public.select_tenant('00000000-0000-0000-0000-00000000000a')$$,
  '42501', null, 'cannot select a tenant without membership'
);

-- Cross-tenant: a2 with a forged tenant A claim still sees nothing of A.
set local request.jwt.claims = '{"sub":"00000000-0000-0000-0000-0000000000a2","role":"authenticated","tenant_id":"00000000-0000-0000-0000-00000000000a"}';
select is((select count(*)::int from public.tenant_entitlement), 0, 'forged tenant claim reads no entitlements');

-- a1 in tenant A.
set local request.jwt.claims = '{"sub":"00000000-0000-0000-0000-0000000000a1","role":"authenticated","session_id":"00000000-0000-0000-0000-0000000005a1","tenant_id":"00000000-0000-0000-0000-00000000000a"}';
select is((select count(*)::int from public.tenant_entitlement where tenant_id = '00000000-0000-0000-0000-00000000000a'), 2, 'member reads current tenant entitlements');
select is((select count(*)::int from public.tenant_entitlement where tenant_id <> '00000000-0000-0000-0000-00000000000a'), 0, 'member reads no other tenant entitlements');
select throws_ok(
  $$insert into public.tenant (name, slug, currency_code, time_zone, date_format) values ('x', 'x', 'INR', 'UTC', 'dd-MM-yyyy')$$,
  '42501', null, 'user cannot create a tenant'
);
select throws_ok(
  $$update public.user_profile set email = 'x@example.com'$$,
  '42501', null, 'user cannot change own email'
);
select lives_ok($$select public.select_tenant('00000000-0000-0000-0000-00000000000a')$$, 'member selects tenant A');
reset role;

-- Hook: member session gets tenant_id and version; no pick means no claims.
select is(
  private.custom_access_token_hook(
    '{"user_id":"00000000-0000-0000-0000-0000000000a1","claims":{"sub":"00000000-0000-0000-0000-0000000000a1","session_id":"00000000-0000-0000-0000-0000000005a1"}}'
  ) -> 'claims' -> 'tenant_id' #>> '{}',
  '00000000-0000-0000-0000-00000000000a',
  'hook adds tenant_id for the picked tenant'
);
select results_eq(
  $$select
      private.custom_access_token_hook('{"user_id":"00000000-0000-0000-0000-0000000000a1","claims":{"session_id":"00000000-0000-0000-0000-0000000005a1"}}') -> 'claims' ->> 'permission_version',
      private.custom_access_token_hook('{"user_id":"00000000-0000-0000-0000-0000000000a2","claims":{"session_id":"00000000-0000-0000-0000-0000000005a2","tenant_id":"forged"}}') -> 'claims' ? 'tenant_id'$$,
  $$values ('1', false)$$,
  'hook adds permission_version, and strips tenant_id when no tenant is picked'
);

-- Removed member: picked session stays, but the hook adds nothing.
update public.tenant_membership set status = 'disabled'
where tenant_id = '00000000-0000-0000-0000-00000000000a' and user_id = '00000000-0000-0000-0000-0000000000a1';
select ok(
  not (private.custom_access_token_hook('{"user_id":"00000000-0000-0000-0000-0000000000a1","claims":{"session_id":"00000000-0000-0000-0000-0000000005a1"}}') -> 'claims' ? 'tenant_id'),
  'hook omits tenant_id for a disabled membership'
);

select * from finish();
rollback;
