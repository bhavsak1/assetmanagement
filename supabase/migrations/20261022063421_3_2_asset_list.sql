-- Story 3.2: the Assets list read path. Design and owner decisions S1 to S5: docs/data-model-goal3.md §13.
-- The list reads asset_view (masking, tenant and permission checks stay there) through list_assets()
-- and count_assets(). Search goes through an id-only security definer helper (spike 1.7 F5), because
-- ilike is not leakproof and cannot use an index under RLS or through the view.

create extension if not exists pg_trgm with schema extensions;
create extension if not exists btree_gin with schema extensions;

-- Tenant first (btree_gin), so a search stays inside the tenant. Partial like every list index (§8).
create index asset_search_trgm on public.asset using gin (
  tenant_id, name extensions.gin_trgm_ops, tag extensions.gin_trgm_ops, serial_number extensions.gin_trgm_ops
) where deleted_at is null;

-- Ids of live assets whose name, tag or serial number contains p_term. Repeats the asset_view checks
-- (tenant, asset_core.view, live rows); the caller still reads the rows through asset_view.
-- 6.1 adds the scope clause here in set form. Owner review item.
-- The pattern goes in as a literal: as a parameter the planner cannot cost the trigram index and
-- reads the whole table. The statement is its own function so the tests can EXPLAIN it.
create function private.asset_search_sql(p_term text)
returns text language sql immutable set search_path = '' as $$
  select format(
    'select a.id from public.asset a
     where a.tenant_id = (select private.current_tenant_id())
       and (select private.has_permission(''asset_core'', ''view''))
       and a.deleted_at is null
       and (a.name ilike %1$L or a.tag ilike %1$L or a.serial_number ilike %1$L)',
    '%' || replace(replace(replace(p_term, '\', '\\'), '%', '\%'), '_', '\_') || '%');
$$;

create function private.search_asset_ids(p_term text)
returns setof uuid language plpgsql stable security definer set search_path = '' as $$
begin
  return query execute private.asset_search_sql(p_term);
end;
$$;

-- The location and every descendant in the current tenant (2.3 closure), for "location with descendants".
-- Ids for the asset list only, so the same asset_core.view check as the list.
create function private.location_subtree_ids(p_location_id uuid)
returns uuid[] language sql stable security definer set search_path = '' as $$
  select coalesce(array_agg(c.descendant_id), '{}')
  from private.location_closure c
  where c.tenant_id = private.current_tenant_id() and c.ancestor_id = p_location_id
    and private.has_permission('asset_core', 'view');
$$;

-- The category and every descendant in the current tenant. Categories have no closure; trees are small.
create function private.category_subtree_ids(p_category_id uuid)
returns uuid[] language sql stable security definer set search_path = '' as $$
  with recursive down as (
    select c.id from public.asset_category c
    where c.tenant_id = private.current_tenant_id() and c.id = p_category_id
      and private.has_permission('asset_core', 'view')
    union
    select c.id from public.asset_category c join down on c.parent_id = down.id
    where c.tenant_id = private.current_tenant_id()
  )
  select coalesce(array_agg(id), '{}') from down;
$$;

-- The where clause for the list and the count. Values go in as literals (%L), so each call is planned
-- with its real values: no `p is null or ...` left in the plan (§13.1). Helpers in (select ...): once per query.
create function private.asset_list_where(p_term text, p_status text, p_category_id uuid, p_location_id uuid)
returns text language sql immutable set search_path = '' as $$
  select concat_ws(' and ', 'true',
    -- Set form, like the 6.1 scope: one array, then primary key lookups whatever the table stats say.
    case when btrim(p_term) <> ''
         then format('v.id = any ((select array(select private.search_asset_ids(%L)))::uuid[])', btrim(p_term)) end,
    case when p_status is not null then format('v.status = %L', p_status) end,
    case when p_category_id is not null
         then format('v.category_id = any ((select private.category_subtree_ids(%L))::uuid[])', p_category_id) end,
    case when p_location_id is not null
         then format('v.location_id = any ((select private.location_subtree_ids(%L))::uuid[])', p_location_id) end);
$$;

-- The statement for one page. Keyset paging: the sort value and id of the last row of the previous page.
-- Sorts: name (default), tag, updated (newest first), each with its index (§8). Separate from
-- list_assets() so the tests can EXPLAIN exactly what it runs.
create function private.asset_list_sql(
  p_term text, p_status text, p_category_id uuid, p_location_id uuid,
  p_sort text, p_after_value text, p_after_id uuid, p_limit integer)
returns text language plpgsql immutable set search_path = '' as $$
declare
  v_sql text := 'select v.* from public.asset_view v where '
                || private.asset_list_where(p_term, p_status, p_category_id, p_location_id);
begin
  if p_sort is null or p_sort not in ('name', 'tag', 'updated') then
    raise exception 'unknown sort: %', p_sort using errcode = '22023';
  end if;
  if p_limit is null or p_limit not between 1 and 100 then
    raise exception 'limit must be 1 to 100' using errcode = '22023';
  end if;
  if p_after_id is not null then
    v_sql := v_sql || case p_sort
      when 'name' then format(' and (v.name, v.id) > (%L, %L::uuid)', p_after_value, p_after_id)
      when 'tag'  then format(' and v.tag > %L', p_after_value)
      -- The index is (updated_at desc, id): start at the cursor time, then skip ids already shown.
      else format(' and v.updated_at <= %1$L::timestamptz and (v.updated_at < %1$L::timestamptz or v.id > %2$L::uuid)',
                  p_after_value, p_after_id)
    end;
  end if;
  v_sql := v_sql || case p_sort
    when 'name' then ' order by v.name, v.id'
    when 'tag'  then ' order by v.tag'
    else ' order by v.updated_at desc, v.id'
  end || format(' limit %s', p_limit);
  return v_sql;
end;
$$;

-- One page of the list. Security invoker: the rows come from asset_view under the caller's own token.
create function public.list_assets(
  p_term text default null, p_status text default null, p_category_id uuid default null,
  p_location_id uuid default null, p_sort text default 'name', p_after_value text default null,
  p_after_id uuid default null, p_limit integer default 50)
returns setof public.asset_view language plpgsql stable set search_path = '' as $$
begin
  return query execute private.asset_list_sql(p_term, p_status, p_category_id, p_location_id,
                                              p_sort, p_after_value, p_after_id, p_limit);
end;
$$;

-- Matching rows, capped at 10,001 (S5): the app shows "10,000+" past 10,000.
create function public.count_assets(
  p_term text default null, p_status text default null, p_category_id uuid default null, p_location_id uuid default null)
returns integer language plpgsql stable set search_path = '' as $$
declare
  v_n integer;
begin
  execute 'select count(*)::int from (select 1 from public.asset_view v where '
          || private.asset_list_where(p_term, p_status, p_category_id, p_location_id) || ' limit 10001) c'
    into v_n;
  return v_n;
end;
$$;

revoke all on function private.asset_search_sql(text), private.search_asset_ids(text), private.location_subtree_ids(uuid),
  private.category_subtree_ids(uuid), private.asset_list_where(text, text, uuid, uuid),
  private.asset_list_sql(text, text, uuid, uuid, text, text, uuid, integer),
  public.list_assets(text, text, uuid, uuid, text, text, uuid, integer), public.count_assets(text, text, uuid, uuid)
  from public, anon;
-- The list functions run as the caller, so the caller needs the helpers. Each returns ids of the
-- caller's own tenant only.
grant execute on function private.search_asset_ids(text), private.location_subtree_ids(uuid),
  private.category_subtree_ids(uuid), private.asset_list_where(text, text, uuid, uuid),
  private.asset_list_sql(text, text, uuid, uuid, text, text, uuid, integer),
  public.list_assets(text, text, uuid, uuid, text, text, uuid, integer), public.count_assets(text, text, uuid, uuid)
  to authenticated;
