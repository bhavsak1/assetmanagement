-- Story 1.3: user_effective_permission, its rebuild and triggers, the permission_version bump [D4],
-- and the helpers every policy calls. Shapes from docs/data-model-goal1.md §2.11, §3 and §5.
-- scope_profile_id comes with 6.1 [D7]. Policies that use the helpers are in 1_3_security_policies.

-- Flat table every RLS check reads. Rebuilt, never edited. No id or std columns on purpose.
create table private.user_effective_permission (
  tenant_id           uuid not null references public.tenant (id),
  user_id             uuid not null references public.user_profile (id),
  domain_operation_id uuid not null references public.domain_operation (id),
  effective_from      timestamptz not null,
  effective_to        timestamptz null,
  rebuilt_at          timestamptz not null default now()
);
-- has_permission() path.
create index user_effective_permission_idx on private.user_effective_permission (tenant_id, user_id, domain_operation_id);
-- On, no policies: read only through the security definer helpers below.
alter table private.user_effective_permission enable row level security;

-- Every function created in private is closed to clients unless a grant says otherwise.
alter default privileges in schema private revoke execute on functions from public;

-- Rebuild one member's rows: membership -> assignment -> group -> policy (§3).
-- A disabled or deleted membership gets no rows, so its assignments grant nothing.
create function private.rebuild_effective_permission(p_tenant_id uuid, p_user_id uuid)
returns void language sql security definer set search_path = '' as $$
  delete from private.user_effective_permission where tenant_id = p_tenant_id and user_id = p_user_id;

  insert into private.user_effective_permission (tenant_id, user_id, domain_operation_id, effective_from, effective_to)
  select m.tenant_id, m.user_id, p.domain_operation_id, a.effective_from, a.effective_to
  from public.tenant_membership m
  join public.user_group_assignment a on a.tenant_id = m.tenant_id and a.user_id = m.user_id and a.deleted_at is null
  join public.security_group g        on g.tenant_id = a.tenant_id and g.id = a.security_group_id and g.deleted_at is null
  join public.group_domain_policy p   on p.tenant_id = g.tenant_id and p.security_group_id = g.id and p.deleted_at is null
  where m.tenant_id = p_tenant_id and m.user_id = p_user_id and m.status = 'active' and m.deleted_at is null;
$$;
revoke all on function private.rebuild_effective_permission(uuid, uuid) from public, anon, authenticated;

-- Rebuild a member and bump their permission_version [D4]. The bump only tells the UI its menus are stale.
create function private.refresh_member(p_tenant_id uuid, p_user_id uuid)
returns void language sql security definer set search_path = '' as $$
  select private.rebuild_effective_permission(p_tenant_id, p_user_id);
  update public.tenant_membership set permission_version = permission_version + 1
  where tenant_id = p_tenant_id and user_id = p_user_id;
$$;
revoke all on function private.refresh_member(uuid, uuid) from public, anon, authenticated;

-- Every member currently assigned the group.
create function private.refresh_group_members(p_tenant_id uuid, p_group_id uuid)
returns void language sql security definer set search_path = '' as $$
  select private.refresh_member(a.tenant_id, a.user_id)
  from (select distinct tenant_id, user_id from public.user_group_assignment
        where tenant_id = p_tenant_id and security_group_id = p_group_id and deleted_at is null) a;
$$;
revoke all on function private.refresh_group_members(uuid, uuid) from public, anon, authenticated;

-- One trigger function for the four sources (§2.11). Same transaction as the change.
-- Old and new are both refreshed, so moving a row between members or groups fixes both.
-- shortcut: row-level, so a bulk policy insert rebuilds each member once per row; move to
-- statement triggers with transition tables if 1.6 seeding or the 1.7 spike shows it is slow.
create function private.on_security_change()
returns trigger language plpgsql security definer set search_path = '' as $$
begin
  case tg_table_name
    when 'security_group' then
      perform private.refresh_group_members(new.tenant_id, new.id);
    when 'group_domain_policy' then
      if tg_op <> 'INSERT' then
        perform private.refresh_group_members(old.tenant_id, old.security_group_id);
      end if;
      if tg_op <> 'DELETE' and (tg_op = 'INSERT' or old.security_group_id is distinct from new.security_group_id) then
        perform private.refresh_group_members(new.tenant_id, new.security_group_id);
      end if;
    else -- user_group_assignment, tenant_membership
      if tg_op <> 'INSERT' then
        perform private.refresh_member(old.tenant_id, old.user_id);
      end if;
      if tg_op <> 'DELETE' and (tg_op = 'INSERT' or (old.tenant_id, old.user_id) is distinct from (new.tenant_id, new.user_id)) then
        perform private.refresh_member(new.tenant_id, new.user_id);
      end if;
  end case;
  return null;
end;
$$;
revoke all on function private.on_security_change() from public, anon, authenticated;

create trigger refresh_permissions after insert or update or delete on public.group_domain_policy
  for each row execute function private.on_security_change();
create trigger refresh_permissions after insert or update or delete on public.user_group_assignment
  for each row execute function private.on_security_change();
-- Only soft delete (or restore) of a group changes what it grants.
create trigger refresh_permissions after update of deleted_at on public.security_group
  for each row when (old.deleted_at is distinct from new.deleted_at)
  execute function private.on_security_change();
-- Only status or soft delete. The version bump itself updates permission_version, so this does not re-fire.
create trigger refresh_permissions after update of status, deleted_at on public.tenant_membership
  for each row when (old.status is distinct from new.status or old.deleted_at is distinct from new.deleted_at)
  execute function private.on_security_change();

-- Helpers (§5). Policies call them inside (select ...) so they run once per statement.
create function private.current_tenant_id()
returns uuid language sql stable set search_path = '' as $$
  select nullif(auth.jwt() ->> 'tenant_id', '')::uuid
$$;

-- Reads only user_effective_permission (CLAUDE.md §7.5). Effective dates checked at read time.
create function private.has_permission(p_domain text, p_operation text)
returns boolean language sql stable security definer set search_path = '' as $$
  select exists (
    select 1
    from private.user_effective_permission uep
    join public.domain_operation o on o.id = uep.domain_operation_id
    join public.security_domain d  on d.id = o.security_domain_id
    where uep.tenant_id = private.current_tenant_id()
      and uep.user_id   = (select auth.uid())
      and d.code = p_domain and o.code = p_operation
      and uep.effective_from <= now()
      and (uep.effective_to is null or uep.effective_to > now())
  );
$$;

-- OQ-30: writes need an active tenant. read_only and suspended tenants cannot write.
create function private.tenant_can_write()
returns boolean language sql stable security definer set search_path = '' as $$
  select exists (select 1 from public.tenant t
                 where t.id = private.current_tenant_id() and t.status = 'active' and t.deleted_at is null);
$$;

-- First grants on private to clients (0_2 left it closed). Only these three helpers.
grant usage on schema private to authenticated;
revoke all on function private.current_tenant_id(), private.has_permission(text, text), private.tenant_can_write() from public, anon;
grant execute on function private.current_tenant_id(), private.has_permission(text, text), private.tenant_can_write() to authenticated;
