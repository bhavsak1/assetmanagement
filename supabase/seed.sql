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

insert into public.tenant (id, name, slug, status, currency_code, locale, time_zone, date_format) values
  ('00000000-0000-0000-0000-00000000000a', 'TEST Tenant A', 'test-tenant-a', 'active', 'INR', 'en-IN', 'Asia/Kolkata', 'dd-MM-yyyy'),
  ('00000000-0000-0000-0000-00000000000b', 'TEST Tenant B', 'test-tenant-b', 'read_only', 'USD', 'en-US', 'America/New_York', 'MM/dd/yyyy');

-- test.user is in both tenants (sees the picker). test.user2 is in tenant B only.
insert into public.tenant_membership (tenant_id, user_id) values
  ('00000000-0000-0000-0000-00000000000a', '00000000-0000-0000-0000-0000000000a1'),
  ('00000000-0000-0000-0000-00000000000b', '00000000-0000-0000-0000-0000000000a1'),
  ('00000000-0000-0000-0000-00000000000b', '00000000-0000-0000-0000-0000000000a2');

insert into public.tenant_entitlement (tenant_id, feature_code, limit_value) values
  ('00000000-0000-0000-0000-00000000000a', 'asset_limit', 500),
  ('00000000-0000-0000-0000-00000000000a', 'ai_addon', null),
  ('00000000-0000-0000-0000-00000000000b', 'asset_limit', 100);
