-- Story 9.2: API keys (docs/data-model-goal9.md §17 A3 to A7). Owner accepted the leans, 5 Nov 2026.
-- OWNER REVIEW (CLAUDE.md §9): API keys. Every function here, the grant to assetly_api, the tables.
-- Key: asly_<12-char prefix>_<43-char secret>, both base64url. Only sha256(secret) is stored. The full key is
-- returned once, by create_api_key. The service turns a key into claims with api_key_identity (A5).

-- In private: no grant to authenticated. Read through public.api_keys(), which never returns the hash.
create table private.api_key (
  id           uuid primary key default gen_random_uuid(),
  tenant_id    uuid not null references public.tenant (id),
  user_id      uuid not null,                 -- the integration user
  name         text not null check (btrim(name) <> '' and length(name) <= 100),
  prefix       text not null unique check (prefix ~ '^[A-Za-z0-9_-]{12}$'),
  secret_hash  bytea not null,
  expires_at   timestamptz not null,
  revoked_at   timestamptz null,
  revoked_by   uuid null references public.user_profile (id),
  last_used_at timestamptz null,
  created_at   timestamptz not null default now(),
  created_by   uuid null references public.user_profile (id),
  unique (tenant_id, id),
  foreign key (tenant_id, user_id) references public.tenant_membership (tenant_id, user_id)
);
create index api_key_user_idx on private.api_key (tenant_id, user_id);
alter table private.api_key enable row level security;

-- A6: one row per key per minute. The rate limit and the usage log. Purged after 90 days.
create table private.api_key_usage (
  key_id    uuid not null references private.api_key (id),
  tenant_id uuid not null references public.tenant (id),
  minute    timestamptz not null,
  calls     integer not null default 1,
  primary key (key_id, minute)
);
create index api_key_usage_minute_idx on private.api_key_usage (minute);
alter table private.api_key_usage enable row level security;

revoke all on private.api_key, private.api_key_usage from public, anon, authenticated;

-- base64url, no padding.
create function private.random_token(p_bytes integer)
returns text language sql volatile set search_path = '' as $$
  select rtrim(translate(encode(extensions.gen_random_bytes(p_bytes), 'base64'), '+/', '-_'), '=');
$$;
revoke all on function private.random_token(integer) from public, anon, authenticated;

-- A3, A4: api_keys.manage. The integration user must be active in this tenant. Expiry required, at most
-- 2 years out. At most 5 live keys per integration user. Returns the full key once.
create function public.create_api_key(p_user_id uuid, p_name text, p_expires_at timestamptz)
returns table (id uuid, key text)
language plpgsql volatile security definer set search_path = '' as $$
declare
  v_tenant uuid := private.current_tenant_id();
  v_id     uuid := gen_random_uuid();
  v_prefix text := private.random_token(9);   -- 12 characters
  v_secret text := private.random_token(32);  -- 43 characters
  v_name   text := btrim(p_name);
begin
  if not (private.has_permission('api_keys', 'manage') and private.tenant_can_write()) then
    raise exception 'not allowed' using errcode = '42501';
  end if;
  if not exists (select 1 from public.tenant_membership m join public.user_profile p on p.id = m.user_id
                 where m.tenant_id = v_tenant and m.user_id = p_user_id and m.status = 'active'
                   and m.deleted_at is null and p.kind = 'integration') then
    raise exception 'integration user not found' using errcode = 'P0002';
  end if;
  if v_name is null or v_name = '' or length(v_name) > 100 then
    raise exception 'name is required, up to 100 characters' using errcode = '22023';
  end if;
  if p_expires_at is null or p_expires_at <= now() or p_expires_at > now() + interval '2 years 1 day' then
    raise exception 'expiry must be in the future and at most 2 years away' using errcode = '22023';
  end if;
  if (select count(*) from private.api_key k
      where k.tenant_id = v_tenant and k.user_id = p_user_id and k.revoked_at is null and k.expires_at > now()) >= 5 then
    raise exception 'at most 5 active keys per integration user' using errcode = '23514';
  end if;

  insert into private.api_key (id, tenant_id, user_id, name, prefix, secret_hash, expires_at, created_by)
  values (v_id, v_tenant, p_user_id, v_name, v_prefix, extensions.digest(v_secret, 'sha256'), p_expires_at,
          (select auth.uid()));
  perform private.audit_security(v_tenant, 'api_key', v_id, 'insert',
    jsonb_build_object('user_id', p_user_id, 'name', v_name, 'prefix', v_prefix, 'expires_at', p_expires_at));
  return query select v_id, 'asly_' || v_prefix || '_' || v_secret;
