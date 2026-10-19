-- Story 1.1: tenant, user_profile, tenant_membership, tenant_entitlement, tenant_session,
-- select_tenant() and the custom access token hook. Shapes from docs/data-model-goal1.md §2 and §4.
-- Policies here cover only what a signed-in user needs before has_permission() exists (1.3).
-- Audit triggers come in 1.5.

-- Std column: updated_at set on every update.
create function private.set_updated_at()
returns trigger language plpgsql set search_path = '' as $$
begin
  new.updated_at := now();
  return new;
end;
$$;
revoke all on function private.set_updated_at() from public, anon, authenticated;

-- user_profile first: every std column references it.
create table public.user_profile (
  id           uuid primary key references auth.users (id) on delete restrict,
  display_name text not null,
  email        text not null,
  created_at   timestamptz not null default now(),
  updated_at   timestamptz not null default now(),
  created_by   uuid null references public.user_profile (id),
  updated_by   uuid null references public.user_profile (id),
  deleted_at   timestamptz null
);

create table public.tenant (
  id            uuid primary key default gen_random_uuid(),
  name          text not null,
  slug          text not null unique check (slug ~ '^[a-z0-9-]+$'),
  status        text not null default 'active' check (status in ('active', 'read_only', 'suspended')),
  currency_code char(3) not null,
  locale        text not null default 'en-IN',
  time_zone     text not null,
  date_format   text not null,
  created_at    timestamptz not null default now(),
  updated_at    timestamptz not null default now(),
  created_by    uuid null references public.user_profile (id),
  updated_by    uuid null references public.user_profile (id),
  deleted_at    timestamptz null
);

create table public.tenant_membership (
  id                 uuid primary key default gen_random_uuid(),
  tenant_id          uuid not null references public.tenant (id),
  user_id            uuid not null references public.user_profile (id),
  status             text not null default 'active' check (status in ('active', 'disabled')),
  permission_version integer not null default 1,
  created_at         timestamptz not null default now(),
  updated_at         timestamptz not null default now(),
  created_by         uuid null references public.user_profile (id),
  updated_by         uuid null references public.user_profile (id),
  deleted_at         timestamptz null,
  -- Not partial: composite FK target for user_group_assignment and tenant_session [D5].
  unique (tenant_id, user_id),
  unique (tenant_id, id)
);
-- JWT hook and "my memberships" path.
create index tenant_membership_user_active_idx on public.tenant_membership (user_id)
  where status = 'active' and deleted_at is null;

create table public.tenant_entitlement (
  id           uuid primary key default gen_random_uuid(),
  tenant_id    uuid not null references public.tenant (id),
  feature_code text not null,
  limit_value  integer null,
  valid_from   timestamptz not null default now(),
  valid_to     timestamptz null,
  created_at   timestamptz not null default now(),
  updated_at   timestamptz not null default now(),
  created_by   uuid null references public.user_profile (id),
  updated_by   uuid null references public.user_profile (id),
  deleted_at   timestamptz null,
  check (valid_to is null or valid_to > valid_from),
  unique (tenant_id, id)
);
create unique index tenant_entitlement_feature_uq on public.tenant_entitlement (tenant_id, feature_code, valid_from)
  where deleted_at is null;

-- The tenant picked for one login session [D3]. Lives and dies with the auth session.
create table private.tenant_session (
  session_id  uuid primary key references auth.sessions (id) on delete cascade,
  user_id     uuid not null,
  tenant_id   uuid not null,
  selected_at timestamptz not null default now(),
  foreign key (tenant_id, user_id) references public.tenant_membership (tenant_id, user_id)
);

create trigger set_updated_at before update on public.user_profile
  for each row execute function private.set_updated_at();
create trigger set_updated_at before update on public.tenant
  for each row execute function private.set_updated_at();
create trigger set_updated_at before update on public.tenant_membership
  for each row execute function private.set_updated_at();
create trigger set_updated_at before update on public.tenant_entitlement
  for each row execute function private.set_updated_at();

-- RLS on everywhere. No policy means no access.
alter table public.user_profile       enable row level security;
alter table public.tenant             enable row level security;
alter table public.tenant_membership  enable row level security;
alter table public.tenant_entitlement enable row level security;
alter table private.tenant_session    enable row level security;

