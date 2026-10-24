-- Story 4.2 (C6): coverage status per asset and group, for a page of assets at once (4.3 detail card,
-- 4.4 list column). docs/data-model-goal4.md §21. Groups: warranty (with extended warranty), amc, other.
-- Best row per group: active, expiring, future, expired; then the latest end (future: the earliest start).
-- No row for an asset and group means never covered (doc change #8). The vendor is the responsible
-- vendor; OQ-27 precedence is a Phase 2 hook (asset-wise rows are all equally specific).
-- Invoker: RLS on coverage_asset and coverage_view decide what is seen. No `set search_path` on purpose:
-- it would stop Postgres inlining the function, and 4.4 joins it into the list query. Every name is
-- schema-qualified, and an invoker function gains no rights from the path.
create function public.asset_coverage(p_asset_ids uuid[])
returns table (asset_id uuid, coverage_group text, status text, coverage_id uuid, vendor_id uuid,
               start_date date, end_date date)
language sql stable as $$
  -- Materialized: start from the page's links (asset index), never from every contract of the tenant.
  with ca as materialized (
    select ca.asset_id, ca.coverage_id
    from public.coverage_asset ca
    where ca.tenant_id = (select private.current_tenant_id())
      and ca.asset_id = any (p_asset_ids)
      and ca.deleted_at is null
  )
  select distinct on (ca.asset_id, g.grp)
         ca.asset_id, g.grp, c.status, c.id, c.vendor_id, c.start_date, c.end_date
  from ca
  join public.coverage_view c on c.id = ca.coverage_id
  cross join lateral (select case when c.coverage_type = 'extended_warranty' then 'warranty'
                                  else c.coverage_type end) g (grp)
  order by ca.asset_id, g.grp,
           array_position(array['active', 'expiring', 'future', 'expired'], c.status),
           case when c.status = 'future' then c.start_date end,
           c.end_date desc, c.id;
$$;
revoke all on function public.asset_coverage(uuid[]) from public, anon;
grant execute on function public.asset_coverage(uuid[]) to authenticated;
