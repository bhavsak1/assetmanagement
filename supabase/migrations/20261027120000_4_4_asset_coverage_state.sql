-- Story 4.4: stored coverage state per asset, for the Assets list coverage filter.
-- docs/data-model-goal4.md §33 to §38, owner decisions C11 to C17 (27 Oct 2026). The live set form that
-- §21 planned took 1.4 to 2.4 s per page at 1M assets (§34); a stored column shares an index with each
-- list sort. The column, detail card and Coverage page stay live (C7 a). Owner review items: the
-- definer refresh functions and the guarded audit trigger.

-- C11: the §33 overall value, and the first tenant date on which the calendar alone can change it.
alter table public.asset
  add column coverage_state text not null default 'none'
    check (coverage_state in ('active', 'expiring', 'out', 'none')),
  add column coverage_state_until date;
-- No grant to authenticated: the asset column grants (3.3) leave both columns to the refresh only.

-- One index per list sort, so a filtered page is still a keyset walk with no sort (goal 3 §8).
create index asset_coverage_name_idx on public.asset (tenant_id, coverage_state, name, id) where deleted_at is null;
create index asset_coverage_tag_idx on public.asset (tenant_id, coverage_state, tag) where deleted_at is null;
create index asset_coverage_updated_idx on public.asset (tenant_id, coverage_state, updated_at desc, id) where deleted_at is null;
create index asset_coverage_until_idx on public.asset (tenant_id, coverage_state_until)
  where coverage_state_until is not null and deleted_at is null;

-- C15: a change of N or time zone queues a full refresh of the tenant. The job walks its assets by id
-- from this cursor; null means nothing is queued.
alter table public.tenant add column coverage_refresh_after uuid;

-- Recomputes state and until for the given assets, in each asset's tenant zone and N, and writes only
-- rows that change. Set-wise: one statement for an AMC of hundreds of assets or a job batch.
-- State: of the groups covering today (warranty with extended, amc, other), the one whose latest
-- covering contract ends first; expiring when that end is before today + N. Out: contracts exist, none
-- covers today. None: no live contract linked.
-- Until: the earliest future start, covering end + 1, or day a covering contract becomes expiring.
create function private.refresh_coverage_state(p_asset_ids uuid[], p_now timestamptz default now())
returns integer language sql volatile security definer set search_path = '' as $$
  with a as (
    select a.id, a.tenant_id, (p_now at time zone t.time_zone)::date as today, t.coverage_expiring_days as n
    from public.asset a
    join public.tenant t on t.id = a.tenant_id
    where a.id = any (p_asset_ids)
  ), l as (
    select a.id as asset_id, a.today, a.n, c.start_date, c.end_date,
           case when c.coverage_type = 'extended_warranty' then 'warranty' else c.coverage_type end as grp
    from a
    join public.coverage_asset ca on ca.tenant_id = a.tenant_id and ca.asset_id = a.id and ca.deleted_at is null
    join public.coverage c on c.tenant_id = ca.tenant_id and c.id = ca.coverage_id and c.deleted_at is null
  ), per_asset as (
    select asset_id, count(*) as links,
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
    select a.id,
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
    returning 1
  )
  select count(*)::int from u;
$$;

-- C14: the calendar side. Every 15 minutes, per tenant: assets whose until has come in the tenant's
-- zone, then a queued full refresh (C15), in batches of p_batch, for up to p_budget per run.
create function private.refresh_due_coverage_states(p_now timestamptz default now(), p_batch integer default 10000,
                                                    p_budget interval default '4 minutes')
returns integer language plpgsql volatile security definer set search_path = '' as $$
declare
  v_start timestamptz := clock_timestamp();
  v_total integer := 0;
  v_n integer;
  v_ids uuid[];
  t record;
begin
  for t in select id, (p_now at time zone time_zone)::date as today, coverage_refresh_after from public.tenant loop
    loop
      v_ids := array(select a.id from public.asset a
                     where a.tenant_id = t.id and a.deleted_at is null and a.coverage_state_until <= t.today
                     limit p_batch);
      exit when cardinality(v_ids) = 0;
      v_n := private.refresh_coverage_state(v_ids, p_now);
      v_total := v_total + v_n;
      -- A refresh always moves until past today, so 0 means nothing changed: stop rather than spin.
      exit when v_n = 0 or clock_timestamp() - v_start > p_budget;
    end loop;
    while t.coverage_refresh_after is not null and clock_timestamp() - v_start <= p_budget loop
      v_ids := array(select a.id from public.asset a
                     where a.tenant_id = t.id and a.deleted_at is null and a.id > t.coverage_refresh_after
                     order by a.id limit p_batch);
      v_total := v_total + private.refresh_coverage_state(v_ids, p_now);
      t.coverage_refresh_after := case when cardinality(v_ids) = p_batch then v_ids[p_batch] end;
      update public.tenant set coverage_refresh_after = t.coverage_refresh_after where id = t.id;
    end loop;
  end loop;
  return v_total;
