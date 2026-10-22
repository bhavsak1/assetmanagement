-- Story 3.1 (A2, A3): status changes are an action, not a table write (CLAUDE.md §7.8).
-- B11 transitions; a reason for inactive, disposed and reopen. Reopen from disposed needs
-- asset_lifecycle.reopen (OQ-04 lean). The audit trigger records the update; this adds the
-- asset.status_changed event. 3.7 maps tenant statuses onto these; 6.1 adds the scope check.
create function public.change_asset_status(p_asset_id uuid, p_status text, p_reason text default null)
returns void language plpgsql security definer set search_path = '' as $$
declare
  v_tenant_id uuid := private.current_tenant_id();
  v_reason    text := nullif(btrim(p_reason), '');
  v_old       text;
begin
  if v_tenant_id is null or not private.has_permission('asset_core', 'view') or not private.tenant_can_write() then
    raise exception 'not allowed to change asset status' using errcode = '42501';
  end if;

  select a.status into v_old from public.asset a
  where a.tenant_id = v_tenant_id and a.id = p_asset_id and a.deleted_at is null
  for update;
  if not found then
    raise exception 'asset not found' using errcode = 'P0002';
  end if;

  if v_old = 'disposed' then
    if not private.has_permission('asset_lifecycle', 'reopen') then
      raise exception 'not allowed to reopen a disposed asset' using errcode = '42501';
    end if;
    if p_status not in ('in_stock', 'active', 'inactive') then
      raise exception 'a disposed asset reopens as in_stock, active or inactive' using errcode = '22023';
    end if;
  else
    if not private.has_permission('asset_lifecycle', 'execute') then
      raise exception 'not allowed to change asset status' using errcode = '42501';
    end if;
    if v_old || '>' || p_status <> all (array[
         'in_stock>active', 'in_stock>disposed',
         'active>under_maintenance', 'active>inactive', 'active>disposed',
         'under_maintenance>active', 'under_maintenance>disposed',
         'inactive>active', 'inactive>disposed']) then
      raise exception 'status cannot change from % to %', v_old, p_status using errcode = '22023';
    end if;
  end if;

  if v_reason is null and (p_status in ('inactive', 'disposed') or v_old = 'disposed') then
    raise exception 'a reason is required for this status change' using errcode = '23502';
  end if;

  update public.asset
  set status = p_status, status_reason = v_reason, status_changed_at = now(), updated_by = auth.uid()
  where tenant_id = v_tenant_id and id = p_asset_id;

  insert into private.outbox_event (tenant_id, event_type, aggregate_type, aggregate_id, payload)
  values (v_tenant_id, 'asset.status_changed', 'asset', p_asset_id,
          jsonb_build_object('from', v_old, 'to', p_status, 'reason', v_reason));
end;
$$;
revoke all on function public.change_asset_status(uuid, text, text) from public, anon;
grant execute on function public.change_asset_status(uuid, text, text) to authenticated;
