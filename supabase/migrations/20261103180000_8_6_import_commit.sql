-- Story 8.6: idempotent commit and batch undo. docs/data-model-goal8.md §18 (leans taken with the owner away).
-- OWNER REVIEW (CLAUDE.md §9): import_commit (security invoker) and its definer step import_commit_finish;
-- import_undo (security definer, action domain import_undo.undo).
-- Commit inserts as the caller, so RLS (asset_core.create and its 6.1 scope, coverage rights) and every asset
-- trigger (tag, status, values, 6.2 money checks, audit and outbox) apply as for the asset form. It re-runs
-- import_validate in the same transaction (V2) and inserts only the payload that run wrote.
-- Idempotency key: a committed asset takes the id of its staged row (K3), so a second commit cannot insert
-- the same row twice even if the status check were bypassed.

alter table public.import_row
  add column undone_at    timestamptz null,
  add column undo_blocked text null check (undo_blocked in ('changed', 'gone', 'has_children', 'out_of_scope'));
alter table public.import_batch
  add column committed_at timestamptz null,
  add column committed_by uuid null references public.user_profile (id),
  add column undone_at    timestamptz null,
  add column undone_by    uuid null references public.user_profile (id),
  add column outcome      jsonb null check (outcome is null or jsonb_typeof(outcome) = 'object');
alter table public.import_batch drop constraint import_batch_status_check;
alter table public.import_batch add constraint import_batch_status_check
  check (status in ('staged', 'mapped', 'validated', 'committed', 'undone', 'expired'));

