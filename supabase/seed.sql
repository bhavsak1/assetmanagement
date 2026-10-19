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
