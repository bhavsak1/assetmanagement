-- Story 9.2: integration users and API keys (docs/data-model-goal9.md §17).
-- Uses the seed: tenant A (...0a, active) with admin.a ...a0001 (Administrator: users_security and api_keys
-- manage) and auditor.a ...a0005 (both view), test.user a1 with no groups; tenant B (...0b, read_only) with
-- admin.b ...b0001.
begin;
select plan(52);

create function pg_temp.err(p_sql text) returns text language plpgsql as $$
begin
  execute p_sql;
  return 'ok';
exception when others then
  return sqlstate;
end;
$$;
-- Runs a statement and the deferred checks now, as a commit would.
create function pg_temp.at_commit(p_sql text) returns void language plpgsql as $$
begin
  execute p_sql;
  set constraints all immediate;
  set constraints all deferred;
end;
$$;

-- Fixtures, as postgres. One asset in tenant A; tenant B gets an integration user and a key directly
-- (B is read_only, so its admin cannot create them).
insert into public.location (id, tenant_id, parent_id, name) values
  ('00000000-0000-0000-0000-0000000092e1', '00000000-0000-0000-0000-00000000000a', null, 'S92 Pune');
insert into public.asset_category (id, tenant_id, parent_id, name) values
  ('00000000-0000-0000-0000-0000000092c1', '00000000-0000-0000-0000-00000000000a', null, 'S92 Pumps');
insert into public.asset (id, tenant_id, tag, name, category_id, location_id) values
  ('00000000-0000-0000-0000-0000000092a1', '00000000-0000-0000-0000-00000000000a', 'S92-P1', 'Pump',
   '00000000-0000-0000-0000-0000000092c1', '00000000-0000-0000-0000-0000000092e1');

insert into auth.users (instance_id, id, aud, role, email, raw_app_meta_data, raw_user_meta_data, created_at, updated_at)
values ('00000000-0000-0000-0000-000000000000', '00000000-0000-0000-0000-0000000092b9', 'authenticated',
        'authenticated', 'b92@integration.invalid', '{}', '{}', now(), now());
insert into public.user_profile (id, display_name, email, kind)
values ('00000000-0000-0000-0000-0000000092b9', 'B integration', 'b92@integration.invalid', 'integration');
insert into public.tenant_membership (tenant_id, user_id)
values ('00000000-0000-0000-0000-00000000000b', '00000000-0000-0000-0000-0000000092b9');
insert into private.api_key (id, tenant_id, user_id, name, prefix, secret_hash, expires_at)
values ('00000000-0000-0000-0000-0000000092f9', '00000000-0000-0000-0000-00000000000b',
        '00000000-0000-0000-0000-0000000092b9', 'B key', 'bbbbbbbbbbbb',
        extensions.digest(repeat('b', 43), 'sha256'), now() + interval '1 day');

-- 1. Grants: only assetly_api can turn a key into an identity; nobody reads the key tables.
select ok(has_function_privilege('assetly_api', 'private.api_key_identity(text)', 'execute'), 'assetly_api can call api_key_identity');
select ok(not has_function_privilege('authenticated', 'private.api_key_identity(text)', 'execute'), 'authenticated cannot call api_key_identity');
select ok(not has_function_privilege('anon', 'private.api_key_identity(text)', 'execute'), 'anon cannot call api_key_identity');
select ok(not has_table_privilege('authenticated', 'private.api_key', 'select'), 'authenticated cannot read private.api_key');
select ok(not has_table_privilege('assetly_api', 'private.api_key', 'select'), 'assetly_api cannot read private.api_key');

-- 2. No grant: a1 can do nothing.
select tests.act_as('00000000-0000-0000-0000-0000000000a1', '00000000-0000-0000-0000-00000000000a');
select is(pg_temp.err($$select public.create_integration_user('X')$$), '42501', 'no grant: cannot create an integration user');
select is((select count(*)::int from public.api_keys()), 0, 'no grant: api_keys() is empty');
reset role;

