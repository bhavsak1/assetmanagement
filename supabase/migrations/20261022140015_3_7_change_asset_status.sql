-- Story 3.7 (R4): status changes between tenant statuses. data-model-goal3.md §18.3.
-- A target is allowed when it is an active status in the asset's effective set, other than the
-- current one, and the system move is a B11 move or stays in the same system status. From disposed
-- it needs asset_lifecycle.reopen (A3; disposed to disposed is a correction), else execute.
-- Reasons as in 3.1. One engine: the action and the dialog's options use status_targets().

-- Allowed targets for one asset row, in set order. Permissions included; no tenant or row checks.
create function private.status_targets(p_tenant_id uuid, p_category_id uuid, p_status_id uuid)
returns table (id uuid, system_status text) language sql stable security definer set search_path = '' as $$
  select t.id, t.system_status
  from public.asset_status cur
  cross join unnest(private.effective_status_ids(p_tenant_id, p_category_id)) with ordinality e (id, n)
  join public.asset_status t on t.tenant_id = p_tenant_id and t.id = e.id
  where cur.tenant_id = p_tenant_id and cur.id = p_status_id
    and t.id <> cur.id and t.is_active and t.deleted_at is null
    and case when cur.system_status = 'disposed'
             then private.has_permission('asset_lifecycle', 'reopen')
                  and t.system_status in ('in_stock', 'active', 'inactive', 'disposed')
             else private.has_permission('asset_lifecycle', 'execute')
                  and (t.system_status = cur.system_status
                       or cur.system_status || '>' || t.system_status = any (array[
                            'in_stock>active', 'in_stock>disposed',
                            'active>under_maintenance', 'active>inactive', 'active>disposed',
                            'under_maintenance>active', 'under_maintenance>disposed',
                            'inactive>active', 'inactive>disposed']))
        end
  order by e.n;
$$;
revoke all on function private.status_targets(uuid, uuid, uuid) from public, anon, authenticated;

-- The statuses the caller may move this asset to now, in set order (the Change status dialog).
-- Empty when the caller may not change it (no permission, read-only tenant, unknown asset).
create function public.allowed_asset_statuses(p_asset_id uuid)
returns setof uuid language sql stable security definer set search_path = '' as $$
  select t.id
  from public.asset a
  cross join private.status_targets(a.tenant_id, a.category_id, a.status_id) t
  where a.tenant_id = private.current_tenant_id() and a.id = p_asset_id and a.deleted_at is null
    and private.has_permission('asset_core', 'view') and private.tenant_can_write();
$$;
revoke all on function public.allowed_asset_statuses(uuid) from public, anon;
grant execute on function public.allowed_asset_statuses(uuid) to authenticated;

-- The action by tenant status. Same checks and error codes as 3.1; 6.1 adds the scope check.
create function public.change_asset_status(p_asset_id uuid, p_status_id uuid, p_reason text default null)
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

  select a.category_id, a.status, a.status_id into v_asset from public.asset a
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
revoke all on function public.change_asset_status(uuid, uuid, text) from public, anon;
grant execute on function public.change_asset_status(uuid, uuid, text) to authenticated;

-- The 3.1 action by system status, kept for the Retire button and older callers: the first status
-- in the asset's set mapped to p_status (else the default row), then the action above.
create or replace function public.change_asset_status(p_asset_id uuid, p_status text, p_reason text default null)
returns void language plpgsql security definer set search_path = '' as $$
declare
  v_status_id uuid;
begin
  select private.pick_asset_status(a.tenant_id, a.category_id, p_status) into v_status_id
  from public.asset a
  where a.tenant_id = private.current_tenant_id() and a.id = p_asset_id and a.deleted_at is null;
  perform public.change_asset_status(p_asset_id, v_status_id, p_reason);
end;
$$;
