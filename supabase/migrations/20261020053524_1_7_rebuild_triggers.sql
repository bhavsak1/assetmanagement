-- Story 1.7: two rebuild fixes from the RLS spike (docs/spike-1-7-rls-performance.md, G1 and G2).
-- G1: policy changes refresh each affected member once per statement, not once per policy row.
--     Saving 20 policies on a group with 80 members rebuilt each member 20 times (6.7 s).
-- G2: the rebuild writes each distinct grant once. Overlapping groups no longer multiply rows.

-- G2. Same joins as 1.3; distinct drops rows that differ only by which assignment or group gave them.
create or replace function private.rebuild_effective_permission(p_tenant_id uuid, p_user_id uuid)
returns void language sql security definer set search_path = '' as $$
  delete from private.user_effective_permission where tenant_id = p_tenant_id and user_id = p_user_id;

  insert into private.user_effective_permission (tenant_id, user_id, domain_operation_id, effective_from, effective_to)
  select distinct m.tenant_id, m.user_id, p.domain_operation_id, a.effective_from, a.effective_to
  from public.tenant_membership m
  join public.user_group_assignment a on a.tenant_id = m.tenant_id and a.user_id = m.user_id and a.deleted_at is null
  join public.security_group g        on g.tenant_id = a.tenant_id and g.id = a.security_group_id and g.deleted_at is null
  join public.group_domain_policy p   on p.tenant_id = g.tenant_id and p.security_group_id = g.id and p.deleted_at is null
  where m.tenant_id = p_tenant_id and m.user_id = p_user_id and m.status = 'active' and m.deleted_at is null;
$$;

-- G1. Statement trigger: every member of every group the statement touched (old and new rows), once.
create function private.on_policy_change()
returns trigger language plpgsql security definer set search_path = '' as $$
declare
  v_tenants uuid[] := '{}';
  v_groups  uuid[] := '{}';
begin
  if tg_op <> 'DELETE' then
    select v_tenants || array_agg(tenant_id), v_groups || array_agg(security_group_id) into v_tenants, v_groups from new_rows;
  end if;
  if tg_op <> 'INSERT' then
    select v_tenants || array_agg(tenant_id), v_groups || array_agg(security_group_id) into v_tenants, v_groups from old_rows;
  end if;

  -- Group ids are unique, so the tenant list only lets the (tenant_id, security_group_id) index work.
  perform private.refresh_member(m.tenant_id, m.user_id)
  from (select distinct a.tenant_id, a.user_id from public.user_group_assignment a
        where a.tenant_id = any (v_tenants) and a.security_group_id = any (v_groups) and a.deleted_at is null) m;
  return null;
end;
$$;
revoke all on function private.on_policy_change() from public, anon, authenticated;

drop trigger refresh_permissions on public.group_domain_policy;
create trigger refresh_permissions_insert after insert on public.group_domain_policy
  referencing new table as new_rows
  for each statement execute function private.on_policy_change();
create trigger refresh_permissions_update after update on public.group_domain_policy
  referencing old table as old_rows new table as new_rows
  for each statement execute function private.on_policy_change();
create trigger refresh_permissions_delete after delete on public.group_domain_policy
  referencing old table as old_rows
  for each statement execute function private.on_policy_change();

-- The row trigger function no longer serves group_domain_policy; drop that branch.
create or replace function private.on_security_change()
returns trigger language plpgsql security definer set search_path = '' as $$
begin
  case tg_table_name
    when 'security_group' then
      perform private.refresh_group_members(new.tenant_id, new.id);
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