-- 4.4 again, one line changed: a commit links up to 20,000 assets in one statement, and "= any (array)"
-- then compared every asset row with every id (minutes). As a semi-join it is one index lookup per id.
create or replace function private.refresh_coverage_state(p_asset_ids uuid[], p_now timestamptz default now())
returns integer language sql volatile security definer set search_path = '' as $$
  with a as (
    select a.id, a.tenant_id, (p_now at time zone t.time_zone)::date as today, t.coverage_expiring_days as n
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

-- The warranty line of a committed row: a fixed id from the row id, so undo finds it without a link table.
create function private.import_coverage_id(p_row_id uuid)
returns uuid language sql immutable set search_path = '' as $$
  select md5(p_row_id::text || ':coverage')::uuid;
$$;
grant execute on function private.import_coverage_id(uuid) to authenticated;

-- Last step of a commit (definer: users have no update right on import tables). It proves the check ran in
-- this transaction for this user and that every ok and warning row now has its asset, then marks the batch.
create function private.import_commit_finish(p_batch_id uuid)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare
  v_batch   public.import_batch;
  v_outcome jsonb;
  v_id      uuid;
begin
  if not private.has_permission('excel_import', 'commit') or not private.tenant_can_write() then
    raise exception 'not allowed' using errcode = '42501';
  end if;
  select * into v_batch from public.import_batch
  where id = p_batch_id and tenant_id = private.current_tenant_id() for update;
  if not found then
    raise exception 'batch not found' using errcode = 'P0002';
  end if;
  if v_batch.status <> 'validated' or (v_batch.summary ->> 'validated_at')::timestamptz <> now()
     or v_batch.summary ->> 'as_user' is distinct from auth.uid()::text then
    raise exception 'commit: check the batch in this transaction first' using errcode = '22023';
  end if;
  -- One primary-key probe per row: a join here was planned on stale statistics and grew quadratic.
  for v_id in select r.id from public.import_row r
              where r.tenant_id = v_batch.tenant_id and r.batch_id = v_batch.id and r.result <> 'error' loop
    if not exists (select 1 from public.asset a where a.id = v_id) then
      raise exception 'commit: a row has no asset' using errcode = '22023';
    end if;
  end loop;

  v_outcome := jsonb_build_object(
    'created_assets', (v_batch.summary ->> 'create_assets')::int,
    'created_coverages', (v_batch.summary ->> 'create_coverages')::int,
    'skipped', (v_batch.summary ->> 'skip')::int,
    'committed_at', now(), 'as_user', auth.uid());
  update public.import_batch
  set status = 'committed', committed_at = now(), committed_by = auth.uid(), outcome = v_outcome, updated_by = auth.uid()
  where id = v_batch.id;
  return v_outcome;
end;
$$;
revoke all on function private.import_commit_finish(uuid) from public, anon;
grant execute on function private.import_commit_finish(uuid) to authenticated;

create function public.import_commit(p_batch_id uuid)
returns jsonb language plpgsql security invoker set search_path = '' as $$
declare
  v_batch public.import_batch;
begin
  if not private.has_permission('excel_import', 'commit') or not private.tenant_can_write() then
    raise exception 'not allowed' using errcode = '42501';
  end if;
  select * into v_batch from public.import_batch where id = p_batch_id and tenant_id = private.current_tenant_id();
  if not found then
    raise exception 'batch not found' using errcode = 'P0002';
  end if;
  -- K2: a committed (or undone) batch returns what its commit did, and creates nothing.
  if v_batch.status in ('committed', 'undone') then
    return v_batch.outcome;
  end if;
  -- V2: check again in this transaction; import_validate locks the batch until the end of it. A commit that
  -- waited on that lock finds the batch committed and returns its outcome too.
  begin
    perform public.import_validate(p_batch_id);
  exception when invalid_parameter_value then
    select * into v_batch from public.import_batch where id = p_batch_id;
    if v_batch.status in ('committed', 'undone') then
      return v_batch.outcome;
    end if;
    raise;
  end;
  -- K8. shortcut: the asset triggers run per row (about 10 ms each); lift this when they move to statement level.
  if (select (summary ->> 'create_assets')::int from public.import_batch where id = p_batch_id) > 2000 then
    raise exception 'commit: more than 2000 rows; split the file' using errcode = '54000';
  end if;

  -- Only rows the check passed (V3), from the payload it wrote. Blank tag and status are filled by the triggers.
  insert into public.asset (id, tenant_id, tag, name, category_id, location_id, status_id, criticality, quantity,
    parent_asset_id, serial_number, manufacturer, model, purchase_date, purchase_value, purchase_currency,
    in_service_date, oem_vendor_id, om_vendor_id, custom_values)
  select r.id, r.tenant_id, a.tag, a.name, a.category_id, a.location_id, a.status_id, a.criticality, coalesce(a.quantity, 1),
    a.parent_asset_id, a.serial_number, a.manufacturer, a.model, a.purchase_date, a.purchase_value, a.purchase_currency,
    a.in_service_date, a.oem_vendor_id, a.om_vendor_id, coalesce(a.custom_values, '{}')
  from public.import_row r
  cross join lateral jsonb_populate_record(null::public.asset, r.payload -> 'asset') a
  where r.tenant_id = v_batch.tenant_id and r.batch_id = v_batch.id and r.result <> 'error'
  order by r.row_number;  -- generated tags follow the file order

  -- M9: one warranty line per row, as create_asset_with_warranty (4.5) writes it.
  insert into public.coverage (id, tenant_id, coverage_type, vendor_id, start_date, end_date)
  select private.import_coverage_id(r.id), r.tenant_id, c.coverage_type, c.vendor_id, c.start_date, c.end_date
  from public.import_row r
  cross join lateral jsonb_populate_record(null::public.coverage, r.payload -> 'coverage') c
  where r.tenant_id = v_batch.tenant_id and r.batch_id = v_batch.id and r.result <> 'error' and r.payload ? 'coverage';
  insert into public.coverage_asset (tenant_id, coverage_id, asset_id)
  select r.tenant_id, private.import_coverage_id(r.id), r.id
  from public.import_row r
  where r.tenant_id = v_batch.tenant_id and r.batch_id = v_batch.id and r.result <> 'error' and r.payload ? 'coverage';

  return private.import_commit_finish(p_batch_id);
end;
$$;
revoke all on function public.import_commit(uuid) from public, anon;
grant execute on function public.import_commit(uuid) to authenticated;

-- K5 to K7: soft-delete what this batch created, row by row, unless the row was changed or moved on since.
-- Definer, as other actions (transfer_asset): it checks its own action domain, import_undo.undo.
-- Runs again on an undone batch to retry rows that were blocked.
create function public.import_undo(p_batch_id uuid)
returns jsonb language plpgsql security definer set search_path = '' set client_min_messages = warning as $$
declare
  v_batch   public.import_batch;
  v_all     boolean := private.scope_all('asset_core', 'update');
  v_outcome jsonb;
begin
  if not private.has_permission('import_undo', 'undo') or not private.tenant_can_write() then
    raise exception 'not allowed' using errcode = '42501';
  end if;
  select * into v_batch from public.import_batch
  where id = p_batch_id and tenant_id = private.current_tenant_id() for update;
  if not found then
    raise exception 'batch not found' using errcode = 'P0002';
  end if;
  if v_batch.status not in ('committed', 'undone') then
    raise exception 'batch is %', v_batch.status using errcode = '22023';
  end if;

  drop table if exists pg_temp.import_u;
  create temp table import_u on commit drop as
  select r.id, c.id as coverage_id, a.location_id, a.category_id,
         case when a.id is null or a.deleted_at is not null or (c.id is null) <> not (r.payload ? 'coverage')
                   or c.deleted_at is not null then 'gone'
              -- set_updated_at moves updated_at on any edit; the commit itself left it at committed_at.
              when a.updated_at > v_batch.committed_at or c.updated_at > v_batch.committed_at then 'changed'
              when exists (select 1 from public.asset k where k.tenant_id = r.tenant_id and k.parent_asset_id = r.id
                           and k.deleted_at is null) then 'has_children'
         end as blocked
  from public.import_row r
  left join public.asset a on a.tenant_id = r.tenant_id and a.id = r.id
  left join public.coverage c on c.tenant_id = r.tenant_id and c.id = private.import_coverage_id(r.id)
  where r.tenant_id = v_batch.tenant_id and r.batch_id = v_batch.id and r.result <> 'error' and r.undone_at is null;
  analyze pg_temp.import_u;

  -- 6.1: only assets the caller may update, per distinct location and category.
  update pg_temp.import_u u set blocked = 'out_of_scope'
  from (select p.location_id, p.category_id
        from (select distinct location_id, category_id from pg_temp.import_u where blocked is null) p
        where not private.in_scope('asset_core', 'update', p.location_id, p.category_id)) s
  where not v_all and u.blocked is null
    and u.category_id = s.category_id and u.location_id is not distinct from s.location_id;

  update public.coverage_asset set deleted_at = now(), updated_by = auth.uid()
  where tenant_id = v_batch.tenant_id and deleted_at is null
    and coverage_id in (select coverage_id from pg_temp.import_u where blocked is null and coverage_id is not null);
  update public.coverage set deleted_at = now(), updated_by = auth.uid()
  where tenant_id = v_batch.tenant_id
    and id in (select coverage_id from pg_temp.import_u where blocked is null and coverage_id is not null);
  update public.asset set deleted_at = now(), updated_by = auth.uid()
  where tenant_id = v_batch.tenant_id and id in (select id from pg_temp.import_u where blocked is null);

  update public.import_row r
  set undone_at = case when u.blocked is null then now() end, undo_blocked = u.blocked
  from pg_temp.import_u u
  where r.tenant_id = v_batch.tenant_id and r.batch_id = v_batch.id and r.id = u.id;

  select v_batch.outcome || jsonb_build_object(
      'undone', count(*) filter (where r.undone_at is not null),
      'blocked', count(*) filter (where r.undone_at is null),
      'blocked_by', coalesce((select jsonb_object_agg(b.undo_blocked, b.n)
                              from (select x.undo_blocked, count(*) as n from public.import_row x
                                    where x.tenant_id = v_batch.tenant_id and x.batch_id = v_batch.id
                                      and x.undo_blocked is not null and x.undone_at is null
                                    group by x.undo_blocked) b), '{}'),
      'undone_at', now(), 'undone_by', auth.uid())
  into v_outcome
  from public.import_row r
  where r.tenant_id = v_batch.tenant_id and r.batch_id = v_batch.id and r.result <> 'error';

  update public.import_batch
  set status = 'undone', undone_at = now(), undone_by = auth.uid(), outcome = v_outcome, updated_by = auth.uid()
  where id = v_batch.id;
  return v_outcome;
end;
$$;
revoke all on function public.import_undo(uuid) from public, anon;
grant execute on function public.import_undo(uuid) to authenticated;