end;
$$;
revoke all on function private.refresh_coverage_state(uuid[], timestamptz),
  private.refresh_due_coverage_states(timestamptz, integer, interval) from public, anon, authenticated;

-- Event side, same transaction as the change, for every writer. Statement level with transition
-- tables: one refresh per statement, however many rows (an AMC with hundreds of links).
create function private.refresh_linked_coverage_state()
returns trigger language plpgsql security definer set search_path = '' as $$
begin
  perform private.refresh_coverage_state(array(select n.asset_id from new_rows n));
  return null;
end;
$$;
create function private.refresh_contract_coverage_state()
returns trigger language plpgsql security definer set search_path = '' as $$
begin
  perform private.refresh_coverage_state(array(
    select ca.asset_id
    from new_rows n
    join old_rows o on o.id = n.id
    join public.coverage_asset ca on ca.tenant_id = n.tenant_id and ca.coverage_id = n.id and ca.deleted_at is null
    where (o.start_date, o.end_date, o.coverage_type, o.deleted_at) is distinct from
          (n.start_date, n.end_date, n.coverage_type, n.deleted_at)));
  return null;
end;
$$;
revoke all on function private.refresh_linked_coverage_state(), private.refresh_contract_coverage_state()
  from public, anon, authenticated;

-- A link is inserted or soft-deleted (its only update). Contract insert needs nothing: it has no links yet.
create trigger refresh_coverage_state_insert after insert on public.coverage_asset
  referencing new table as new_rows for each statement execute function private.refresh_linked_coverage_state();
create trigger refresh_coverage_state_update after update on public.coverage_asset
  referencing new table as new_rows for each statement execute function private.refresh_linked_coverage_state();
create trigger refresh_coverage_state after update on public.coverage
  referencing old table as old_rows new table as new_rows for each statement
  execute function private.refresh_contract_coverage_state();

-- C15: N or time zone changed: queue the whole tenant for the job.
create function private.queue_coverage_refresh()
returns trigger language plpgsql set search_path = '' as $$
begin
  new.coverage_refresh_after := '00000000-0000-0000-0000-000000000000';
  return new;
end;
$$;
revoke all on function private.queue_coverage_refresh() from public, anon, authenticated;
create trigger queue_coverage_refresh before update of coverage_expiring_days, time_zone on public.tenant
  for each row when (old.coverage_expiring_days is distinct from new.coverage_expiring_days
                     or old.time_zone is distinct from new.time_zone)
  execute function private.queue_coverage_refresh();

-- C12: a refresh changes only the two state columns. Then updated_at stays, the value checks skip, and
-- no audit row or asset.updated outbox event is written. Every other change fires them as before.
-- Generic: new asset columns need no change here. Insert and delete keep their own triggers (no OLD).
drop trigger check_asset_values on public.asset;
drop trigger set_updated_at on public.asset;
drop trigger audit on public.asset;
create trigger check_asset_values before insert on public.asset
  for each row execute function private.check_asset_values();
create trigger check_asset_values_update before update on public.asset
  for each row when ((to_jsonb(old) - '{coverage_state,coverage_state_until}'::text[])
                     is distinct from (to_jsonb(new) - '{coverage_state,coverage_state_until}'::text[]))
  execute function private.check_asset_values();
create trigger set_updated_at before update on public.asset
  for each row when ((to_jsonb(old) - '{coverage_state,coverage_state_until}'::text[])
                     is distinct from (to_jsonb(new) - '{coverage_state,coverage_state_until}'::text[]))
  execute function private.set_updated_at();
create trigger audit after insert or delete on public.asset
  for each row execute function private.audit_row('data');
create trigger audit_update after update on public.asset
  for each row when ((to_jsonb(old) - '{coverage_state,coverage_state_until}'::text[])
                     is distinct from (to_jsonb(new) - '{coverage_state,coverage_state_until}'::text[]))
  execute function private.audit_row('data');

-- Same view as 4_1b_asset_vendors with coverage_state appended (C13: one word, readable with asset_core.view).
create or replace view public.asset_view as
  select a.id, a.tenant_id, a.tag, a.name, a.category_id, a.location_id,
         a.status, a.status_reason, a.status_changed_at, a.quantity, a.parent_asset_id, a.criticality,
         a.serial_number, a.manufacturer, a.model, a.purchase_date,
         case when (select private.has_permission('asset_financials', 'view')) then a.purchase_value end as purchase_value,
         case when (select private.has_permission('asset_financials', 'view')) then a.purchase_currency end as purchase_currency,
         a.in_service_date,
         a.custom_values - (select private.hidden_field_keys('asset')) as custom_values,
         a.created_at, a.updated_at, a.created_by, a.updated_by,
         a.location_reason, a.location_changed_at,
         a.status_id,
         a.oem_vendor_id, a.om_vendor_id,
         a.coverage_state
  from public.asset a
  where a.tenant_id = (select private.current_tenant_id())
    and (select private.has_permission('asset_core', 'view'))
    and a.deleted_at is null;