-- user_profile: own row only. Reading co-members' profiles needs a security definer helper (1.3+).
create policy user_profile_select_own on public.user_profile
  for select to authenticated
  using (id = (select auth.uid()));
create policy user_profile_update_own on public.user_profile
  for update to authenticated
  using (id = (select auth.uid()))
  with check (id = (select auth.uid()));
-- RLS cannot hide columns: a user may change only their display name.
revoke insert, update, delete on public.user_profile from anon, authenticated;
grant update (display_name) on public.user_profile to authenticated;

-- tenant_membership: own rows in any tenant (for the picker). Admin read/write comes with 1.3 helpers.
create policy tenant_membership_select_own on public.tenant_membership
  for select to authenticated
  using (user_id = (select auth.uid()));

-- tenant: names of tenants the user is an active member of. Update comes in 2.5.
create policy tenant_select_member on public.tenant
  for select to authenticated
  using (exists (
    select 1 from public.tenant_membership m
    where m.tenant_id = tenant.id
      and m.user_id = (select auth.uid())
      and m.status = 'active' and m.deleted_at is null
  ));

-- tenant_entitlement: read in the current tenant (token claim plus a live active membership).
-- shortcut: inlines the claim read, swap for private.current_tenant_id() once 1.3 grants private to authenticated.
create policy tenant_entitlement_select_current on public.tenant_entitlement
  for select to authenticated
  using (
    tenant_id = nullif((select auth.jwt() ->> 'tenant_id'), '')::uuid
    and exists (
      select 1 from public.tenant_membership m
      where m.tenant_id = tenant_entitlement.tenant_id
        and m.user_id = (select auth.uid())
        and m.status = 'active' and m.deleted_at is null
    )
  );

-- Action: pick the tenant for this login session [D3]. The app then refreshes the session.
create function public.select_tenant(p_tenant_id uuid)
returns void language plpgsql security definer set search_path = '' as $$
declare
  v_user_id    uuid := auth.uid();
  v_session_id uuid := nullif(auth.jwt() ->> 'session_id', '')::uuid;
begin
  if v_user_id is null or v_session_id is null then
    raise exception 'not signed in' using errcode = '42501';
  end if;

  if not exists (
    select 1
    from public.tenant_membership m
    join public.tenant t on t.id = m.tenant_id
    where m.tenant_id = p_tenant_id and m.user_id = v_user_id
      and m.status = 'active' and m.deleted_at is null
      and t.status <> 'suspended' and t.deleted_at is null
  ) then
    raise exception 'no access to tenant' using errcode = '42501';
  end if;

  insert into private.tenant_session (session_id, user_id, tenant_id)
  values (v_session_id, v_user_id, p_tenant_id)
  on conflict (session_id) do update
    set tenant_id = excluded.tenant_id, user_id = excluded.user_id, selected_at = now();
end;
$$;
revoke all on function public.select_tenant(uuid) from public, anon;
grant execute on function public.select_tenant(uuid) to authenticated;

-- Custom access token hook (§4). Adds tenant_id and permission_version only, and only for an
-- active membership in a non-suspended tenant picked for this session. Never picks a default.
create function private.custom_access_token_hook(event jsonb)
returns jsonb language plpgsql stable security definer set search_path = '' as $$
declare
  v_claims jsonb := coalesce(event -> 'claims', '{}'::jsonb) - 'tenant_id' - 'permission_version';
  v_tenant_id uuid;
  v_version   integer;
begin
  select m.tenant_id, m.permission_version
    into v_tenant_id, v_version
  from private.tenant_session s
  join public.tenant_membership m on m.tenant_id = s.tenant_id and m.user_id = s.user_id
  join public.tenant t on t.id = m.tenant_id
  where s.session_id = nullif(v_claims ->> 'session_id', '')::uuid
    and s.user_id = (event ->> 'user_id')::uuid
    and m.status = 'active' and m.deleted_at is null
    and t.status <> 'suspended' and t.deleted_at is null;

  if v_tenant_id is not null then
    v_claims := v_claims || jsonb_build_object('tenant_id', v_tenant_id, 'permission_version', v_version);
  end if;

  return jsonb_set(event, '{claims}', v_claims);
end;
$$;
grant usage on schema private to supabase_auth_admin;
revoke all on function private.custom_access_token_hook(jsonb) from public, anon, authenticated;
grant execute on function private.custom_access_token_hook(jsonb) to supabase_auth_admin;
