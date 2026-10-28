-- Story 5.4: Dashboard "Assets by location". docs/data-model-goal5.md §14.1 (D3 b).
-- Invoker: every check comes from what it reads, asset_view (tenant, asset_core.view, live asset, 6.1 scope
-- later) and obligation under its RLS (tenant, obligation.view; overdue is 0 without it). Exact counts per
-- asset location; the web rolls them up the location tree it already loads (the closure table is private).
create function public.location_asset_counts()
returns table (location_id uuid, assets integer, overdue integer)
language sql stable set search_path = '' as $$
  with a as (
    select v.location_id, count(*)::int as assets
    from public.asset_view v
    group by v.location_id
  ), o as (
    select v.location_id, count(*)::int as overdue
    from public.obligation o
    join public.asset_view v on v.tenant_id = o.tenant_id and v.id = o.asset_id
    where o.deleted_at is null and o.due_state = 'overdue'
    group by v.location_id
  )
  select a.location_id, a.assets, coalesce(o.overdue, 0)
  from a left join o on o.location_id is not distinct from a.location_id
$$;

revoke all on function public.location_asset_counts() from public, anon;
grant execute on function public.location_asset_counts() to authenticated;
