-- Story 5.1: stored obligation state (scheduled, due soon, overdue, paused), kept right by triggers and a
-- pg_cron delta job, and the due-soon tenant setting. docs/data-model-goal5.md §4 and §5, owner decisions
-- O6 and O8 (28 Oct 2026). Same shape as 4.4 (4_4_asset_coverage_state). Owner review items: the definer
-- refresh functions and the cron job.

-- §4: due soon = due within N days of the tenant's today. 30 matches the screens' "Next 30 days".
alter table public.tenant add column obligation_due_soon_days smallint not null default 30
  check (obligation_due_soon_days between 1 and 365);
-- A change of N or time zone queues a full refresh: the job walks the tenant's obligations by id from this
-- cursor. Null means nothing is queued (as coverage_refresh_after).
alter table public.tenant add column obligation_refresh_after uuid;

-- Recomputes state and until for the given obligations in each tenant's zone and N, writes only rows that
-- change, and writes one outbox event per row that enters due_soon or overdue (decision 8). Set-wise.
-- O6: paused when the obligation is inactive, or its asset is inactive, disposed or deleted.
-- Until: scheduled -> the day it becomes due soon; due soon -> the day after it is due; else null.
create function private.refresh_obligation_state(p_ids uuid[], p_now timestamptz default now())
returns integer language sql volatile security definer set search_path = '' as $$
  with s as (
    select o.id, o.tenant_id, o.asset_id, o.name, o.next_due_date, o.due_state as old_state, x.state,
           case x.state when 'scheduled' then o.next_due_date - t.obligation_due_soon_days
                        when 'due_soon' then o.next_due_date + 1 end as until
    from public.obligation o
    join public.tenant t on t.id = o.tenant_id
    join public.asset a on a.tenant_id = o.tenant_id and a.id = o.asset_id
    cross join lateral (select (p_now at time zone t.time_zone)::date as today) d
    cross join lateral (select case
      when not o.is_active or a.deleted_at is not null or a.status in ('inactive', 'disposed') then 'paused'
      when o.next_due_date < d.today then 'overdue'
      when o.next_due_date <= d.today + t.obligation_due_soon_days then 'due_soon'
      else 'scheduled' end as state) x
    where o.id = any (p_ids) and o.deleted_at is null
  ), u as (
    update public.obligation o set due_state = s.state, due_state_until = s.until
    from s
    where o.id = s.id and (o.due_state, o.due_state_until) is distinct from (s.state, s.until)
    returning o.id
  ), e as (
    insert into private.outbox_event (tenant_id, event_type, aggregate_type, aggregate_id, payload)
    select s.tenant_id, 'obligation.' || s.state, 'obligation', s.id,
           jsonb_build_object('asset_id', s.asset_id, 'name', s.name, 'next_due_date', s.next_due_date,
                              'from', s.old_state, 'to', s.state)
    from s
    join u on u.id = s.id
    where s.state in ('due_soon', 'overdue') and s.state is distinct from s.old_state
  )
  select count(*)::int from u;
$$;

-- The calendar side, every 15 minutes (O8): per tenant, obligations whose until has come in the tenant's
-- zone, then a queued full refresh, in batches of p_batch, for up to p_budget per run (4.4 loop).
create function private.refresh_due_obligation_states(p_now timestamptz default now(), p_batch integer default 10000,
                                                      p_budget interval default '4 minutes')
returns integer language plpgsql volatile security definer set search_path = '' as $$
declare
  v_start timestamptz := clock_timestamp();
  v_total integer := 0;
  v_n integer;
  v_ids uuid[];
  t record;
begin
  for t in select id, (p_now at time zone time_zone)::date as today, obligation_refresh_after from public.tenant loop
    loop
      v_ids := array(select o.id from public.obligation o
                     where o.tenant_id = t.id and o.deleted_at is null and o.due_state_until <= t.today
                     limit p_batch);
      exit when cardinality(v_ids) = 0;
      v_n := private.refresh_obligation_state(v_ids, p_now);
      v_total := v_total + v_n;
      -- A refresh always moves until past today, so 0 means nothing changed: stop rather than spin.
      exit when v_n = 0 or clock_timestamp() - v_start > p_budget;
    end loop;
    while t.obligation_refresh_after is not null and clock_timestamp() - v_start <= p_budget loop
      v_ids := array(select o.id from public.obligation o
                     where o.tenant_id = t.id and o.deleted_at is null and o.id > t.obligation_refresh_after
                     order by o.id limit p_batch);
      v_total := v_total + private.refresh_obligation_state(v_ids, p_now);
      t.obligation_refresh_after := case when cardinality(v_ids) = p_batch then v_ids[p_batch] end;
      update public.tenant set obligation_refresh_after = t.obligation_refresh_after where id = t.id;
    end loop;
  end loop;
  return v_total;
end;
$$;
revoke all on function private.refresh_obligation_state(uuid[], timestamptz),
  private.refresh_due_obligation_states(timestamptz, integer, interval) from public, anon, authenticated;

-- Event side, same transaction as the change, for every writer. Statement level: one refresh per statement.
-- On update, only rows whose due date, active flag or deletion changed: the refresh's own update changes
-- none of them. A statement trigger fires even for zero rows, so an empty set must stop here, or the
-- refresh's own (empty) update would fire it again without end.
create function private.refresh_changed_obligation_state()
returns trigger language plpgsql security definer set search_path = '' as $$
declare
  v_ids uuid[];