-- 3. View only (auditor): lists, cannot create.
select tests.act_as('00000000-0000-0000-0000-0000000a0005', '00000000-0000-0000-0000-00000000000a');
select is(pg_temp.err($$select public.create_integration_user('X')$$), '42501', 'auditor: cannot create an integration user');
select is(pg_temp.err($$select public.create_api_key('00000000-0000-0000-0000-0000000092b9', 'x', now() + interval '1 day')$$),
          '42501', 'auditor: cannot create a key');
reset role;

-- 4. Admin A creates an integration user.
select tests.act_as('00000000-0000-0000-0000-0000000a0001', '00000000-0000-0000-0000-00000000000a');
select set_config('t.user', public.create_integration_user('  ERP sync  ')::text, false);
reset role;
select is((select kind || ':' || display_name from public.user_profile where id = current_setting('t.user')::uuid),
          'integration:ERP sync', 'the profile is an integration user, name trimmed');
select ok((select encrypted_password is null and banned_until > now() + interval '100 years'
           and email like '%@integration.invalid' from auth.users where id = current_setting('t.user')::uuid),
          'the auth user has no password, is banned and has a placeholder email');
select ok(not exists (select 1 from auth.identities where user_id = current_setting('t.user')::uuid),
          'the auth user has no identity, so it cannot sign in');
select is((select status || ':' || email_digest from public.tenant_membership
           where tenant_id = '00000000-0000-0000-0000-00000000000a' and user_id = current_setting('t.user')::uuid),
          'active:false', 'membership active, daily email off');
select is((select actor_user_id::text || ':' || category from public.audit_log
           where table_name = 'integration_user' and record_id = current_setting('t.user')::uuid and action = 'insert'),
          '00000000-0000-0000-0000-0000000a0001:security', 'creating it writes a security audit row by the admin');

select tests.act_as('00000000-0000-0000-0000-0000000a0001', '00000000-0000-0000-0000-00000000000a');
select is((select kind from public.security_members() where user_id = current_setting('t.user')::uuid),
          'integration', 'security_members tags it');
select is(pg_temp.err($$select public.create_integration_user('   ')$$), '22023', 'a blank name is refused');

-- 5. Keys: format, hash only, expiry bounds, people refused.
select set_config('t.ka_id', id::text, false), set_config('t.ka', key, false)
from public.create_api_key(current_setting('t.user')::uuid, 'Main', now() + interval '1 year');
select ok(current_setting('t.ka') ~ '^asly_[A-Za-z0-9_-]{12}_[A-Za-z0-9_-]{43}$', 'the key has the asly_ format');
select is(pg_temp.err($$select public.create_api_key(current_setting('t.user')::uuid, 'x', now() + interval '3 years')$$),
          '22023', 'expiry over 2 years is refused');
select is(pg_temp.err($$select public.create_api_key(current_setting('t.user')::uuid, 'x', now() - interval '1 day')$$),
          '22023', 'a past expiry is refused');
select is(pg_temp.err($$select public.create_api_key('00000000-0000-0000-0000-0000000a0002', 'x', now() + interval '1 day')$$),
          'P0002', 'a key for a person is refused');
select is((select count(*)::int from public.api_keys()), 1, 'admin A lists its one key');
select is((select prefix from public.api_keys()), substr(current_setting('t.ka'), 6, 12), 'the list shows the prefix');
reset role;
select ok((select secret_hash = extensions.digest(substr(current_setting('t.ka'), 19), 'sha256')
             and position(substr(current_setting('t.ka'), 19) in encode(secret_hash, 'escape')) = 0
           from private.api_key where id = current_setting('t.ka_id')::uuid),
          'only the hash is stored');
select ok(not exists (select 1 from public.audit_log where new_data::text like '%' || substr(current_setting('t.ka'), 19) || '%'),
          'the secret is in no audit row');

