-- Story 5.5: Locations status counts. docs/data-model-goal5.md §15.1 (L1 a).
-- As 5.4 location_asset_counts, with one count per system status. Invoker: every check comes from what it
-- reads, asset_view (tenant, asset_core.view, live asset, 6.1 scope later) and obligation under its RLS
-- (overdue is 0 without obligation.view). Exact per asset location; the web rolls up the tree.
create function public.location_status_counts()
returns table (location_id uuid, in_stock integer, active integer, under_maintenance integer,
               inactive integer, disposed integer, overdue integer)
language sql stable set search_path = '' as $$
  with a as (
    select v.location_id,
           count(*) filter (where v.status = 'in_stock')::int as in_stock,
           count(*) filter (where v.status = 'active')::int as active,
           count(*) filter (where v.status = 'under_maintenance')::int as under_maintenance,
           count(*) filter (where v.status = 'inactive')::int as inactive,
           count(*) filter (where v.status = 'disposed')::int as disposed
    from public.asset_view v
    group by v.location_id
  ), o as (
    select v.location_id, count(*)::int as overdue
    from public.obligation o
    join public.asset_view v on v.tenant_id = o.tenant_id and v.id = o.asset_id
    where o.deleted_at is null and o.due_state = 'overdue'
    group by v.location_id
  )
  select a.location_id, a.in_stock, a.active, a.under_maintenance, a.inactive, a.disposed, coalesce(o.overdue, 0)
  from a left join o on o.location_id is not distinct from a.location_id
$$;

revoke all on function public.location_status_counts() from public, anon;
grant execute on function public.location_status_counts() to authenticated;
