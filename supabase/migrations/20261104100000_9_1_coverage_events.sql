-- Story 9.1: coverage events for notifications (docs/data-model-goal9.md §4, N3). The 4.4 job changed
-- asset.coverage_state with no event (C12). Same body as 8.6, plus: the old state in "a", and one outbox
-- event when an asset enters expiring or out from active or expiring. none -> anything (a new asset, an
-- import) never fires, so bulk loads send no alerts. Same transaction as the change (CLAUDE.md §8).
create or replace function private.refresh_coverage_state(p_asset_ids uuid[], p_now timestamptz default now())
returns integer language sql volatile security definer set search_path = '' as $$
  with a as (
    select a.id, a.tenant_id, a.coverage_state as old_state, (p_now at time zone t.time_zone)::date as today,
           t.coverage_expiring_days as n
    from public.asset a
    join public.tenant t on t.id = a.tenant_id
    where a.id in (select unnest(p_asset_ids))  -- 8.6: = any() of 20,000 ids scanned the array per asset row
  ), l as (
    select a.id as asset_id, a.today, a.n, c.start_date, c.end_date,
           case when c.coverage_type = 'extended_warranty' then 'warranty' else c.coverage_type end as grp
    from a
    join public.coverage_asset ca on ca.tenant_id = a.tenant_id and ca.asset_id = a.id and ca.deleted_at is null
    join public.coverage c on c.tenant_id = ca.tenant_id and c.id = ca.coverage_id and c.deleted_at is null
  ), per_asset as (
    select asset_id, count(*) as links, max(end_date) filter (where end_date < today) as last_end,
           min(least(case when start_date > today then start_date end,
                     case when start_date <= today and end_date >= today then end_date + 1 end,
                     case when start_date <= today and end_date - n + 1 > today then end_date - n + 1 end)) as until
    from l group by asset_id
  ), first_end as (
    select asset_id, min(covered_end) as covered_end
    from (select asset_id, grp, max(end_date) filter (where start_date <= today and end_date >= today) as covered_end
          from l group by asset_id, grp) g
    group by asset_id
  ), s as (
    select a.id, a.tenant_id, a.old_state, coalesce(f.covered_end, p.last_end) as end_date,
           case when f.covered_end is not null then case when f.covered_end < a.today + a.n then 'expiring' else 'active' end
                when p.links > 0 then 'out'
                else 'none' end as state,
           p.until
    from a
    left join per_asset p on p.asset_id = a.id
    left join first_end f on f.asset_id = a.id
  ), u as (
    update public.asset x set coverage_state = s.state, coverage_state_until = s.until
    from s
    where x.id = s.id and (x.coverage_state, x.coverage_state_until) is distinct from (s.state, s.until)
    returning x.id
  ), e as (
    insert into private.outbox_event (tenant_id, event_type, aggregate_type, aggregate_id, payload)
    select s.tenant_id, case s.state when 'expiring' then 'coverage.expiring' else 'coverage.expired' end, 'asset', s.id,
           jsonb_build_object('asset_id', s.id, 'end_date', s.end_date, 'from', s.old_state, 'to', s.state)
    from s
    join u on u.id = s.id
    where s.state in ('expiring', 'out') and s.old_state in ('active', 'expiring') and s.state <> s.old_state
  )
  select count(*)::int from u;
$$;
