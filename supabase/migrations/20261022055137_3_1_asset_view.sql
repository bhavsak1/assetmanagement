-- Story 3.1 (A6): the app reads assets only through this view. RLS cannot hide columns, so the
-- base table withholds purchase_value, purchase_currency and custom_values from users, and this
-- view returns them masked: money needs asset_financials.view, each custom key its field's domain.
-- Owner-run (not security_invoker) so it can read those columns; the where clause repeats the
-- base select policy. Live rows only, which also matches the partial list indexes (spike 1.7 F2).
-- 6.1 adds the scope clause here, in set form.
-- Not security_barrier on purpose: a barrier view is never flattened, so `order by name limit 50`
-- sorts the whole tenant (the spike's 196k-row read) and a tag lookup cannot use its index.
-- Masked columns stay safe either way: a filter on them sees the masked expression, never the raw
-- value. What the barrier would add is evaluation order for non-leakproof user functions, and API
-- users cannot create functions. Owner review item.
create view public.asset_view as
  select a.id, a.tenant_id, a.tag, a.name, a.category_id, a.location_id,
         a.status, a.status_reason, a.status_changed_at, a.quantity, a.parent_asset_id, a.criticality,
         a.serial_number, a.manufacturer, a.model, a.purchase_date,
         case when (select private.has_permission('asset_financials', 'view')) then a.purchase_value end as purchase_value,
         case when (select private.has_permission('asset_financials', 'view')) then a.purchase_currency end as purchase_currency,
         a.in_service_date,
         a.custom_values - (select private.hidden_field_keys('asset')) as custom_values,
         a.created_at, a.updated_at, a.created_by, a.updated_by
  from public.asset a
  where a.tenant_id = (select private.current_tenant_id())
    and (select private.has_permission('asset_core', 'view'))
    and a.deleted_at is null;
revoke all on public.asset_view from public, anon, authenticated;
grant select on public.asset_view to authenticated;
