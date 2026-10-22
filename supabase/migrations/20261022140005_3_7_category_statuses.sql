-- Story 3.7 (R1, R2): the ordered status set of a category, inherited from the nearest parent.
-- data-model-goal3.md §18.2. Stored on the category, so the category policy (category_config.manage)
-- and its audit trigger already cover writes. Null = inherit.
alter table public.asset_category add column status_ids uuid[] null;

-- A set: not empty, no duplicates, live active statuses of the same tenant, and at least one a new
-- asset can start in (in_stock or active). Definer: reads statuses whatever the caller's grants.
create function private.check_category_statuses()
returns trigger language plpgsql security definer set search_path = '' as $$
begin
  if new.status_ids is null or new.status_ids is not distinct from old.status_ids then
    return new;
  end if;
  if cardinality(new.status_ids) = 0
     or cardinality(new.status_ids) <> (select count(distinct x) from unnest(new.status_ids) x) then
    raise exception 'a status set needs at least one status and no duplicates' using errcode = '23514';
  end if;
  if cardinality(new.status_ids) <> (
       select count(*) from public.asset_status s
       where s.tenant_id = new.tenant_id and s.id = any (new.status_ids) and s.is_active and s.deleted_at is null) then
    raise exception 'status set has an unknown or inactive status' using errcode = '23514';
  end if;
  if not exists (select 1 from public.asset_status s
                 where s.tenant_id = new.tenant_id and s.id = any (new.status_ids)
                   and s.system_status in ('in_stock', 'active')) then
    raise exception 'status set needs a status mapped to in_stock or active' using errcode = '23514';
  end if;
  return new;
end;
$$;
revoke all on function private.check_category_statuses() from public, anon, authenticated;

-- OLD is null on insert; plpgsql reads its fields as null there.
create trigger check_category_statuses before insert or update of status_ids on public.asset_category
  for each row execute function private.check_category_statuses();

-- The effective set of a category: its own, else the nearest ancestor's; with no set anywhere,
-- every active status of the tenant (R2), in system order then label. Writes use it (asset triggers,
-- the status action), never the list. Category trees are small (2.1: no closure).
create function private.effective_status_ids(p_tenant_id uuid, p_category_id uuid)
returns uuid[] language sql stable security definer set search_path = '' as $$
  select coalesce(
    (with recursive up as (
       select c.parent_id, c.status_ids, 0 as depth from public.asset_category c
       where c.tenant_id = p_tenant_id and c.id = p_category_id
       union all
       select c.parent_id, c.status_ids, up.depth + 1 from public.asset_category c
       join up on c.tenant_id = p_tenant_id and c.id = up.parent_id
       where up.status_ids is null
     )
     select status_ids from up where status_ids is not null order by depth limit 1),
    (select array_agg(s.id order by array_position(
              array['in_stock', 'active', 'under_maintenance', 'inactive', 'disposed'], s.system_status), lower(s.label))
     from public.asset_status s
     where s.tenant_id = p_tenant_id and s.is_active and s.deleted_at is null));
$$;
revoke all on function private.effective_status_ids(uuid, uuid) from public, anon, authenticated;

-- For the app (create form): the effective set of a category in the current tenant, in order.
-- Only for callers who may read statuses (same rule as the asset_status select policy).
create function public.category_statuses(p_category_id uuid default null)
returns uuid[] language sql stable security definer set search_path = '' as $$
  select private.effective_status_ids(private.current_tenant_id(), p_category_id)
  where private.current_tenant_id() is not null
    and (private.has_permission('category_config', 'view') or private.has_permission('asset_core', 'view'));
$$;
revoke all on function public.category_statuses(uuid) from public, anon;
grant execute on function public.category_statuses(uuid) to authenticated;
