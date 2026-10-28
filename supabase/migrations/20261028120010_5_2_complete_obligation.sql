-- Story 5.2: record and undo a completion. Actions, not table writes (CLAUDE.md §7.8). data-model-goal5.md
-- §12.3 and §12.4, owner decisions S2 to S6 and O5 (28 Oct 2026).
-- OWNER REVIEW (CLAUDE.md §9): two security definer functions.
-- Invariant both keep: obligation.last_done_date = the later of its baseline (the value before any record,
-- kept on the first record as prev_last_done_date) and the latest live record's done_on. So an undo of any
-- record, latest or not, puts the right date back without a replay.
-- The 5.1 statement trigger on obligation refreshes the stored due state in the same statement, and the audit
-- triggers write the audit rows and their outbox events. Each action adds one event of its own.
-- 6.1 adds a set-form scope clause to the obligation lookups.

create function public.complete_obligation(
  p_obligation_id      uuid,
  p_done_on            date,
  p_notes              text default null,
  p_cost               numeric default null,
  p_currency           text default null,
  p_outcome            text default null,
  p_vendor_id          uuid default null,
  p_done_by            uuid default null,
  p_certificate_expiry date default null)
returns uuid language plpgsql security definer set search_path = '' as $$
declare
  v_tenant_id uuid := private.current_tenant_id();
  v_today     date := private.tenant_today();
  o           public.obligation;
  v_paused    boolean;
  v_advance   boolean;
  v_id        uuid;
begin
  -- S5: the action's own domain.
  if v_tenant_id is null or not private.has_permission('obligation', 'complete') or not private.tenant_can_write() then
    raise exception 'not allowed to complete obligation' using errcode = '42501';
  end if;

  -- Locked: two completions of one obligation queue, and the second sees the first's dates.
  select ob.* into o from public.obligation ob
  where ob.tenant_id = v_tenant_id and ob.id = p_obligation_id and ob.deleted_at is null
  for update;
  if not found then
    raise exception 'obligation not found' using errcode = 'P0002';
  end if;
  -- The §5 paused rule, read from the rows, not from the stored state.
  select not o.is_active or a.deleted_at is not null or a.status in ('inactive', 'disposed') into v_paused
  from public.asset a where a.tenant_id = v_tenant_id and a.id = o.asset_id;
  if v_paused then
    raise exception 'a paused obligation cannot be completed' using errcode = '22023';
  end if;

  -- S3: not in the future, at most 366 days back (catches a wrong year). Older history comes by import.
  if p_done_on is null then
    raise exception 'done_on is required' using errcode = '23502';
  end if;
  if p_done_on > v_today or p_done_on < v_today - 366 then
    raise exception 'done_on must be within the last 366 days and not in the future' using errcode = '22023';
  end if;

  -- S2: the latest date wins; a record dated before the last completion is history only.
  v_advance := o.last_done_date is null or p_done_on >= o.last_done_date;

  -- The insert trigger checks the vendor, the person and the cost permission (no silent drop of a cost).
  insert into public.service_record (tenant_id, obligation_id, asset_id, done_on, done_by_user_id, vendor_id, outcome,
                                     certificate_expiry, notes, cost_amount, cost_currency, advanced, prev_last_done_date)
  values (v_tenant_id, o.id, o.asset_id, p_done_on,
          -- S1: me by default; a contractor job may name only the vendor.
          case when p_vendor_id is null then coalesce(p_done_by, auth.uid()) else p_done_by end,
          p_vendor_id, p_outcome, p_certificate_expiry, p_notes, p_cost,
          case when p_cost is not null then coalesce(upper(nullif(btrim(p_currency), '')),
                                                     (select t.currency_code from public.tenant t where t.id = v_tenant_id)) end,
          v_advance, o.last_done_date)
  returning id into v_id;

  if v_advance then
    update public.obligation
    set last_done_date = p_done_on,
        next_due_date = private.obligation_next_due(o.anchor, o.interval_count, o.interval_unit, o.first_due_date,
                                                    o.last_done_date, o.next_due_date, p_done_on),
        updated_by = auth.uid()
    where tenant_id = v_tenant_id and id = o.id
    returning next_due_date into o.next_due_date;
  end if;

  -- No cost in a payload: events reach systems that hold no service_values.
  insert into private.outbox_event (tenant_id, event_type, aggregate_type, aggregate_id, payload)
  values (v_tenant_id, 'obligation.completed', 'obligation', o.id,
          jsonb_build_object('asset_id', o.asset_id, 'service_record_id', v_id, 'done_on', p_done_on,
                             'outcome', p_outcome, 'next_due_date', o.next_due_date, 'advanced', v_advance));
  return v_id;
end;
$$;
revoke all on function public.complete_obligation(uuid, date, text, numeric, text, text, uuid, uuid, date) from public, anon;
grant execute on function public.complete_obligation(uuid, date, text, numeric, text, text, uuid, uuid, date) to authenticated;

-- S4: soft-deletes a record and puts last_done_date back per the invariant. When it moves, next due is
-- recomputed by the insert rule (§3), which also follows a rule edit made since. A wrong date is fixed by
-- undo, then record again.
create function public.undo_completion(p_service_record_id uuid)
returns void language plpgsql security definer set search_path = '' as $$
declare
  v_tenant_id uuid := private.current_tenant_id();
  r           public.service_record;
  o           public.obligation;
  v_last      date;
begin
  if v_tenant_id is null or not private.has_permission('service_record', 'update') or not private.tenant_can_write() then
    raise exception 'not allowed to undo completion' using errcode = '42501';
  end if;

  select sr.* into r from public.service_record sr
  where sr.tenant_id = v_tenant_id and sr.id = p_service_record_id and sr.deleted_at is null;
  if not found then
    raise exception 'service record not found' using errcode = 'P0002';
  end if;
  -- Same lock as complete_obligation, so an undo and a completion of one obligation queue.
  select ob.* into o from public.obligation ob where ob.tenant_id = v_tenant_id and ob.id = r.obligation_id for update;

  update public.service_record set deleted_at = now(), updated_by = auth.uid()
  where tenant_id = v_tenant_id and id = r.id;

  -- The baseline is the first record's prev_last_done_date. last_done never drops below it, so it is also the
  -- least prev over all records, undone ones included (null if any is null). No tie on created_at in a transaction.
  select greatest((select case when bool_or(sr.prev_last_done_date is null) then null else min(sr.prev_last_done_date) end
                   from public.service_record sr
                   where sr.tenant_id = v_tenant_id and sr.obligation_id = o.id),
                  (select max(sr.done_on) from public.service_record sr
                   where sr.tenant_id = v_tenant_id and sr.obligation_id = o.id and sr.deleted_at is null))
  into v_last;

  if v_last is distinct from o.last_done_date then
    update public.obligation
    set last_done_date = v_last,
        next_due_date = private.obligation_next_due(o.anchor, o.interval_count, o.interval_unit, o.first_due_date, v_last),
        updated_by = auth.uid()
    where tenant_id = v_tenant_id and id = o.id
    returning next_due_date into o.next_due_date;
  end if;

  insert into private.outbox_event (tenant_id, event_type, aggregate_type, aggregate_id, payload)
  values (v_tenant_id, 'obligation.completion_undone', 'obligation', o.id,
          jsonb_build_object('asset_id', o.asset_id, 'service_record_id', r.id, 'done_on', r.done_on,
                             'next_due_date', o.next_due_date));
end;
$$;
revoke all on function public.undo_completion(uuid) from public, anon;
grant execute on function public.undo_completion(uuid) to authenticated;
