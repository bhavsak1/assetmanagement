-- Story 6.1: row scope on every surface that shows or changes asset data (data-model-goal6.md §4 to §6).
-- OWNER REVIEW (CLAUDE.md §9): RLS policies, security definer functions, the storage upload check.
-- Each view and function below is its earlier body with one scope clause added; nothing else changes.
-- Reads: ((select private.scope_all(d, o)) or <asset id> in (select private.scope_asset_ids(d, o))), the grant
-- being the row's own domain (S2). Writes of a new row: private.in_scope(d, o, location, category) (S6).
-- Invoker functions over these views and tables (list_assets, count_assets, maintenance, dashboard and
-- location counts, asset_coverage, service_history, the attachment lists) get the scope with no change.

-- Views (owner-run, so they repeat the clause themselves). Same columns as before.
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
    and a.deleted_at is null
    and ((select private.scope_all('asset_core', 'view'))
         or a.location_id = any ((select private.scope_locations('asset_core', 'view'))::uuid[])
         or a.category_id = any ((select private.scope_categories('asset_core', 'view'))::uuid[])
         or a.id in (select private.scope_mixed_ids('asset_core', 'view')));

create or replace view public.service_record_view as
  select r.id, r.tenant_id, r.obligation_id, r.asset_id, r.done_on, r.done_by_user_id, r.vendor_id, r.outcome,
         r.certificate_expiry, r.notes,
         case when (select private.has_permission('service_values', 'view')) then r.cost_amount end as cost_amount,
         case when (select private.has_permission('service_values', 'view')) then r.cost_currency end as cost_currency,
         r.advanced, r.created_at, r.updated_at, r.created_by, r.updated_by
  from public.service_record r
  where r.tenant_id = (select private.current_tenant_id())
    and (select private.has_permission('service_record', 'view'))
    and r.deleted_at is null
    and ((select private.scope_all('service_record', 'view')) or r.asset_id in (select private.scope_asset_ids('service_record', 'view')));

-- coverage_visible already reads asset_view (asset_core.view scope). S2: the contract grant's own scope too.
-- A contract with no live links stays visible to every coverage_contract.view holder (4.2 rule).
create or replace view public.coverage_view as
  select c.id, c.tenant_id, c.coverage_type, c.vendor_id, c.reference, c.start_date, c.end_date,
         case when (select private.has_permission('coverage_values', 'view')) then c.contract_value end as contract_value,
         case when (select private.has_permission('coverage_values', 'view')) then c.contract_currency end as contract_currency,
         c.renews_coverage_id, c.notes,
         case when c.start_date > (select private.tenant_today()) then 'future'
              when c.end_date < (select private.tenant_today()) then 'expired'
              when c.end_date < (select private.tenant_today())
                                + (select t.coverage_expiring_days from public.tenant t
                                   where t.id = (select private.current_tenant_id())) then 'expiring'
              else 'active' end as status,
         c.created_at, c.updated_at, c.created_by, c.updated_by
  from public.coverage c
  where c.tenant_id = (select private.current_tenant_id())
    and (select private.has_permission('coverage_contract', 'view'))
    and c.deleted_at is null
    and private.coverage_visible(c.id)
    and ((select private.scope_all('coverage_contract', 'view'))
         or not exists (select 1 from public.coverage_asset ca
                        where ca.tenant_id = c.tenant_id and ca.coverage_id = c.id and ca.deleted_at is null)
         or c.id in (select ca.coverage_id from public.coverage_asset ca
                     where ca.tenant_id = (select private.current_tenant_id()) and ca.deleted_at is null
                       and ca.asset_id in (select private.scope_asset_ids('coverage_contract', 'view'))));

