-- Story 6.1: the row-scope helpers (data-model-goal6.md §3, S3). OWNER REVIEW (CLAUDE.md §9): helper functions.
-- has_permission() is unchanged: it says whether the user holds the operation at all. Scope is a second clause:
--   ((select private.scope_all(d, o)) or <asset id> in (select private.scope_asset_ids(d, o)))
-- Set form (spike 1.7 §6): unscoped users stop at the InitPlan; scoped users build one id set per statement.
-- Read only user_effective_permission, the rules, location_closure and asset_category (CLAUDE.md §7.5).

-- True when the user holds the operation now through a tenant-wide grant (scope_profile_id null).
create function private.scope_all(p_domain text, p_operation text)
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
      and uep.scope_profile_id is null
  );
$$;

-- One row per live profile the user holds the operation through now. locs: rule locations and descendants,
-- cats: rule categories and children; null = that dimension is unrestricted. S4: a profile with no live rule
-- gives no row, so it grants nothing.
create function private.scope_rules(p_domain text, p_operation text)
returns table (locs uuid[], cats uuid[]) language sql stable security definer set search_path = '' as $$
  with prof as (
    select distinct uep.tenant_id, uep.scope_profile_id as id
    from private.user_effective_permission uep
    join public.domain_operation o on o.id = uep.domain_operation_id
    join public.security_domain d  on d.id = o.security_domain_id
    join public.scope_profile sp   on sp.tenant_id = uep.tenant_id and sp.id = uep.scope_profile_id and sp.deleted_at is null
    where uep.tenant_id = private.current_tenant_id()
      and uep.user_id   = (select auth.uid())
      and d.code = p_domain and o.code = p_operation
      and uep.effective_from <= now()
      and (uep.effective_to is null or uep.effective_to > now())
  )
  select (select array_agg(c.descendant_id)
          from public.scope_profile_rule r
          join private.location_closure c on c.tenant_id = r.tenant_id and c.ancestor_id = r.location_id
          where r.tenant_id = p.tenant_id and r.scope_profile_id = p.id and r.deleted_at is null),
         (with recursive down as (
            select r.category_id as id from public.scope_profile_rule r
            where r.tenant_id = p.tenant_id and r.scope_profile_id = p.id and r.deleted_at is null
              and r.category_id is not null
            union
            select c.id from public.asset_category c join down on c.parent_id = down.id
            where c.tenant_id = p.tenant_id)
          select array_agg(id) from down)
  from prof p
  where exists (select 1 from public.scope_profile_rule r
                where r.tenant_id = p.tenant_id and r.scope_profile_id = p.id and r.deleted_at is null);
$$;
revoke all on function private.scope_rules(text, text) from public, anon, authenticated;

-- Live assets of the current tenant in the union of the user's profiles for the operation (S3 a). Only
-- called when scope_all is false. S5: an asset with no location never matches a location rule.
create function private.scope_asset_ids(p_domain text, p_operation text)
returns setof uuid language sql stable security definer set search_path = '' as $$
  select a.id
  from private.scope_rules(p_domain, p_operation) p
  join public.asset a on (p.locs is null or a.location_id = any (p.locs))
                     and (p.cats is null or a.category_id = any (p.cats))
  where a.tenant_id = private.current_tenant_id() and a.deleted_at is null;
$$;

-- The asset table's own form (§8: the id set above was too slow for list pages). Matched on the row's own
-- columns, so a sorted list walks its index and stops at the page size:
--   location_id = any (scope_locations) or category_id = any (scope_categories) or id in (scope_mixed_ids)
-- Still exact across profiles: a profile with both dimensions goes through the id set (its intersection),
-- a one-dimension profile through the arrays.
create function private.scope_locations(p_domain text, p_operation text)
returns uuid[] language sql stable security definer set search_path = '' as $$
  select coalesce(array_agg(distinct l), '{}') from private.scope_rules(p_domain, p_operation) p, unnest(p.locs) l
  where p.cats is null;
$$;
create function private.scope_categories(p_domain text, p_operation text)
returns uuid[] language sql stable security definer set search_path = '' as $$
  select coalesce(array_agg(distinct c), '{}') from private.scope_rules(p_domain, p_operation) p, unnest(p.cats) c
  where p.locs is null;
$$;
create function private.scope_mixed_ids(p_domain text, p_operation text)
returns setof uuid language sql stable security definer set search_path = '' as $$
  select a.id
  from private.scope_rules(p_domain, p_operation) p
  join public.asset a on a.location_id = any (p.locs) and a.category_id = any (p.cats)
  where p.locs is not null and p.cats is not null
    and a.tenant_id = private.current_tenant_id() and a.deleted_at is null;
$$;

-- One location and category pair: for write checks on a new row (S6), which is not in the table yet.
-- Single rows only; reads use the set form above.
create function private.in_scope(p_domain text, p_operation text, p_location_id uuid, p_category_id uuid)
returns boolean language sql stable security definer set search_path = '' as $$
  select private.scope_all(p_domain, p_operation)
      or exists (select 1 from private.scope_rules(p_domain, p_operation) p
                 where (p.locs is null or p_location_id = any (p.locs))
                   and (p.cats is null or p_category_id = any (p.cats)));
$$;

-- One existing asset (live or not), for the action functions. Another tenant's or a missing id: false.
create function private.asset_in_scope(p_domain text, p_operation text, p_asset_id uuid)
returns boolean language sql stable security definer set search_path = '' as $$
  select coalesce((select private.in_scope(p_domain, p_operation, a.location_id, a.category_id)
                   from public.asset a where a.tenant_id = private.current_tenant_id() and a.id = p_asset_id), false);
$$;

revoke all on function private.scope_all(text, text), private.scope_asset_ids(text, text),
  private.scope_locations(text, text), private.scope_categories(text, text), private.scope_mixed_ids(text, text),
  private.in_scope(text, text, uuid, uuid), private.asset_in_scope(text, text, uuid) from public, anon;
grant execute on function private.scope_all(text, text), private.scope_asset_ids(text, text),
  private.scope_locations(text, text), private.scope_categories(text, text), private.scope_mixed_ids(text, text),
  private.in_scope(text, text, uuid, uuid), private.asset_in_scope(text, text, uuid) to authenticated;
