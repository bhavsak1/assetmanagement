-- Story 5.1: recurring obligations per asset and the next-due math. docs/data-model-goal5.md §1 and §3,
-- owner decisions O1, O5, O7 (28 Oct 2026); OQ-03 decided (both anchors per rule). 1.4 RLS pattern on the
-- catalog domain obligation (1.2 seed, 1.6 grid): no new domain. Row scope is 6.1.

-- interval_count units as an interval. Months and years clamp to month end (31 Jan + 1 month = 28 Feb).
create function private.obligation_step(p_count integer, p_unit text)
returns interval language sql immutable set search_path = '' as $$
  select case p_unit when 'day' then make_interval(days => p_count)
                     when 'week' then make_interval(weeks => p_count)
                     when 'month' then make_interval(months => p_count)
                     when 'year' then make_interval(years => p_count) end;
$$;

-- §3. p_done_on null: insert or rule edit. p_done_on set: a completion (5.2 complete_obligation).
-- Fixed due dates are always first_due + k × step (k >= 0), never the last due + step, so month ends do not
-- drift. O5: a fixed completion moves to the first slot after the later of the done date and the current due.
create function private.obligation_next_due(p_anchor text, p_count integer, p_unit text, p_first_due date,
                                            p_last_done date, p_current_due date default null,
                                            p_done_on date default null)
returns date language plpgsql immutable set search_path = '' as $$
declare
  v_step  interval := private.obligation_step(p_count, p_unit);
  v_after date;
  k       integer;
begin
  if p_done_on is null and p_last_done is null then
    return p_first_due;
  end if;
  if p_anchor = 'completion' then
    return (coalesce(p_done_on, p_last_done) + v_step)::date;
  end if;
  v_after := case when p_done_on is null then p_last_done else greatest(p_done_on, p_current_due) end;
  -- Estimate k from the step's length in days, then step to the exact first slot after v_after.
  k := greatest(0, floor((v_after - p_first_due) / (extract(epoch from v_step) / 86400))::integer - 1);
  while (p_first_due + v_step * k)::date <= v_after loop
    k := k + 1;
  end loop;
  while k > 0 and (p_first_due + v_step * (k - 1))::date > v_after loop
    k := k - 1;
  end loop;
  return (p_first_due + v_step * k)::date;
end;
$$;
revoke all on function private.obligation_step(integer, text),
  private.obligation_next_due(text, integer, text, date, date, date, date) from public, anon, authenticated;

create table public.obligation (
  id              uuid primary key default gen_random_uuid(),
  tenant_id       uuid not null references public.tenant (id),
  asset_id        uuid not null,
  name            text not null check (length(btrim(name)) between 1 and 80),
  -- O1: system codes; the tenant's own words go in name.
  obligation_type text not null check (obligation_type in ('service', 'calibration', 'inspection', 'certificate')),
  interval_count  smallint not null check (interval_count between 1 and 999),
  interval_unit   text not null check (interval_unit in ('day', 'week', 'month', 'year')),
  anchor          text not null check (anchor in ('completion', 'fixed')),
  first_due_date  date not null,
  last_done_date  date null,
  next_due_date   date not null,
  -- Kept by private.refresh_obligation_state (5_1_obligation_state) only.
  due_state       text not null default 'scheduled' check (due_state in ('scheduled', 'due_soon', 'overdue', 'paused')),
  due_state_until date null,
  is_active       boolean not null default true,
  notes           text null check (length(notes) <= 2000),
  created_at      timestamptz not null default now(),
  updated_at      timestamptz not null default now(),
  created_by      uuid null references public.user_profile (id),
  updated_by      uuid null references public.user_profile (id),
  deleted_at      timestamptz null,
  unique (tenant_id, id),
  foreign key (tenant_id, asset_id) references public.asset (tenant_id, id)
);

create unique index obligation_name_uq on public.obligation (tenant_id, asset_id, lower(btrim(name))) where deleted_at is null;
-- Maintenance tabs (by due) and Dashboard counts; asset detail; the job.
create index obligation_state_idx on public.obligation (tenant_id, due_state, next_due_date, id) where deleted_at is null;
create index obligation_asset_idx on public.obligation (tenant_id, asset_id) where deleted_at is null;
create index obligation_until_idx on public.obligation (tenant_id, due_state_until)
  where due_state_until is not null and deleted_at is null;

-- New rows go on live assets. next_due_date follows the rule on insert and on a rule edit (§3). A
-- completion (5.2) sets last_done_date and next_due_date itself and touches no rule column.
create function private.set_obligation_next_due()
returns trigger language plpgsql security definer set search_path = '' as $$
begin
  if tg_op = 'INSERT' then
    new.name := btrim(new.name);
    if not exists (select 1 from public.asset a where a.tenant_id = new.tenant_id and a.id = new.asset_id and a.deleted_at is null) then
      raise exception 'asset_id: asset is deleted or not found' using errcode = '23514';
    end if;
  end if;
  new.next_due_date := private.obligation_next_due(new.anchor, new.interval_count, new.interval_unit,
                                                   new.first_due_date, new.last_done_date);
  return new;
end;
$$;
revoke all on function private.set_obligation_next_due() from public, anon, authenticated;

create trigger set_obligation_next_due before insert or update of anchor, interval_count, interval_unit, first_due_date
  on public.obligation for each row execute function private.set_obligation_next_due();
-- O7: removing an obligation edits it (no delete operation on the domain).
create trigger check_soft_delete before update of deleted_at on public.obligation
  for each row execute function private.check_soft_delete('obligation', 'update');
-- A state refresh is not an edit (as 4.4 C12): updated_at stays, no audit row or obligation.updated event.
create trigger set_updated_at before update on public.obligation
  for each row when ((to_jsonb(old) - '{due_state,due_state_until}'::text[])
                     is distinct from (to_jsonb(new) - '{due_state,due_state_until}'::text[]))
  execute function private.set_updated_at();
create trigger audit after insert or delete on public.obligation
  for each row execute function private.audit_row('data');
create trigger audit_update after update on public.obligation
  for each row when ((to_jsonb(old) - '{due_state,due_state_until}'::text[])
                     is distinct from (to_jsonb(new) - '{due_state,due_state_until}'::text[]))
  execute function private.audit_row('data');

alter table public.obligation enable row level security;

create policy obligation_select on public.obligation
  for select to authenticated
  using (tenant_id = (select private.current_tenant_id())
         and (select private.has_permission('obligation', 'view')));
create policy obligation_insert on public.obligation
  for insert to authenticated
  with check (tenant_id = (select private.current_tenant_id())
              and (select private.has_permission('obligation', 'create'))
              and (select private.tenant_can_write()));
create policy obligation_update on public.obligation
  for update to authenticated
  using (tenant_id = (select private.current_tenant_id())
         and (select private.has_permission('obligation', 'update'))
         and (select private.tenant_can_write()))
  with check (tenant_id = (select private.current_tenant_id())
              and (select private.has_permission('obligation', 'update'))
              and (select private.tenant_can_write()));

-- Column grants: next due and the state are derived; last done is history on insert, then 5.2's action only.
revoke all on public.obligation from anon, authenticated;
grant select on public.obligation to authenticated;
grant insert (id, tenant_id, asset_id, name, obligation_type, interval_count, interval_unit, anchor,
              first_due_date, last_done_date, is_active, notes) on public.obligation to authenticated;
grant update (name, obligation_type, interval_count, interval_unit, anchor, first_due_date, is_active, notes,
              deleted_at) on public.obligation to authenticated;