-- Definer read helpers.
create or replace function private.asset_search_sql(p_term text)
returns text language sql immutable set search_path = '' as $$
  select format(
    'select a.id from public.asset a
     where a.tenant_id = (select private.current_tenant_id())
       and (select private.has_permission(''asset_core'', ''view''))
       and a.deleted_at is null
       and ((select private.scope_all(''asset_core'', ''view''))
         or a.location_id = any ((select private.scope_locations(''asset_core'', ''view''))::uuid[])
         or a.category_id = any ((select private.scope_categories(''asset_core'', ''view''))::uuid[])
         or a.id in (select private.scope_mixed_ids(''asset_core'', ''view'')))
       and (a.name ilike %1$L or a.tag ilike %1$L or a.serial_number ilike %1$L)',
    '%' || replace(replace(replace(p_term, '\', '\\'), '%', '\%'), '_', '\_') || '%');
$$;

-- The asset may be soft-deleted (history), so a row check, not the live-only id set.
create or replace function public.asset_history(p_asset_id uuid, p_before timestamptz default null, p_before_id uuid default null,
                                     p_limit integer default 50)
returns table (id uuid, occurred_at timestamptz, action text, actor_type text, actor_name text,
               old_data jsonb, new_data jsonb, hidden_fields text[])
language sql stable security definer set search_path = '' as $$
  with ctx as (
    select private.current_tenant_id() as tenant_id,
           private.has_permission('asset_core', 'view') as can_view,
           private.has_permission('asset_financials', 'view') as money,
           private.hidden_field_keys('asset') as hidden
  ), page as (
    select l.*, c.money, c.hidden
    from ctx c
    join public.audit_log l on l.tenant_id = c.tenant_id and l.table_name = 'asset' and l.record_id = p_asset_id
    where c.can_view
      and private.asset_in_scope('asset_core', 'view', p_asset_id)
      and (p_before is null
           or (l.occurred_at, l.id) < (p_before, coalesce(p_before_id, 'ffffffff-ffff-ffff-ffff-ffffffffffff')))
    order by l.occurred_at desc, l.id desc
    limit least(greatest(coalesce(p_limit, 50), 1), 100)
  )
  select r.id, r.occurred_at, r.action, r.actor_type,
         -- H1: name only, and only of an active member of this tenant (the rule 1.11 plans). Null: former member or system.
         (select p.display_name from public.user_profile p
          join public.tenant_membership m on m.user_id = p.id
          where p.id = r.actor_user_id and m.tenant_id = r.tenant_id and m.status = 'active' and m.deleted_at is null),
         private.mask_asset_data(r.old_data, r.money, r.hidden),
         private.mask_asset_data(r.new_data, r.money, r.hidden),
         -- What was removed and changed in this row, so the tab can say "hidden" instead of dropping it.
         array(select k from unnest(array['purchase_value', 'purchase_currency']) k
               where not r.money and coalesce(r.old_data -> k, 'null') is distinct from coalesce(r.new_data -> k, 'null')
               union all
               select 'custom.' || k from unnest(r.hidden) k
               where coalesce(r.old_data -> 'custom_values' -> k, 'null')
                     is distinct from coalesce(r.new_data -> 'custom_values' -> k, 'null'))
  from page r
  order by r.occurred_at desc, r.id desc;
$$;

create or replace function public.allowed_asset_statuses(p_asset_id uuid)
returns setof uuid language sql stable security definer set search_path = '' as $$
  select t.id
  from public.asset a
  cross join private.status_targets(a.tenant_id, a.category_id, a.status_id) t
  where a.tenant_id = private.current_tenant_id() and a.id = p_asset_id and a.deleted_at is null
    and private.has_permission('asset_core', 'view') and private.tenant_can_write()
    and private.in_scope('asset_lifecycle', case when a.status = 'disposed' then 'reopen' else 'execute' end,
                         a.location_id, a.category_id);
$$;

-- Actions (S6): the asset must be in the scope of the action's own grant. Out of scope reads as not found.
create or replace function public.transfer_asset(p_asset_id uuid, p_to_location_id uuid, p_reason text)
returns void language plpgsql security definer set search_path = '' as $$
declare
  v_tenant_id uuid := private.current_tenant_id();
  v_reason    text := nullif(btrim(p_reason), '');
  v_status    text;
  v_from      uuid;
  v_category  uuid;
begin
  if v_tenant_id is null or not private.has_permission('asset_core', 'view')
     or not private.has_permission('asset_lifecycle', 'execute') or not private.tenant_can_write() then
    raise exception 'not allowed to transfer asset' using errcode = '42501';
  end if;

  select a.status, a.location_id, a.category_id into v_status, v_from, v_category from public.asset a
  where a.tenant_id = v_tenant_id and a.id = p_asset_id and a.deleted_at is null
  for update;
  if not found or not private.in_scope('asset_lifecycle', 'execute', v_from, v_category) then
    raise exception 'asset not found' using errcode = 'P0002';
  end if;
  if v_status = 'disposed' then
    raise exception 'a disposed asset cannot be transferred' using errcode = '22023';
  end if;

  -- Locked so it cannot be deactivated before this commits. Another tenant's id reads as not found.
  perform 1 from public.location l
  where l.tenant_id = v_tenant_id and l.id = p_to_location_id and l.active and l.deleted_at is null
  for share;
  if not found then
    raise exception 'location is inactive or deleted' using errcode = '23514';
  end if;
  -- A scoped user moves assets only within their scope; cross-plant moves need a tenant-wide grant.
  if not private.in_scope('asset_lifecycle', 'execute', p_to_location_id, v_category) then
    raise exception 'location is outside your scope' using errcode = '42501';
  end if;
  if v_from is not distinct from p_to_location_id then
    raise exception 'asset is already at this location' using errcode = '22023';
  end if;
  if v_reason is null then
    raise exception 'a reason is required for a transfer' using errcode = '23502';
  end if;

  update public.asset
  set location_id = p_to_location_id, location_reason = v_reason, location_changed_at = now(), updated_by = auth.uid()
  where tenant_id = v_tenant_id and id = p_asset_id;

  insert into private.outbox_event (tenant_id, event_type, aggregate_type, aggregate_id, payload)
  values (v_tenant_id, 'asset.transferred', 'asset', p_asset_id,
          jsonb_build_object('from', v_from, 'to', p_to_location_id, 'reason', v_reason));
end;
$$;

create or replace function public.change_asset_status(p_asset_id uuid, p_status_id uuid, p_reason text default null)
returns void language plpgsql security definer set search_path = '' as $$
declare
  v_tenant_id uuid := private.current_tenant_id();
  v_reason    text := nullif(btrim(p_reason), '');
  v_asset     record;
  v_from      text;
  v_to        text;
begin
  if v_tenant_id is null or not private.has_permission('asset_core', 'view') or not private.tenant_can_write() then
    raise exception 'not allowed to change asset status' using errcode = '42501';
  end if;

  select a.category_id, a.location_id, a.status, a.status_id into v_asset from public.asset a
  where a.tenant_id = v_tenant_id and a.id = p_asset_id and a.deleted_at is null
  for update;
  if not found then
    raise exception 'asset not found' using errcode = 'P0002';
  end if;
  v_from := v_asset.status;

  if v_from = 'disposed' and not private.has_permission('asset_lifecycle', 'reopen') then
    raise exception 'not allowed to reopen a disposed asset' using errcode = '42501';
  elsif v_from <> 'disposed' and not private.has_permission('asset_lifecycle', 'execute') then
    raise exception 'not allowed to change asset status' using errcode = '42501';
  end if;
  -- After the permission check, so a missing grant still says so; out of scope reads as not found.
  if not private.in_scope('asset_lifecycle', case when v_from = 'disposed' then 'reopen' else 'execute' end,
                          v_asset.location_id, v_asset.category_id) then
    raise exception 'asset not found' using errcode = 'P0002';
  end if;

  select t.system_status into v_to
  from private.status_targets(v_tenant_id, v_asset.category_id, v_asset.status_id) t
  where t.id = p_status_id;
  if v_to is null then
    raise exception 'status cannot change from % to %', v_from,
      coalesce((select s.system_status from public.asset_status s where s.tenant_id = v_tenant_id and s.id = p_status_id),
               'this status')
      using errcode = '22023';
  end if;

  if v_reason is null and (v_to in ('inactive', 'disposed') or v_from = 'disposed') then
    raise exception 'a reason is required for this status change' using errcode = '23502';
  end if;

  update public.asset
  set status_id = p_status_id, status = v_to, status_reason = v_reason, status_changed_at = now(), updated_by = auth.uid()
  where tenant_id = v_tenant_id and id = p_asset_id;

  insert into private.outbox_event (tenant_id, event_type, aggregate_type, aggregate_id, payload)
  values (v_tenant_id, 'asset.status_changed', 'asset', p_asset_id,
          jsonb_build_object('from', v_from, 'to', v_to, 'from_id', v_asset.status_id, 'to_id', p_status_id,
                             'reason', v_reason));
end;
$$;

create or replace function public.complete_obligation(
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
  if not found or not private.asset_in_scope('obligation', 'complete', o.asset_id) then
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

create or replace function public.undo_completion(p_service_record_id uuid)
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
  if not found or not private.asset_in_scope('service_record', 'update', r.asset_id) then
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

-- Upload check (OWNER REVIEW: file access). Downloads go through the attachment rows' RLS below.
create or replace function private.can_upload_attachment(p_name text)
returns boolean language plpgsql stable security definer set search_path = '' as $$
declare
  v_uuid constant text := '[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}';
  v_id   uuid;
begin
  if p_name is null or p_name !~ ('^' || v_uuid || '/(asset|service_record)/' || v_uuid || '/' || v_uuid || '$') then
    return false;
  end if;
  v_id := split_part(p_name, '/', 3)::uuid;
  -- A null anywhere (no tenant claim) makes the whole result null, which the policy treats as refused.
  return split_part(p_name, '/', 1)::uuid = private.current_tenant_id()
     and private.tenant_can_write()
     and case split_part(p_name, '/', 2)
           -- A live asset of the current tenant, in asset_attachment.create scope.
           when 'asset' then private.has_permission('asset_attachment', 'create')
             and exists (select 1 from public.asset a
                         where a.tenant_id = private.current_tenant_id() and a.id = v_id and a.deleted_at is null)
             and private.asset_in_scope('asset_attachment', 'create', v_id)
           -- A live (not undone) service record of the current tenant, its asset in service_record.create scope.
           when 'service_record' then private.has_permission('service_record', 'create')
             and exists (select 1 from public.service_record r
                         where r.tenant_id = private.current_tenant_id() and r.id = v_id and r.deleted_at is null
                           and private.asset_in_scope('service_record', 'create', r.asset_id))
         end;
end;
$$;

-- Table policies: the 1.4 checks as before, plus the scope clause. The asset table uses its own columns (§8);
-- children use the id set, which holds live assets only, so a scoped user does not see the child rows of a
-- soft-deleted asset; tenant-wide users still do.

alter policy asset_select on public.asset
  using (tenant_id = (select private.current_tenant_id())
         and (select private.has_permission('asset_core', 'view'))
         and ((select private.scope_all('asset_core', 'view'))
         or location_id = any ((select private.scope_locations('asset_core', 'view'))::uuid[])
         or category_id = any ((select private.scope_categories('asset_core', 'view'))::uuid[])
         or id in (select private.scope_mixed_ids('asset_core', 'view'))));
-- A new row is not in the table yet: in_scope on its own location and category, once per row (writes are single rows).
alter policy asset_insert on public.asset
  with check (tenant_id = (select private.current_tenant_id())
              and (select private.has_permission('asset_core', 'create'))
              and (select private.tenant_can_write())
              and ((select private.scope_all('asset_core', 'create'))
                   or private.in_scope('asset_core', 'create', location_id, category_id)));
alter policy asset_update on public.asset
  using (tenant_id = (select private.current_tenant_id())
         and (select private.has_permission('asset_core', 'update'))
         and (select private.tenant_can_write())
         and ((select private.scope_all('asset_core', 'update'))
         or location_id = any ((select private.scope_locations('asset_core', 'update'))::uuid[])
         or category_id = any ((select private.scope_categories('asset_core', 'update'))::uuid[])
         or id in (select private.scope_mixed_ids('asset_core', 'update'))))
  with check (tenant_id = (select private.current_tenant_id())
              and (select private.has_permission('asset_core', 'update'))
              and (select private.tenant_can_write())
              and ((select private.scope_all('asset_core', 'update'))
                   or private.in_scope('asset_core', 'update', location_id, category_id)));

alter policy obligation_select on public.obligation
  using (tenant_id = (select private.current_tenant_id())
         and (select private.has_permission('obligation', 'view'))
         and ((select private.scope_all('obligation', 'view')) or asset_id in (select private.scope_asset_ids('obligation', 'view'))));
alter policy obligation_insert on public.obligation
  with check (tenant_id = (select private.current_tenant_id())
              and (select private.has_permission('obligation', 'create'))
              and (select private.tenant_can_write())
              and ((select private.scope_all('obligation', 'create')) or asset_id in (select private.scope_asset_ids('obligation', 'create'))));
alter policy obligation_update on public.obligation
  using (tenant_id = (select private.current_tenant_id())
         and (select private.has_permission('obligation', 'update'))
         and (select private.tenant_can_write())
         and ((select private.scope_all('obligation', 'update')) or asset_id in (select private.scope_asset_ids('obligation', 'update'))))
  with check (tenant_id = (select private.current_tenant_id())
              and (select private.has_permission('obligation', 'update'))
              and (select private.tenant_can_write())
              and ((select private.scope_all('obligation', 'update')) or asset_id in (select private.scope_asset_ids('obligation', 'update'))));

alter policy service_record_select on public.service_record
  using (tenant_id = (select private.current_tenant_id())
         and (select private.has_permission('service_record', 'view'))
         and ((select private.scope_all('service_record', 'view')) or asset_id in (select private.scope_asset_ids('service_record', 'view'))));
alter policy service_record_update on public.service_record
  using (tenant_id = (select private.current_tenant_id())
         and (select private.has_permission('service_record', 'update'))
         and (select private.tenant_can_write())
         and ((select private.scope_all('service_record', 'update')) or asset_id in (select private.scope_asset_ids('service_record', 'update'))))
  with check (tenant_id = (select private.current_tenant_id())
              and (select private.has_permission('service_record', 'update'))
              and (select private.tenant_can_write())
              and ((select private.scope_all('service_record', 'update')) or asset_id in (select private.scope_asset_ids('service_record', 'update'))));

alter policy coverage_asset_select on public.coverage_asset
  using (tenant_id = (select private.current_tenant_id())
         and (select private.has_permission('coverage_contract', 'view'))
         and exists (select 1 from public.asset_view av where av.id = asset_id)
         and ((select private.scope_all('coverage_contract', 'view')) or asset_id in (select private.scope_asset_ids('coverage_contract', 'view'))));
alter policy coverage_asset_insert on public.coverage_asset
  with check (tenant_id = (select private.current_tenant_id())
              and (select private.has_permission('coverage_contract', 'update'))
              and (select private.tenant_can_write())
              and exists (select 1 from public.asset_view av where av.id = asset_id)
              and private.coverage_visible(coverage_id)
              and ((select private.scope_all('coverage_contract', 'update')) or asset_id in (select private.scope_asset_ids('coverage_contract', 'update'))));
alter policy coverage_asset_update on public.coverage_asset
  using (tenant_id = (select private.current_tenant_id())
         and (select private.has_permission('coverage_contract', 'update'))
         and (select private.tenant_can_write())
         and exists (select 1 from public.asset_view av where av.id = asset_id)
         and ((select private.scope_all('coverage_contract', 'update')) or asset_id in (select private.scope_asset_ids('coverage_contract', 'update'))))
  with check (tenant_id = (select private.current_tenant_id())
              and (select private.has_permission('coverage_contract', 'update'))
              and (select private.tenant_can_write())
              and ((select private.scope_all('coverage_contract', 'update')) or asset_id in (select private.scope_asset_ids('coverage_contract', 'update'))));

-- The storage read policy goes through these rows, so downloads and signed URLs follow the scope too.
alter policy asset_attachment_select on public.asset_attachment
  using (tenant_id = (select private.current_tenant_id())
         and (select private.has_permission('asset_attachment', 'view'))
         and ((select private.scope_all('asset_attachment', 'view')) or asset_id in (select private.scope_asset_ids('asset_attachment', 'view'))));
alter policy asset_attachment_insert on public.asset_attachment
  with check (tenant_id = (select private.current_tenant_id())
              and (select private.has_permission('asset_attachment', 'create'))
              and (select private.tenant_can_write())
              and ((select private.scope_all('asset_attachment', 'create')) or asset_id in (select private.scope_asset_ids('asset_attachment', 'create'))));
alter policy asset_attachment_update on public.asset_attachment
  using (tenant_id = (select private.current_tenant_id())
         and (select private.has_permission('asset_attachment', 'delete'))
         and (select private.tenant_can_write())
         and ((select private.scope_all('asset_attachment', 'delete')) or asset_id in (select private.scope_asset_ids('asset_attachment', 'delete'))))
  with check (tenant_id = (select private.current_tenant_id())
              and (select private.has_permission('asset_attachment', 'delete'))
              and (select private.tenant_can_write())
              and ((select private.scope_all('asset_attachment', 'delete')) or asset_id in (select private.scope_asset_ids('asset_attachment', 'delete'))));

-- A service record file follows its record's asset.
alter policy service_record_attachment_select on public.service_record_attachment
  using (tenant_id = (select private.current_tenant_id())
         and (select private.has_permission('service_record', 'view'))
         and ((select private.scope_all('service_record', 'view'))
              or service_record_id in (select r.id from public.service_record r
                                       where r.asset_id in (select private.scope_asset_ids('service_record', 'view')))));
alter policy service_record_attachment_insert on public.service_record_attachment
  with check (tenant_id = (select private.current_tenant_id())
              and (select private.has_permission('service_record', 'create'))
              and (select private.tenant_can_write())
              and ((select private.scope_all('service_record', 'create'))
                   or service_record_id in (select r.id from public.service_record r
                                            where r.asset_id in (select private.scope_asset_ids('service_record', 'create')))));
alter policy service_record_attachment_update on public.service_record_attachment
  using (tenant_id = (select private.current_tenant_id())
         and (select private.has_permission('service_record', 'update'))
         and (select private.tenant_can_write())
         and ((select private.scope_all('service_record', 'update'))
              or service_record_id in (select r.id from public.service_record r
                                       where r.asset_id in (select private.scope_asset_ids('service_record', 'update')))))
  with check (tenant_id = (select private.current_tenant_id())
              and (select private.has_permission('service_record', 'update'))
              and (select private.tenant_can_write())
              and ((select private.scope_all('service_record', 'update'))
                   or service_record_id in (select r.id from public.service_record r
                                            where r.asset_id in (select private.scope_asset_ids('service_record', 'update')))));
