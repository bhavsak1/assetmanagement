-- Story 6.5: "Why can this user see this?" (docs/data-model-goal6.md §34). Owner accepted E1 to E9 on 1 Nov 2026.
-- OWNER REVIEW (CLAUDE.md §9): both functions. Read-only: no table, policy or write path changes.

-- One profile's scope, for any user (the 6.1 helpers work for auth.uid() only and stay unchanged [E6]).
-- Same expansion as private.scope_rules: locations through the closure, categories down the tree, null when the
-- dimension has no rule, no row when the profile has no live rule (S4) or is deleted.
create function private.profile_scope(p_profile_id uuid)
returns table (locs uuid[], cats uuid[]) language sql stable security definer set search_path = '' as $$
  select (select array_agg(c.descendant_id)
          from public.scope_profile_rule r
          join private.location_closure c on c.tenant_id = r.tenant_id and c.ancestor_id = r.location_id
          where r.tenant_id = sp.tenant_id and r.scope_profile_id = sp.id and r.deleted_at is null),
         (with recursive down as (
            select r.category_id as id from public.scope_profile_rule r
            where r.tenant_id = sp.tenant_id and r.scope_profile_id = sp.id and r.deleted_at is null
              and r.category_id is not null
            union
            select c.id from public.asset_category c join down on c.parent_id = down.id
            where c.tenant_id = sp.tenant_id)
          select array_agg(id) from down)
  from public.scope_profile sp
  where sp.id = p_profile_id and sp.deleted_at is null
    and exists (select 1 from public.scope_profile_rule r
                where r.tenant_id = sp.tenant_id and r.scope_profile_id = sp.id and r.deleted_at is null);
$$;
revoke all on function private.profile_scope(uuid) from public, anon, authenticated;

