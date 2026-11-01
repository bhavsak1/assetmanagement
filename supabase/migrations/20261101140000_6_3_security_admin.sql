-- Story 6.3: what the Security screen needs beyond the 1.x and 6.1 tables (docs/data-model-goal6.md §21).
-- Owner accepted G1 to G8 on 1 Nov 2026. OWNER REVIEW (CLAUDE.md §9): every function and trigger here.
-- Groups, assignments, profiles and rules are still written through their RLS policies; audit, rebuild and
-- the permission_version bump are the existing 1.3, 1.5 and 1.7 triggers.

-- Member list for the Assignments tab [G4]. user_profile is own-row only, so this exposes four columns
-- of the current tenant's members to users_security.view and nothing to anyone else.
create function public.security_members()
returns table (user_id uuid, display_name text, email text, status text)
language sql stable security definer set search_path = '' as $$
  select m.user_id, p.display_name, p.email, m.status
  from public.tenant_membership m
  join public.user_profile p on p.id = m.user_id
  where m.tenant_id = private.current_tenant_id() and m.deleted_at is null
    and private.has_permission('users_security', 'view')
  order by p.display_name;
$$;
revoke all on function public.security_members() from public, anon;
grant execute on function public.security_members() to authenticated;

-- The grid's one write path [G3]: make the group's live grants exactly p_operation_ids. Invoker, so the
-- 1.3 policies still decide (tenant, manage, tenant_can_write, not system); the checks up front only turn
-- RLS's silent no-op on the update into an error. Unchanged grants keep their row.
-- 6.4 hook: 6.4 changes this body to write a draft change set instead of the live rows.
create function public.set_group_policies(p_group_id uuid, p_operation_ids uuid[])
returns void language plpgsql security invoker set search_path = '' as $$
declare
  v_ids uuid[] := coalesce(p_operation_ids, '{}');
begin
  if not (private.has_permission('users_security', 'manage') and private.tenant_can_write()) then
    raise exception 'not allowed' using errcode = '42501';
  end if;
  if not exists (select 1 from public.security_group g
                 where g.id = p_group_id and g.tenant_id = private.current_tenant_id() and g.deleted_at is null) then
    raise exception 'group not found' using errcode = 'P0002';
  end if;
  if exists (select 1 from public.security_group g where g.id = p_group_id and g.group_type = 'system') then
    raise exception 'system groups cannot be edited' using errcode = '42501';
  end if;

  update public.group_domain_policy set deleted_at = now()
  where security_group_id = p_group_id and deleted_at is null and domain_operation_id <> all (v_ids);

  insert into public.group_domain_policy (tenant_id, security_group_id, domain_operation_id)
  select g.tenant_id, g.id, o.id
  from public.security_group g
  join public.domain_operation o on o.id = any (v_ids)
  where g.id = p_group_id
    and not exists (select 1 from public.group_domain_policy p
                    where p.security_group_id = g.id and p.domain_operation_id = o.id and p.deleted_at is null);
end;
$$;
revoke all on function public.set_group_policies(uuid, uuid[]) from public, anon;
grant execute on function public.set_group_policies(uuid, uuid[]) to authenticated;

-- Lock-out guard [G5, G6]. Deferred to commit, so the rebuild has run and a multi-step swap of admins
-- passes. A tenant must keep one active member holding users_security.manage now and open-ended.
-- Only removals are watched (inserts never take a grant away), and only user-driven changes: provisioning
-- and support scripts run as postgres with no auth.uid() and can repair a tenant.
create function private.check_security_admin_left()
returns trigger language plpgsql security definer set search_path = '' as $$
declare
  v_tenant uuid := case when tg_op = 'DELETE' then old.tenant_id else new.tenant_id end;
begin
  if (select auth.uid()) is null then
    return null;
  end if;
  if not exists (
    select 1
    from private.user_effective_permission uep
    join public.domain_operation o on o.id = uep.domain_operation_id
    join public.security_domain d  on d.id = o.security_domain_id
    where uep.tenant_id = v_tenant
      and d.code = 'users_security' and o.code = 'manage'
      and uep.effective_from <= now() and uep.effective_to is null
  ) then
    raise exception 'last security admin' using errcode = '42501',
      hint = 'Keep at least one member who can manage security, with no end date.';
  end if;
  return null;
end;
$$;
revoke all on function private.check_security_admin_left() from public, anon, authenticated;

create constraint trigger security_admin_left after update or delete on public.group_domain_policy
  deferrable initially deferred for each row execute function private.check_security_admin_left();
create constraint trigger security_admin_left after update or delete on public.user_group_assignment
  deferrable initially deferred for each row execute function private.check_security_admin_left();
create constraint trigger security_admin_left after update of deleted_at or delete on public.security_group
  deferrable initially deferred for each row execute function private.check_security_admin_left();
-- Not permission_version: the rebuild bumps it on every security change.
create constraint trigger security_admin_left after update of status, deleted_at or delete on public.tenant_membership
  deferrable initially deferred for each row execute function private.check_security_admin_left();

-- A group with live assignments cannot be deleted [G7]; remove or end them first (as scope profiles, 6.1).
create function private.check_security_group_in_use()
returns trigger language plpgsql security definer set search_path = '' as $$
begin
  if new.deleted_at is not null and old.deleted_at is null
     and exists (select 1 from public.user_group_assignment a
                 where a.tenant_id = new.tenant_id and a.security_group_id = new.id and a.deleted_at is null
                   and (a.effective_to is null or a.effective_to > now())) then
    raise exception 'security group is assigned' using errcode = '23503';
  end if;
  return new;
end;
$$;
revoke all on function private.check_security_group_in_use() from public, anon, authenticated;

create trigger check_in_use before update of deleted_at on public.security_group
  for each row execute function private.check_security_group_in_use();