end;
$$;
revoke all on function public.create_api_key(uuid, text, timestamptz) from public, anon;
grant execute on function public.create_api_key(uuid, text, timestamptz) to authenticated;

-- A4: takes effect at the next request. Revoking twice is an error, so the screen shows the real state.
create function public.revoke_api_key(p_key_id uuid)
returns uuid language plpgsql volatile security definer set search_path = '' as $$
declare
  v_tenant uuid := private.current_tenant_id();
begin
  if not (private.has_permission('api_keys', 'manage') and private.tenant_can_write()) then
    raise exception 'not allowed' using errcode = '42501';
  end if;
  update private.api_key set revoked_at = now(), revoked_by = (select auth.uid())
  where id = p_key_id and tenant_id = v_tenant and revoked_at is null;
  if not found then
    raise exception 'api key not found' using errcode = 'P0002';
  end if;
  perform private.audit_security(v_tenant, 'api_key', p_key_id, 'revoke', '{}'::jsonb);
  return p_key_id;
end;
$$;
revoke all on function public.revoke_api_key(uuid) from public, anon;
grant execute on function public.revoke_api_key(uuid) to authenticated;

-- The keys screen (A13). Never the hash.
create function public.api_keys()
returns table (id uuid, user_id uuid, name text, prefix text, expires_at timestamptz, revoked_at timestamptz,
               last_used_at timestamptz, created_at timestamptz)
language sql stable security definer set search_path = '' as $$
  select k.id, k.user_id, k.name, k.prefix, k.expires_at, k.revoked_at, k.last_used_at, k.created_at
  from private.api_key k
  where k.tenant_id = private.current_tenant_id() and private.has_permission('api_keys', 'view')
  order by k.created_at desc;
$$;
revoke all on function public.api_keys() from public, anon;
grant execute on function public.api_keys() to authenticated;

-- A5: key to identity. Called by the service as assetly_api, before it switches role, so no claims are set.
-- A row only when the hash matches, the key is live, the integration user and its membership are active and
-- the tenant is not suspended (read_only still reads; RLS blocks its writes). Also counts the call (A6).
create function private.api_key_identity(p_key text)
returns table (user_id uuid, tenant_id uuid, key_id uuid, calls integer)
language plpgsql volatile security definer set search_path = '' as $$
declare
  v_key   private.api_key;
  v_calls integer;
begin
  if p_key is null or p_key !~ '^asly_[A-Za-z0-9_-]{12}_[A-Za-z0-9_-]{43}$' then
    return;
  end if;
  select k.* into v_key
  from private.api_key k
  join public.tenant_membership m on m.tenant_id = k.tenant_id and m.user_id = k.user_id
                                 and m.status = 'active' and m.deleted_at is null
  join public.user_profile p on p.id = k.user_id and p.kind = 'integration' and p.deleted_at is null
  join public.tenant t on t.id = k.tenant_id and t.status <> 'suspended' and t.deleted_at is null
  where k.prefix = substr(p_key, 6, 12)
    and k.secret_hash = extensions.digest(substr(p_key, 19), 'sha256')
    and k.revoked_at is null and k.expires_at > now();
  if v_key.id is null then
    return;
  end if;

  insert into private.api_key_usage as u (key_id, tenant_id, minute)
  values (v_key.id, v_key.tenant_id, date_trunc('minute', now()))
  on conflict on constraint api_key_usage_pkey do update set calls = u.calls + 1
  returning u.calls into v_calls;
  -- At most one write a minute per key (A4).
  update private.api_key set last_used_at = now()
  where id = v_key.id and (last_used_at is null or last_used_at < now() - interval '1 minute');

  return query select v_key.user_id, v_key.tenant_id, v_key.id, v_calls;
end;
$$;
revoke all on function private.api_key_identity(text) from public, anon, authenticated;
grant usage on schema private to assetly_api;
grant execute on function private.api_key_identity(text) to assetly_api;

-- A10: /v1/assets pages by (updated_at, id) on the 3.1 index asset_updated_idx (scanned backward).

-- A6: usage rows older than 90 days.
select cron.schedule('assetly_purge_api_key_usage', '41 3 * * *',
                     $$delete from private.api_key_usage where minute < now() - interval '90 days'$$);