-- One row per live assignment of p_user_id (why it grants or not), then a summary row (security_group_id null).
-- E1: callers need users_security.view; another tenant's user gives no rows. An asset must be visible to the
-- caller (asset_view runs the caller's own grant and scope), else "asset not found", so nobody learns more
-- than they already see. Returns names and dates the caller already reads on the Security screen, never a value.
-- E2: reasons come from the policy graph; the summary is checked against user_effective_permission (what
-- enforcement reads) and a disagreement shows as denied with note rebuild_mismatch.
-- E4: draft = add / remove when the open change set would change the group's grant.
create function public.explain_access(p_user_id uuid, p_domain text, p_operation text, p_asset_id uuid default null)
returns table (security_group_id uuid, group_name text, scope_profile_id uuid, scope_profile_name text,
               effective_from timestamptz, effective_to timestamptz, outcome text, draft text, note text)
language plpgsql stable security definer set search_path = '' as $$
#variable_conflict use_column
declare
  v_tenant uuid := private.current_tenant_id();
  v_op     uuid;
  -- E3: the domains 6.1 put a scope clause on (data-model-goal6.md §4).
  v_scoped boolean := p_domain in ('asset_core', 'asset_lifecycle', 'obligation', 'service_record', 'coverage_contract',
                                   'asset_attachment', 'service_record_attachment');
  v_loc    uuid;
  v_cat    uuid;
  v_active boolean;
  v_graph  boolean;
  v_uep    boolean;
begin
  if not private.has_permission('users_security', 'view') then
    return;
  end if;
  select m.status = 'active' into v_active from public.tenant_membership m
  where m.tenant_id = v_tenant and m.user_id = p_user_id and m.deleted_at is null;
  if v_active is null then
    return;
  end if;
  select o.id into v_op from public.domain_operation o join public.security_domain d on d.id = o.security_domain_id
  where d.code = p_domain and o.code = p_operation;
  if v_op is null then
    raise exception 'unknown operation' using errcode = '22023';
  end if;
  if p_asset_id is not null then
    if not exists (select 1 from public.asset_view av where av.id = p_asset_id) then
      raise exception 'asset not found' using errcode = 'P0002';
    end if;
    select a.location_id, a.category_id into v_loc, v_cat from public.asset a where a.id = p_asset_id;
  end if;

  return query
  with a as (
    select a.security_group_id, g.name as group_name, a.scope_profile_id, sp.name as scope_profile_name,
           a.effective_from, a.effective_to,
           exists (select 1 from public.group_domain_policy p
                   where p.security_group_id = g.id and p.domain_operation_id = v_op and p.deleted_at is null) as live,
           (select v_op = any (i.operation_ids) from public.policy_change_set_item i
            join public.policy_change_set cs on cs.id = i.policy_change_set_id and cs.status = 'draft'
            where cs.tenant_id = v_tenant and i.security_group_id = g.id and i.deleted_at is null) as wanted
    from public.user_group_assignment a
    join public.security_group g on g.tenant_id = a.tenant_id and g.id = a.security_group_id and g.deleted_at is null
    left join public.scope_profile sp on sp.tenant_id = a.tenant_id and sp.id = a.scope_profile_id
    where a.tenant_id = v_tenant and a.user_id = p_user_id and a.deleted_at is null
  )
  select a.security_group_id, a.group_name, a.scope_profile_id, a.scope_profile_name, a.effective_from, a.effective_to,
         case
           when not v_active then 'member_inactive'
           when not a.live then 'no_policy'
           when not (a.effective_from <= now() and (a.effective_to is null or a.effective_to > now())) then 'not_effective'
           when a.scope_profile_id is null or not v_scoped then 'grants'
           when not exists (select 1 from private.profile_scope(a.scope_profile_id)) then 'empty_profile'
           when p_asset_id is not null and not exists (
             select 1 from private.profile_scope(a.scope_profile_id) s
             where (s.locs is null or v_loc = any (s.locs)) and (s.cats is null or v_cat = any (s.cats))) then 'out_of_scope'
           else 'grants'
         end,
         case when a.wanted and not a.live then 'add' when not a.wanted and a.live then 'remove' end,
         null::text
  from a
  order by a.group_name, a.effective_from;

  v_graph := exists (
    select 1 from public.user_group_assignment a
    join public.security_group g on g.tenant_id = a.tenant_id and g.id = a.security_group_id and g.deleted_at is null
    join public.group_domain_policy p on p.security_group_id = g.id and p.domain_operation_id = v_op and p.deleted_at is null
    where v_active and a.tenant_id = v_tenant and a.user_id = p_user_id and a.deleted_at is null
      and a.effective_from <= now() and (a.effective_to is null or a.effective_to > now())
      and (a.scope_profile_id is null or not v_scoped
           or exists (select 1 from private.profile_scope(a.scope_profile_id) s
                      where p_asset_id is null
                         or (s.locs is null or v_loc = any (s.locs)) and (s.cats is null or v_cat = any (s.cats)))));
  v_uep := exists (
    select 1 from private.user_effective_permission u
    where u.tenant_id = v_tenant and u.user_id = p_user_id and u.domain_operation_id = v_op
      and u.effective_from <= now() and (u.effective_to is null or u.effective_to > now())
      and (u.scope_profile_id is null or not v_scoped
           or exists (select 1 from private.profile_scope(u.scope_profile_id) s
                      where p_asset_id is null
                         or (s.locs is null or v_loc = any (s.locs)) and (s.cats is null or v_cat = any (s.cats)))));

  return query select null::uuid, null::text, null::uuid, null::text, null::timestamptz, null::timestamptz,
    case when v_graph and v_uep then 'grants' else 'denied' end,
    null::text,
    case when v_graph <> v_uep then 'rebuild_mismatch'
         when p_operation <> 'view' and not private.tenant_can_write() then 'tenant_read_only'
         when p_asset_id is not null and not v_scoped then 'scope_not_applicable' end;
end;
$$;
revoke all on function public.explain_access(uuid, text, text, uuid) from public, anon;
grant execute on function public.explain_access(uuid, text, text, uuid) to authenticated;