-- 6. Key to identity.
select is((select user_id::text || ':' || tenant_id || ':' || calls from private.api_key_identity(current_setting('t.ka'))),
          current_setting('t.user')::uuid || ':00000000-0000-0000-0000-00000000000a:1', 'a live key gives its user and tenant');
select is((select calls from private.api_key_identity(current_setting('t.ka'))), 2, 'the minute counter goes up');
select ok((select last_used_at is not null from private.api_key where id = current_setting('t.ka_id')::uuid), 'last_used_at is set');
select is((select count(*)::int from private.api_key_identity(left(current_setting('t.ka'), 60) || case when right(current_setting('t.ka'), 1) = 'A' then 'B' else 'A' end)), 0, 'a wrong secret gives nothing');
select is((select count(*)::int from private.api_key_identity('not a key')), 0, 'garbage gives nothing');
select is((select count(*)::int from private.api_key_identity(null)), 0, 'null gives nothing');

-- 7. Expired.
update private.api_key set expires_at = now() - interval '1 second' where id = current_setting('t.ka_id')::uuid;
select is((select count(*)::int from private.api_key_identity(current_setting('t.ka'))), 0, 'an expired key gives nothing');
update private.api_key set expires_at = now() + interval '1 year' where id = current_setting('t.ka_id')::uuid;

-- 8. Disabled integration user.
select tests.act_as('00000000-0000-0000-0000-0000000a0001', '00000000-0000-0000-0000-00000000000a');
select public.set_integration_user_status(current_setting('t.user')::uuid, 'disabled');
reset role;
select is((select count(*)::int from private.api_key_identity(current_setting('t.ka'))), 0, 'a disabled integration user''s key gives nothing');
select tests.act_as('00000000-0000-0000-0000-0000000a0001', '00000000-0000-0000-0000-00000000000a');
select public.set_integration_user_status(current_setting('t.user')::uuid, 'active');
select is(pg_temp.err($$select public.set_integration_user_status('00000000-0000-0000-0000-0000000a0002', 'disabled')$$),
          'P0002', 'set_integration_user_status refuses a person');
reset role;
select is((select count(*)::int from private.api_key_identity(current_setting('t.ka'))), 1, 're-enabled: the key works again');

-- 9. The engine: the integration user sees what its groups allow, in its own tenant only.
select tests.act_as(current_setting('t.user')::uuid, '00000000-0000-0000-0000-00000000000a');
select is((select count(*)::int from public.asset_view where id = '00000000-0000-0000-0000-0000000092a1'), 0, 'no group: it sees no asset');
reset role;
select tests.grant('00000000-0000-0000-0000-00000000000a', current_setting('t.user')::uuid, 'asset_core', '{view,update}');
select tests.act_as(current_setting('t.user')::uuid, '00000000-0000-0000-0000-00000000000a');
select is((select count(*)::int from public.asset_view where id = '00000000-0000-0000-0000-0000000092a1'), 1, 'with asset_core.view it sees the asset');
reset role;
select tests.act_as(current_setting('t.user')::uuid, '00000000-0000-0000-0000-00000000000b');
select is((select count(*)::int from public.asset_view), 0, 'claims naming tenant B: it sees nothing');
reset role;

-- 10. A7: a change made with a key records the key.
select set_config('request.jwt.claims', json_build_object('sub', current_setting('t.user')::uuid, 'role', 'authenticated',
                  'tenant_id', '00000000-0000-0000-0000-00000000000a', 'api_key_id', current_setting('t.ka_id')::uuid)::text, true);
select set_config('role', 'authenticated', true);
update public.asset set model = 'API model' where id = '00000000-0000-0000-0000-0000000092a1';
reset role;
select is((select api_key_id from public.audit_log where record_id = '00000000-0000-0000-0000-0000000092a1' and action = 'update'
           order by occurred_at desc limit 1), current_setting('t.ka_id')::uuid, 'the audit row carries api_key_id');

