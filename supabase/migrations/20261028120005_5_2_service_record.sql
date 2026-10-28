-- Story 5.2: service_record, one completed piece of work on an obligation. data-model-goal5.md §12.1, owner
-- decisions S1 to S8 (28 Oct 2026). 1.4 pattern on the catalog domain service_record (1.2 seed, 1.6 grid).
-- OWNER REVIEW (CLAUDE.md §9): RLS and the cost masking view.
-- No insert grant: rows come only from public.complete_obligation (5_2_complete_obligation). Users may
-- correct the free fields (S4); the date and the obligation never change (undo, then record again).
-- 6.1 adds one set-form scope clause on asset_id to select and update.

create table public.service_record (
  id                  uuid primary key default gen_random_uuid(),
  tenant_id           uuid not null references public.tenant (id),
  obligation_id       uuid not null,
  -- Copied from the obligation by the action, so the asset's history needs no join.
  asset_id            uuid not null,
  done_on             date not null,
  -- S1: who did it. A member, a contractor (vendor), or both.
  done_by_user_id     uuid null references public.user_profile (id),
  vendor_id           uuid null,
  -- S6: inspection and calibration result; null when not a pass or fail kind of job.
  outcome             text null check (outcome in ('pass', 'fail')),
  -- S7: stored and shown only.
  certificate_expiry  date null,
  notes               text null check (length(notes) <= 2000),
  -- Domain service_values (S8), masked in service_record_view. No conversion (CLAUDE.md §8).
  cost_amount         numeric(19, 4) null check (cost_amount >= 0),
  cost_currency       char(3) null check (cost_currency ~ '^[A-Z]{3}$'),
  -- S2, S4: system only. advanced = this record moved the obligation's dates; prev_last_done_date is what
  -- last_done_date was before, so an undo restores it exactly.
  advanced            boolean not null,
  prev_last_done_date date null,
  created_at          timestamptz not null default now(),
  updated_at          timestamptz not null default now(),
  created_by          uuid null default auth.uid() references public.user_profile (id),
  updated_by          uuid null references public.user_profile (id),
  deleted_at          timestamptz null,
  unique (tenant_id, id),
  check (cost_amount is null or cost_currency is not null),
  foreign key (tenant_id, obligation_id) references public.obligation (tenant_id, id),
  foreign key (tenant_id, asset_id) references public.asset (tenant_id, id),
  foreign key (tenant_id, vendor_id) references public.vendor (tenant_id, id)
);
-- The Service history tab; undo's "latest advanced" lookup.
create index service_record_asset_idx on public.service_record (tenant_id, asset_id, done_on desc, id) where deleted_at is null;
create index service_record_obligation_idx on public.service_record (tenant_id, obligation_id, done_on desc, id) where deleted_at is null;

-- Every writer (the action and corrections): the vendor is live and active in the tenant, the person is an
-- active member, and a cost change needs service_values (the 4.2 check_coverage rule). Only a changed vendor
-- or person is checked, so a vendor deactivated later does not block a note fix.
create function private.check_service_record()
returns trigger language plpgsql security definer set search_path = '' as $$
begin
  new.notes := nullif(btrim(new.notes), '');

  if new.vendor_id is not null and (tg_op = 'INSERT' or new.vendor_id is distinct from old.vendor_id)
     and not exists (select 1 from public.vendor v where v.tenant_id = new.tenant_id and v.id = new.vendor_id
                     and v.deleted_at is null and v.is_active) then
    raise exception 'vendor_id: vendor is inactive or not found' using errcode = '23514';
  end if;

  if new.done_by_user_id is not null and (tg_op = 'INSERT' or new.done_by_user_id is distinct from old.done_by_user_id)
     and not exists (select 1 from public.tenant_membership m where m.tenant_id = new.tenant_id
                     and m.user_id = new.done_by_user_id and m.status = 'active' and m.deleted_at is null) then
    raise exception 'done_by_user_id: not an active member of this tenant' using errcode = '23514';
  end if;

  if auth.uid() is not null
     and not (private.has_permission('service_values', 'update') and private.has_permission('service_values', 'view'))
     and (case when tg_op = 'INSERT' then new.cost_amount is not null or new.cost_currency is not null
               else (new.cost_amount, new.cost_currency) is distinct from (old.cost_amount, old.cost_currency) end) then
    raise exception 'no permission to change service cost' using errcode = '42501';
  end if;
  return new;
