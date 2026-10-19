-- Story 1.2: security_domain, domain_operation (platform catalog), security_group,
-- group_domain_policy, user_group_assignment. Shapes from docs/data-model-goal1.md §2.5 to §2.9.
-- scope_profile and its rules are 6.1 [D7]; user_group_assignment.scope_profile_id comes then.
-- Tenant tables have RLS on and no policies (closed) until has_permission() exists (1.3).
-- Audit and permission_version bump triggers come in 1.5 and 1.3.

-- Platform catalog: no tenant_id, written only by migrations.
create table public.security_domain (
  id          uuid primary key default gen_random_uuid(),
  code        text not null unique check (code ~ '^[a-z][a-z0-9_]*$'),
  entity      text not null,
  kind        text not null check (kind in ('entity', 'field', 'action', 'platform')),
  description text not null,
  is_system   boolean not null default true,
  created_at  timestamptz not null default now(),
  updated_at  timestamptz not null default now()
);

create table public.domain_operation (
  id                 uuid primary key default gen_random_uuid(),
  security_domain_id uuid not null references public.security_domain (id),
  code               text not null check (code ~ '^[a-z][a-z0-9_]*$'),
  sort_order         smallint not null default 0,
  created_at         timestamptz not null default now(),
  updated_at         timestamptz not null default now(),
  unique (security_domain_id, code)
);

-- A role. Starter groups are seeded per tenant in 1.6.
create table public.security_group (
  id            uuid primary key default gen_random_uuid(),
  tenant_id     uuid not null references public.tenant (id),
  code          text not null check (code ~ '^[a-z][a-z0-9_]*$'),
  name          text not null,
  group_type    text not null default 'role' check (group_type in ('role', 'system')),
  template_code text null,
  description   text null,
  created_at    timestamptz not null default now(),
  updated_at    timestamptz not null default now(),
  created_by    uuid null references public.user_profile (id),
  updated_by    uuid null references public.user_profile (id),
  deleted_at    timestamptz null,
  unique (tenant_id, id)
);
create unique index security_group_code_uq on public.security_group (tenant_id, code)
  where deleted_at is null;

-- One row per granted operation [D6]. No status or version until 6.4 [D9].
create table public.group_domain_policy (
  id                  uuid primary key default gen_random_uuid(),
  tenant_id           uuid not null,
  security_group_id   uuid not null,
  domain_operation_id uuid not null references public.domain_operation (id),
  created_at          timestamptz not null default now(),
  updated_at          timestamptz not null default now(),
  created_by          uuid null references public.user_profile (id),
  updated_by          uuid null references public.user_profile (id),
  deleted_at          timestamptz null,
  unique (tenant_id, id),
  foreign key (tenant_id, security_group_id) references public.security_group (tenant_id, id)
);
create unique index group_domain_policy_op_uq on public.group_domain_policy (security_group_id, domain_operation_id)
  where deleted_at is null;
-- Rebuild path (1.3).
create index group_domain_policy_group_idx on public.group_domain_policy (tenant_id, security_group_id);

-- Gives a group to a member [D5]. No unique key: same group may be assigned twice (grants are additive).
create table public.user_group_assignment (
  id                uuid primary key default gen_random_uuid(),
  tenant_id         uuid not null,
  user_id           uuid not null references public.user_profile (id),
  security_group_id uuid not null,
  effective_from    timestamptz not null default now(),
  effective_to      timestamptz null,
  created_at        timestamptz not null default now(),
  updated_at        timestamptz not null default now(),
  created_by        uuid null references public.user_profile (id),
  updated_by        uuid null references public.user_profile (id),
  deleted_at        timestamptz null,
  check (effective_to is null or effective_to > effective_from),
  unique (tenant_id, id),
  -- Proves the user is a member of this tenant, with no trigger [D5].
  foreign key (tenant_id, user_id) references public.tenant_membership (tenant_id, user_id),
  foreign key (tenant_id, security_group_id) references public.security_group (tenant_id, id)
);
-- Rebuild paths (1.3).
create index user_group_assignment_user_idx on public.user_group_assignment (tenant_id, user_id);
create index user_group_assignment_group_idx on public.user_group_assignment (tenant_id, security_group_id);

create trigger set_updated_at before update on public.security_domain
  for each row execute function private.set_updated_at();
create trigger set_updated_at before update on public.domain_operation
  for each row execute function private.set_updated_at();
create trigger set_updated_at before update on public.security_group
  for each row execute function private.set_updated_at();
create trigger set_updated_at before update on public.group_domain_policy
  for each row execute function private.set_updated_at();
create trigger set_updated_at before update on public.user_group_assignment
  for each row execute function private.set_updated_at();

-- RLS on everywhere. No policy means no access.
alter table public.security_domain       enable row level security;
alter table public.domain_operation      enable row level security;
alter table public.security_group        enable row level security;
alter table public.group_domain_policy   enable row level security;
alter table public.user_group_assignment enable row level security;

-- Catalog: owner decision 19 Oct 2026, only security admins read it. No policy until 1.3 adds
-- users_security.view, so closed for now. No user writes, ever.
revoke insert, update, delete, truncate on public.security_domain, public.domain_operation from anon, authenticated;