-- The 4.1b list functions with one more filter, p_coverage (C13: needs coverage_contract.view, else it
-- matches nothing). New argument last, with a default: old calls and saved views are unchanged.
drop function public.list_assets(text, text, uuid, uuid, text, text, uuid, integer, uuid, uuid);
drop function public.count_assets(text, text, uuid, uuid, uuid, uuid);
drop function private.asset_list_sql(text, text, uuid, uuid, text, text, uuid, integer, uuid, uuid);
drop function private.asset_list_where(text, text, uuid, uuid, uuid, uuid);

create function private.asset_list_where(p_term text, p_status text, p_category_id uuid, p_location_id uuid,
                                         p_status_id uuid default null, p_vendor_id uuid default null,
                                         p_coverage text default null)
returns text language sql immutable set search_path = '' as $$
  select concat_ws(' and ', 'true',
    -- Set form, like the 6.1 scope: one array, then primary key lookups whatever the table stats say.
    case when btrim(p_term) <> ''
         then format('v.id = any ((select array(select private.search_asset_ids(%L)))::uuid[])', btrim(p_term)) end,
    case when p_status is not null then format('v.status = %L', p_status) end,
    case when p_status_id is not null then format('v.status_id = %L', p_status_id) end,
    case when p_vendor_id is not null then format('(v.oem_vendor_id = %1$L or v.om_vendor_id = %1$L)', p_vendor_id) end,
    case when p_category_id is not null
         then format('v.category_id = any ((select private.category_subtree_ids(%L))::uuid[])', p_category_id) end,
    case when p_location_id is not null
         then format('v.location_id = any ((select private.location_subtree_ids(%L))::uuid[])', p_location_id) end,
    case when p_coverage is not null
         then format('v.coverage_state = %L and (select private.has_permission(''coverage_contract'', ''view''))', p_coverage) end);
$$;

create function private.asset_list_sql(
  p_term text, p_status text, p_category_id uuid, p_location_id uuid,
  p_sort text, p_after_value text, p_after_id uuid, p_limit integer, p_status_id uuid default null,
  p_vendor_id uuid default null, p_coverage text default null)
returns text language plpgsql immutable set search_path = '' as $$
declare
  v_sql text := 'select v.* from public.asset_view v where '
                || private.asset_list_where(p_term, p_status, p_category_id, p_location_id, p_status_id,
                                            p_vendor_id, p_coverage);
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

create function public.list_assets(
  p_term text default null, p_status text default null, p_category_id uuid default null,
  p_location_id uuid default null, p_sort text default 'name', p_after_value text default null,
  p_after_id uuid default null, p_limit integer default 50, p_status_id uuid default null,
  p_vendor_id uuid default null, p_coverage text default null)
returns setof public.asset_view language plpgsql stable set search_path = '' as $$
begin
  return query execute private.asset_list_sql(p_term, p_status, p_category_id, p_location_id,
                                              p_sort, p_after_value, p_after_id, p_limit, p_status_id,
                                              p_vendor_id, p_coverage);
end;
$$;

create function public.count_assets(
  p_term text default null, p_status text default null, p_category_id uuid default null,
  p_location_id uuid default null, p_status_id uuid default null, p_vendor_id uuid default null,
  p_coverage text default null)
returns integer language plpgsql stable set search_path = '' as $$
declare
  v_n integer;
begin
  execute 'select count(*)::int from (select 1 from public.asset_view v where '
          || private.asset_list_where(p_term, p_status, p_category_id, p_location_id, p_status_id,
                                      p_vendor_id, p_coverage)
          || ' limit 10001) c'
    into v_n;
  return v_n;
end;
$$;

revoke all on function private.asset_list_where(text, text, uuid, uuid, uuid, uuid, text),
  private.asset_list_sql(text, text, uuid, uuid, text, text, uuid, integer, uuid, uuid, text),
  public.list_assets(text, text, uuid, uuid, text, text, uuid, integer, uuid, uuid, text),
  public.count_assets(text, text, uuid, uuid, uuid, uuid, text)
  from public, anon;
grant execute on function private.asset_list_where(text, text, uuid, uuid, uuid, uuid, text),
  private.asset_list_sql(text, text, uuid, uuid, text, text, uuid, integer, uuid, uuid, text),
  public.list_assets(text, text, uuid, uuid, text, text, uuid, integer, uuid, uuid, text),
  public.count_assets(text, text, uuid, uuid, uuid, uuid, text)
  to authenticated;

-- Backfill every live asset, then schedule the job (pg_cron: plain Postgres, RDS has it).
select private.refresh_coverage_state(array(select id from public.asset where deleted_at is null));

create extension if not exists pg_cron;
select cron.schedule('assetly_coverage_state', '*/15 * * * *', 'select private.refresh_due_coverage_states()');