-- 11. Revoke.
select tests.act_as('00000000-0000-0000-0000-0000000a0001', '00000000-0000-0000-0000-00000000000a');
select is(public.revoke_api_key(current_setting('t.ka_id')::uuid), current_setting('t.ka_id')::uuid, 'admin revokes the key');
select is(pg_temp.err($$select public.revoke_api_key(current_setting('t.ka_id')::uuid)$$), 'P0002', 'revoking twice is an error');
reset role;
select is((select count(*)::int from private.api_key_identity(current_setting('t.ka'))), 0, 'a revoked key gives nothing');
select is((select count(*)::int from public.audit_log where table_name = 'api_key' and record_id = current_setting('t.ka_id')::uuid
           and action in ('insert', 'revoke') and category = 'security'), 2, 'create and revoke are audited');

-- 12. Cross-tenant: admin A cannot see, use or revoke tenant B's key or user; admin B sees only B.
select tests.act_as('00000000-0000-0000-0000-0000000a0001', '00000000-0000-0000-0000-00000000000a');
select ok(not exists (select 1 from public.api_keys() where id = '00000000-0000-0000-0000-0000000092f9'::uuid), 'admin A does not list B''s key');
select is(pg_temp.err($$select public.revoke_api_key('00000000-0000-0000-0000-0000000092f9')$$), 'P0002', 'admin A cannot revoke B''s key');
select is(pg_temp.err($$select public.create_api_key('00000000-0000-0000-0000-0000000092b9', 'x', now() + interval '1 day')$$),
          'P0002', 'admin A cannot make a key for B''s integration user');
select is(pg_temp.err($$select public.set_integration_user_status('00000000-0000-0000-0000-0000000092b9', 'disabled')$$),
          'P0002', 'admin A cannot disable B''s integration user');
reset role;
select tests.act_as('00000000-0000-0000-0000-0000000b0001', '00000000-0000-0000-0000-00000000000b');
select is((select array_agg(id)::text from public.api_keys()), '{00000000-0000-0000-0000-0000000092f9}', 'admin B lists only B''s key');
-- 13. Read-only tenant: no new identities; its keys still read.
select is(pg_temp.err($$select public.create_integration_user('X')$$), '42501', 'read-only tenant: cannot create an integration user');
reset role;
select is((select tenant_id from private.api_key_identity('asly_bbbbbbbbbbbb_' || repeat('b', 43))),
          '00000000-0000-0000-0000-00000000000b'::uuid, 'read-only tenant: its key still resolves (reads only, RLS stops writes)');
update public.tenant set status = 'suspended' where id = '00000000-0000-0000-0000-00000000000b';
select is((select count(*)::int from private.api_key_identity('asly_bbbbbbbbbbbb_' || repeat('b', 43))), 0, 'suspended tenant: the key gives nothing');

-- 14. A12: an integration user never counts as the last security admin, and gets no alerts.
select tests.grant('00000000-0000-0000-0000-00000000000a', current_setting('t.user')::uuid, 'users_security', '{view,manage}');
select tests.act_as('00000000-0000-0000-0000-0000000a0001', '00000000-0000-0000-0000-00000000000a');
select throws_ok(
  $$select pg_temp.at_commit('update public.user_group_assignment set deleted_at = now()
      where user_id = ''00000000-0000-0000-0000-0000000a0001'' and deleted_at is null')$$,
  '42501', 'last security admin', 'an integration user with manage does not keep the last admin');
reset role;

select tests.grant('00000000-0000-0000-0000-00000000000a', current_setting('t.user')::uuid, 'obligation', '{view,update}');
insert into private.outbox_event (tenant_id, event_type, aggregate_type, aggregate_id, payload)
values ('00000000-0000-0000-0000-00000000000a', 'obligation.overdue', 'obligation', gen_random_uuid(),
        jsonb_build_object('asset_id', '00000000-0000-0000-0000-0000000092a1'));
select private.fan_out_events();
select is((select count(*)::int from public.notification where user_id = current_setting('t.user')::uuid), 0,
          'fan-out skips the integration user');

select * from finish();
rollback;
