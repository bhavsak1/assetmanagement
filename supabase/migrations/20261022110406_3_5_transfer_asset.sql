-- Story 3.5: a location change is an action, not a table write (CLAUDE.md §7.8, data-model-goal3.md §16.1).
-- asset_lifecycle.execute covers transfer and retire (1.2 catalog). The whole row moves: no partial
-- transfer (OQ-01), the tag stays (§2), children stay put (T3, OQ-07). No back-dating (T2).
-- The audit trigger records the update; this adds the asset.transferred event. Same transaction.
-- 6.1 adds a set-form scope clause to the asset lookup and to the target location lookup.
create function public.transfer_asset(p_asset_id uuid, p_to_location_id uuid, p_reason text)
returns void language plpgsql security definer set search_path = '' as $$
declare
  v_tenant_id uuid := private.current_tenant_id();
  v_reason    text := nullif(btrim(p_reason), '');
  v_status    text;
  v_from      uuid;
begin
  if v_tenant_id is null or not private.has_permission('asset_core', 'view')
     or not private.has_permission('asset_lifecycle', 'execute') or not private.tenant_can_write() then
    raise exception 'not allowed to transfer asset' using errcode = '42501';
  end if;

  select a.status, a.location_id into v_status, v_from from public.asset a
  where a.tenant_id = v_tenant_id and a.id = p_asset_id and a.deleted_at is null
  for update;
  if not found then
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
revoke all on function public.transfer_asset(uuid, uuid, text) from public, anon;
grant execute on function public.transfer_asset(uuid, uuid, text) to authenticated;
