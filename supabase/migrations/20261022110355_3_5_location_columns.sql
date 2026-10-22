-- Story 3.5 (T1 a): the reason and time of the last transfer, like status_reason and
-- status_changed_at. The audit row of the transfer then holds from, to, reason, by and when,
-- so the Audit tab shows it with no change to asset_history. Set only by transfer_asset().
alter table public.asset
  add column location_reason text null,
  add column location_changed_at timestamptz null;

-- Readable, not writable: no insert or update grant (data-model-goal3.md §3).
grant select (location_reason, location_changed_at) on public.asset to authenticated;

-- Same view as 3_1_asset_view with the two columns added at the end (create or replace keeps
-- the existing column order).
create or replace view public.asset_view as
  select a.id, a.tenant_id, a.tag, a.name, a.category_id, a.location_id,
         a.status, a.status_reason, a.status_changed_at, a.quantity, a.parent_asset_id, a.criticality,
         a.serial_number, a.manufacturer, a.model, a.purchase_date,
         case when (select private.has_permission('asset_financials', 'view')) then a.purchase_value end as purchase_value,
         case when (select private.has_permission('asset_financials', 'view')) then a.purchase_currency end as purchase_currency,
         a.in_service_date,
         a.custom_values - (select private.hidden_field_keys('asset')) as custom_values,
         a.created_at, a.updated_at, a.created_by, a.updated_by,
         a.location_reason, a.location_changed_at
  from public.asset a
  where a.tenant_id = (select private.current_tenant_id())
    and (select private.has_permission('asset_core', 'view'))
    and a.deleted_at is null;
