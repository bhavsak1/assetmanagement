-- Local seed. Runs on `supabase db reset` against the local stack only. Never run on staging.

-- LOCAL TEST USER (story 0.4). Test values, not a real account.
--   email:    test.user@example.com
--   password: assetly-local-test
-- Token columns are '' not null, because Supabase Auth cannot read null there.
insert into auth.users (
  instance_id, id, aud, role, email, encrypted_password, email_confirmed_at,
  raw_app_meta_data, raw_user_meta_data, created_at, updated_at,
  confirmation_token, recovery_token, email_change, email_change_token_new
) values (
  '00000000-0000-0000-0000-000000000000', '00000000-0000-0000-0000-0000000000a1',
  'authenticated', 'authenticated', 'test.user@example.com',
  extensions.crypt('assetly-local-test', extensions.gen_salt('bf')), now(),
  '{"provider":"email","providers":["email"]}', '{}', now(), now(),
  '', '', '', ''
);

insert into auth.identities (provider_id, user_id, identity_data, provider, created_at, updated_at)
values (
  '00000000-0000-0000-0000-0000000000a1', '00000000-0000-0000-0000-0000000000a1',
  '{"sub":"00000000-0000-0000-0000-0000000000a1","email":"test.user@example.com","email_verified":true}',
  'email', now(), now()
);

-- SECOND LOCAL TEST USER (story 1.1). Member of tenant B only. Test values.
--   email:    test.user2@example.com
--   password: assetly-local-test
insert into auth.users (
  instance_id, id, aud, role, email, encrypted_password, email_confirmed_at,
  raw_app_meta_data, raw_user_meta_data, created_at, updated_at,
  confirmation_token, recovery_token, email_change, email_change_token_new
) values (
  '00000000-0000-0000-0000-000000000000', '00000000-0000-0000-0000-0000000000a2',
  'authenticated', 'authenticated', 'test.user2@example.com',
  extensions.crypt('assetly-local-test', extensions.gen_salt('bf')), now(),
  '{"provider":"email","providers":["email"]}', '{}', now(), now(),
  '', '', '', ''
);

insert into auth.identities (provider_id, user_id, identity_data, provider, created_at, updated_at)
values (
  '00000000-0000-0000-0000-0000000000a2', '00000000-0000-0000-0000-0000000000a2',
  '{"sub":"00000000-0000-0000-0000-0000000000a2","email":"test.user2@example.com","email_verified":true}',
  'email', now(), now()
);

-- TEST TENANTS (story 1.1). Hand-seeded per OQ-30. Not real companies.
insert into public.user_profile (id, display_name, email) values
  ('00000000-0000-0000-0000-0000000000a1', 'Test User', 'test.user@example.com'),
  ('00000000-0000-0000-0000-0000000000a2', 'Test User Two', 'test.user2@example.com');

insert into public.tenant (id, name, slug, status, currency_code, locale, time_zone, date_format, fiscal_year_start_month) values
  ('00000000-0000-0000-0000-00000000000a', 'TEST Tenant A', 'test-tenant-a', 'active', 'INR', 'en-IN', 'Asia/Kolkata', 'dd-MM-yyyy', 4),
  ('00000000-0000-0000-0000-00000000000b', 'TEST Tenant B', 'test-tenant-b', 'read_only', 'USD', 'en-US', 'America/New_York', 'MM/dd/yyyy', 1);

-- test.user is in both tenants (sees the picker). test.user2 is in tenant B only.
insert into public.tenant_membership (tenant_id, user_id) values
  ('00000000-0000-0000-0000-00000000000a', '00000000-0000-0000-0000-0000000000a1'),
  ('00000000-0000-0000-0000-00000000000b', '00000000-0000-0000-0000-0000000000a1'),
  ('00000000-0000-0000-0000-00000000000b', '00000000-0000-0000-0000-0000000000a2');

insert into public.tenant_entitlement (tenant_id, feature_code, limit_value) values
  ('00000000-0000-0000-0000-00000000000a', 'asset_limit', 500),
  ('00000000-0000-0000-0000-00000000000a', 'ai_addon', null),
  ('00000000-0000-0000-0000-00000000000b', 'asset_limit', 100);

-- STARTER GROUPS AND ROLE TEST USERS (story 1.6). Test values, not real accounts.
-- Both test tenants get the starter groups, as provisioning will do. One user per starter group per tenant:
--   email:    <role>.<a|b>@example.com, role in admin, plant, planner, tech, auditor
--   password: assetly-local-test
--   id:       00000000-0000-0000-0000-0000000<a|b>000<1..5>, in the role order above
-- test.user and test.user2 keep no groups: the 1.3 and 1.4 tests start them from nothing.
select private.seed_starter_groups(id) from public.tenant where slug in ('test-tenant-a', 'test-tenant-b');

do $$
declare
  r record;
begin
  for r in
    select t.id as tenant_id, g.code,
           g.login || '.' || t.suffix || '@example.com' as email,
           ('00000000-0000-0000-0000-0000000' || t.suffix || '000' || g.n)::uuid as user_id
    from (values ('00000000-0000-0000-0000-00000000000a'::uuid, 'a'),
                 ('00000000-0000-0000-0000-00000000000b'::uuid, 'b')) t (id, suffix)
    cross join (values (1, 'tenant_admin', 'admin'), (2, 'plant_manager', 'plant'), (3, 'planner', 'planner'),
                       (4, 'technician', 'tech'), (5, 'auditor', 'auditor')) g (n, code, login)
  loop
    insert into auth.users (
      instance_id, id, aud, role, email, encrypted_password, email_confirmed_at,
      raw_app_meta_data, raw_user_meta_data, created_at, updated_at,
      confirmation_token, recovery_token, email_change, email_change_token_new
    ) values (
      '00000000-0000-0000-0000-000000000000', r.user_id, 'authenticated', 'authenticated', r.email,
      extensions.crypt('assetly-local-test', extensions.gen_salt('bf')), now(),
      '{"provider":"email","providers":["email"]}', '{}', now(), now(), '', '', '', ''
    );
    insert into auth.identities (provider_id, user_id, identity_data, provider, created_at, updated_at)
    values (r.user_id, r.user_id,
            json_build_object('sub', r.user_id, 'email', r.email, 'email_verified', true), 'email', now(), now());
    insert into public.user_profile (id, display_name, email) values (r.user_id, 'TEST ' || r.email, r.email);
    insert into public.tenant_membership (tenant_id, user_id) values (r.tenant_id, r.user_id);
    insert into public.user_group_assignment (tenant_id, user_id, security_group_id)
    select r.tenant_id, r.user_id, g.id from public.security_group g
    where g.tenant_id = r.tenant_id and g.template_code = 'starter.' || r.code;
  end loop;
end;
$$;
