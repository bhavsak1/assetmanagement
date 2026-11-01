-- Story 6.1: scope profiles and their rules, the link on the assignment, and scope in the derived table.
-- Design and owner decisions S1 to S9: docs/data-model-goal6.md (D7 A and X from data-model-goal1.md §2.10).
-- OWNER REVIEW (CLAUDE.md §9): RLS policies and the rebuild function.
-- Domain users_security (S8): no catalog change. Security audit like the other security tables (D8).

create table public.scope_profile (
  id         uuid primary key default gen_random_uuid(),
  tenant_id  uuid not null references public.tenant (id),
  name       text not null check (length(btrim(name)) between 1 and 80),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  created_by uuid null references public.user_profile (id),
  updated_by uuid null references public.user_profile (id),
  deleted_at timestamptz null,
  unique (tenant_id, id)
);
create unique index scope_profile_name_uq on public.scope_profile (tenant_id, lower(name)) where deleted_at is null;

-- One row per allowed value (D7 A). Same dimension: OR. Different dimensions: AND. S1: location and category only.
create table public.scope_profile_rule (
  id               uuid primary key default gen_random_uuid(),
  tenant_id        uuid not null references public.tenant (id),
  scope_profile_id uuid not null,
  dimension        text not null check (dimension in ('location', 'category')),
  location_id      uuid null,  -- and every descendant (closure)
  category_id      uuid null,  -- and every child category
  created_at       timestamptz not null default now(),
  updated_at       timestamptz not null default now(),
  created_by       uuid null references public.user_profile (id),
  updated_by       uuid null references public.user_profile (id),
  deleted_at       timestamptz null,
  unique (tenant_id, id),
  check ((dimension = 'location') = (location_id is not null) and (dimension = 'category') = (category_id is not null)),
  foreign key (tenant_id, scope_profile_id) references public.scope_profile (tenant_id, id),
  foreign key (tenant_id, location_id) references public.location (tenant_id, id),
  foreign key (tenant_id, category_id) references public.asset_category (tenant_id, id)
);
create index scope_profile_rule_profile_idx on public.scope_profile_rule (tenant_id, scope_profile_id) where deleted_at is null;
create unique index scope_profile_rule_location_uq on public.scope_profile_rule (tenant_id, scope_profile_id, location_id)
  where deleted_at is null and location_id is not null;
create unique index scope_profile_rule_category_uq on public.scope_profile_rule (tenant_id, scope_profile_id, category_id)
  where deleted_at is null and category_id is not null;

-- Null = tenant-wide (D7). The 1.3 row trigger already rebuilds the member on any assignment update.
alter table public.user_group_assignment add column scope_profile_id uuid null,
  add foreign key (tenant_id, scope_profile_id) references public.scope_profile (tenant_id, id);
alter table private.user_effective_permission add column scope_profile_id uuid null;

-- §2: a profile in use cannot be deleted; unassign it first.
create function private.check_scope_profile_in_use()
returns trigger language plpgsql security definer set search_path = '' as $$
begin
  if new.deleted_at is not null and old.deleted_at is null
     and exists (select 1 from public.user_group_assignment a
                 where a.tenant_id = new.tenant_id and a.scope_profile_id = new.id and a.deleted_at is null) then
    raise exception 'scope profile is assigned' using errcode = '23503';
  end if;
  return new;
end;
$$;
revoke all on function private.check_scope_profile_in_use() from public, anon, authenticated;

create trigger set_updated_at before update on public.scope_profile
  for each row execute function private.set_updated_at();
create trigger set_updated_at before update on public.scope_profile_rule
  for each row execute function private.set_updated_at();
create trigger check_in_use before update of deleted_at on public.scope_profile
  for each row execute function private.check_scope_profile_in_use();
create trigger audit after insert or update or delete on public.scope_profile
  for each row execute function private.audit_row('security');
create trigger audit after insert or update or delete on public.scope_profile_rule
  for each row execute function private.audit_row('security');

-- RLS as user_group_assignment (1.3): view with users_security.view, writes with manage. Soft delete only.
alter table public.scope_profile enable row level security;
alter table public.scope_profile_rule enable row level security;

create policy scope_profile_select on public.scope_profile
  for select to authenticated
  using (tenant_id = (select private.current_tenant_id())
         and (select private.has_permission('users_security', 'view')));
create policy scope_profile_insert on public.scope_profile
  for insert to authenticated
  with check (tenant_id = (select private.current_tenant_id())
              and (select private.has_permission('users_security', 'manage'))
              and (select private.tenant_can_write()));
create policy scope_profile_update on public.scope_profile
  for update to authenticated
  using (tenant_id = (select private.current_tenant_id())
         and (select private.has_permission('users_security', 'manage'))
         and (select private.tenant_can_write()))
  with check (tenant_id = (select private.current_tenant_id())
              and (select private.has_permission('users_security', 'manage'))
              and (select private.tenant_can_write()));

create policy scope_profile_rule_select on public.scope_profile_rule
  for select to authenticated
  using (tenant_id = (select private.current_tenant_id())
         and (select private.has_permission('users_security', 'view')));
create policy scope_profile_rule_insert on public.scope_profile_rule
  for insert to authenticated
  with check (tenant_id = (select private.current_tenant_id())
              and (select private.has_permission('users_security', 'manage'))
              and (select private.tenant_can_write()));
create policy scope_profile_rule_update on public.scope_profile_rule
  for update to authenticated
  using (tenant_id = (select private.current_tenant_id())
         and (select private.has_permission('users_security', 'manage'))
         and (select private.tenant_can_write()))
  with check (tenant_id = (select private.current_tenant_id())
              and (select private.has_permission('users_security', 'manage'))
              and (select private.tenant_can_write()));

revoke delete, truncate on public.scope_profile, public.scope_profile_rule from anon, authenticated;

-- 1.7 G2 body plus scope_profile_id, kept in the distinct: a Pune grant and a tenant-wide grant are two rows.
create or replace function private.rebuild_effective_permission(p_tenant_id uuid, p_user_id uuid)
returns void language sql security definer set search_path = '' as $$
  delete from private.user_effective_permission where tenant_id = p_tenant_id and user_id = p_user_id;

  insert into private.user_effective_permission (tenant_id, user_id, domain_operation_id, effective_from, effective_to,
                                                 scope_profile_id)
  select distinct m.tenant_id, m.user_id, p.domain_operation_id, a.effective_from, a.effective_to, a.scope_profile_id
  from public.tenant_membership m
  join public.user_group_assignment a on a.tenant_id = m.tenant_id and a.user_id = m.user_id and a.deleted_at is null
  join public.security_group g        on g.tenant_id = a.tenant_id and g.id = a.security_group_id and g.deleted_at is null
  join public.group_domain_policy p   on p.tenant_id = g.tenant_id and p.security_group_id = g.id and p.deleted_at is null
  where m.tenant_id = p_tenant_id and m.user_id = p_user_id and m.status = 'active' and m.deleted_at is null;
$$;