end;
$$;
revoke all on function private.check_service_record() from public, anon, authenticated;

create trigger check_service_record before insert or update on public.service_record
  for each row execute function private.check_service_record();
create trigger set_updated_at before update on public.service_record
  for each row execute function private.set_updated_at();
create trigger audit after insert or update or delete on public.service_record
  for each row execute function private.audit_row('data');

-- Soft-deleted (undone) rows stay readable as history; the view and the app filter them.
alter table public.service_record enable row level security;

create policy service_record_select on public.service_record
  for select to authenticated
  using (tenant_id = (select private.current_tenant_id())
         and (select private.has_permission('service_record', 'view')));
create policy service_record_update on public.service_record
  for update to authenticated
  using (tenant_id = (select private.current_tenant_id())
         and (select private.has_permission('service_record', 'update'))
         and (select private.tenant_can_write()))
  with check (tenant_id = (select private.current_tenant_id())
              and (select private.has_permission('service_record', 'update'))
              and (select private.tenant_can_write()));

-- The cost columns are not readable on the table, only through the view below.
revoke all on public.service_record from anon, authenticated;
grant select (id, tenant_id, obligation_id, asset_id, done_on, done_by_user_id, vendor_id, outcome,
              certificate_expiry, notes, advanced, prev_last_done_date, created_at, updated_at, created_by,
              updated_by, deleted_at) on public.service_record to authenticated;
grant update (done_by_user_id, vendor_id, outcome, certificate_expiry, notes, cost_amount, cost_currency, updated_by)
  on public.service_record to authenticated;

-- Live records with the cost masked unless the user holds service_values.view. Owner-run like coverage_view,
-- so it repeats the select policy's tenant and permission check itself.
create view public.service_record_view as
  select r.id, r.tenant_id, r.obligation_id, r.asset_id, r.done_on, r.done_by_user_id, r.vendor_id, r.outcome,
         r.certificate_expiry, r.notes,
         case when (select private.has_permission('service_values', 'view')) then r.cost_amount end as cost_amount,
         case when (select private.has_permission('service_values', 'view')) then r.cost_currency end as cost_currency,
         r.advanced, r.created_at, r.updated_at, r.created_by, r.updated_by
  from public.service_record r
  where r.tenant_id = (select private.current_tenant_id())
    and (select private.has_permission('service_record', 'view'))
    and r.deleted_at is null;
revoke all on public.service_record_view from public, anon, authenticated;
grant select on public.service_record_view to authenticated;

-- The Service history tab: one asset's live records, newest first, optionally one obligation. Invoker, so the
-- vendor name shows only with vendor_core.view and the obligation name only with obligation.view. No paging:
-- an asset has tens of records over years. 5.3's tenant-wide Completed list pages on its own.
create function public.service_history(p_asset_id uuid, p_obligation_id uuid default null)
returns table (id uuid, obligation_id uuid, obligation_name text, done_on date, outcome text,
               done_by_user_id uuid, done_by_name text, vendor_id uuid, vendor_name text,
               certificate_expiry date, notes text, cost_amount numeric, cost_currency text, advanced boolean)
language sql stable set search_path = '' as $$
  select r.id, r.obligation_id, o.name, r.done_on, r.outcome, r.done_by_user_id, private.member_name(r.done_by_user_id),
         r.vendor_id, v.name, r.certificate_expiry, r.notes, r.cost_amount, r.cost_currency::text, r.advanced
  from public.service_record_view r
  left join public.obligation o on o.tenant_id = r.tenant_id and o.id = r.obligation_id
  left join public.vendor v on v.tenant_id = r.tenant_id and v.id = r.vendor_id
  where r.asset_id = p_asset_id and (p_obligation_id is null or r.obligation_id = p_obligation_id)
  order by r.done_on desc, r.created_at desc, r.id
$$;
revoke all on function public.service_history(uuid, uuid) from public, anon;
grant execute on function public.service_history(uuid, uuid) to authenticated;
