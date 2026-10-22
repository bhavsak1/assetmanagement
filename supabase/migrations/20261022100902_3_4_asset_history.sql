-- Story 3.4 (A6, H1): the Audit tab of an asset. Everyone who can view the asset sees its history,
-- without audit_log.view, masked like asset_view: money needs asset_financials.view, each custom key
-- its field's domain (data-model-goal3.md §15). 6.1 adds its scope clause to the asset exists check.

-- now() is the transaction start, so rows written in one transaction tied and lost their order.
alter table public.audit_log alter column occurred_at set default clock_timestamp();

-- One audit snapshot of an asset with the asset_view masking applied.
create function private.mask_asset_data(p_data jsonb, p_money boolean, p_hidden text[])
returns jsonb language sql immutable set search_path = '' as $$
  select case when p_money then p_data else p_data - 'purchase_value' - 'purchase_currency' end
         || case when p_data ? 'custom_values'
                 then jsonb_build_object('custom_values', (p_data -> 'custom_values') - p_hidden) else '{}' end;
$$;

create function public.asset_history(p_asset_id uuid, p_before timestamptz default null, p_before_id uuid default null,
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
      and exists (select 1 from public.asset a where a.tenant_id = c.tenant_id and a.id = p_asset_id)
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

revoke all on function public.asset_history(uuid, timestamptz, uuid, integer) from public, anon;
grant execute on function public.asset_history(uuid, timestamptz, uuid, integer) to authenticated;
revoke all on function private.mask_asset_data(jsonb, boolean, text[]) from public, anon, authenticated;