begin
  if tg_op = 'INSERT' then
    v_ids := array(select n.id from new_rows n);
  else
    v_ids := array(
      select n.id from new_rows n join old_rows o on o.id = n.id
      where (o.next_due_date, o.is_active, o.deleted_at) is distinct from (n.next_due_date, n.is_active, n.deleted_at));
  end if;
  if cardinality(v_ids) > 0 then
    perform private.refresh_obligation_state(v_ids);
  end if;
  return null;
end;
$$;
-- Retire, reopen, any status change or soft delete of the asset: its obligations pause or resume.
create function private.refresh_asset_obligation_state()
returns trigger language plpgsql security definer set search_path = '' as $$
begin
  perform private.refresh_obligation_state(array(
    select o.id from public.obligation o where o.tenant_id = new.tenant_id and o.asset_id = new.id and o.deleted_at is null));
  return null;
end;
$$;
revoke all on function private.refresh_changed_obligation_state(), private.refresh_asset_obligation_state()
  from public, anon, authenticated;

create trigger refresh_obligation_state_insert after insert on public.obligation
  referencing new table as new_rows for each statement execute function private.refresh_changed_obligation_state();
create trigger refresh_obligation_state_update after update on public.obligation
  referencing old table as old_rows new table as new_rows for each statement
  execute function private.refresh_changed_obligation_state();
create trigger refresh_obligation_state after update of status, deleted_at on public.asset
  for each row when (old.status is distinct from new.status or old.deleted_at is distinct from new.deleted_at)
  execute function private.refresh_asset_obligation_state();

-- N or time zone changed: queue the whole tenant for the job.
create function private.queue_obligation_refresh()
returns trigger language plpgsql set search_path = '' as $$
begin
  new.obligation_refresh_after := '00000000-0000-0000-0000-000000000000';
  return new;
end;
$$;
revoke all on function private.queue_obligation_refresh() from public, anon, authenticated;
create trigger queue_obligation_refresh before update of obligation_due_soon_days, time_zone on public.tenant
  for each row when (old.obligation_due_soon_days is distinct from new.obligation_due_soon_days
                     or old.time_zone is distinct from new.time_zone)
  execute function private.queue_obligation_refresh();

-- The 4.2 settings function with one more setting, last and optional (null keeps it): old calls still work.
drop function public.update_tenant_settings(text, text, text, text, smallint, text[], smallint);
create function public.update_tenant_settings(
  p_currency_code            text,
  p_locale                   text,
  p_time_zone                text,
  p_date_format              text,
  p_fiscal_year_start_month  smallint,
  p_required_asset_fields    text[],
  p_coverage_expiring_days   smallint default null,
  p_obligation_due_soon_days smallint default null
)
returns void language plpgsql security definer set search_path = '' as $$
declare
  v_tenant_id uuid := private.current_tenant_id();
  v_old       jsonb;
  v_new       jsonb;
begin
  if v_tenant_id is null
     or not private.has_permission('tenant_settings', 'manage')
     or not private.tenant_can_write() then
    raise exception 'not allowed to change tenant settings' using errcode = '42501';
  end if;

  if not exists (select 1 from pg_catalog.pg_timezone_names where name = p_time_zone) then
    raise exception 'unknown time zone: %', p_time_zone using errcode = '22023';
  end if;

  select to_jsonb(t) into v_old from public.tenant t where t.id = v_tenant_id;

  update public.tenant set
    currency_code            = p_currency_code,
    locale                   = p_locale,
    time_zone                = p_time_zone,
    date_format              = p_date_format,
    fiscal_year_start_month  = p_fiscal_year_start_month,
    required_asset_fields    = coalesce(p_required_asset_fields, '{}'),
    coverage_expiring_days   = coalesce(p_coverage_expiring_days, coverage_expiring_days),
    obligation_due_soon_days = coalesce(p_obligation_due_soon_days, obligation_due_soon_days),
    updated_by               = auth.uid()
  where id = v_tenant_id
  returning to_jsonb(tenant.*) into v_new;

  -- Changed columns only, as audit_row() does (data-model-goal1.md §2.12). The refresh cursors are the
  -- system's, not settings.
  select jsonb_object_agg(o.key, o.value), jsonb_object_agg(o.key, v_new -> o.key)
    into v_old, v_new
  from jsonb_each(v_old) o
  where o.value is distinct from v_new -> o.key
    and o.key not in ('updated_at', 'updated_by', 'coverage_refresh_after', 'obligation_refresh_after');

  if v_old is null then
    return;  -- nothing changed, nothing to audit
  end if;

  insert into public.audit_log (tenant_id, category, actor_type, actor_user_id, action, table_name, record_id, old_data, new_data)
  values (v_tenant_id, 'data', 'user', auth.uid(), 'update', 'tenant', v_tenant_id, v_old, v_new);
  insert into private.outbox_event (tenant_id, event_type, aggregate_type, aggregate_id, payload)
  values (v_tenant_id, 'tenant.update', 'tenant', v_tenant_id, jsonb_build_object('old', v_old, 'new', v_new));
end;
$$;
revoke all on function public.update_tenant_settings(text, text, text, text, smallint, text[], smallint, smallint) from public, anon;
grant execute on function public.update_tenant_settings(text, text, text, text, smallint, text[], smallint, smallint) to authenticated;

-- No backfill: the table is new. Schedule the job (pg_cron is on since 4.4).
select cron.schedule('assetly_obligation_state', '*/15 * * * *', 'select private.refresh_due_obligation_states()');
