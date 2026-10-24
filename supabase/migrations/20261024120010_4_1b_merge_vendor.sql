-- Story 4.1b (B7, B8): merge a duplicate vendor into another (CLAUDE.md §8). An action, not a table
-- write (§7.8). docs/data-model-goal4.md §13. The source is soft-deleted first, so the asset rule
-- reads the repoint as the merge; the deferred soft-delete guard is checked at commit, after it.
-- 6.1 adds its scope clause to the vendor lookups.
create function public.merge_vendor(p_from_id uuid, p_into_id uuid)
returns void language plpgsql security definer set search_path = '' as $$
declare
  v_tenant_id  uuid := private.current_tenant_id();
  v_contacts   integer;
  v_categories integer;
  v_assets     integer;
  v_roles      text[];
begin
  if v_tenant_id is null or not private.has_permission('vendor_core', 'delete') or not private.tenant_can_write() then
    raise exception 'not allowed to merge vendors' using errcode = '42501';
  end if;
  if p_from_id is not distinct from p_into_id then
    raise exception 'a vendor cannot be merged into itself' using errcode = '22023';
  end if;
  -- Another tenant's id reads as not found.
  perform 1 from public.vendor v
  where v.tenant_id = v_tenant_id and v.id in (p_from_id, p_into_id) and v.deleted_at is null
  order by v.id for update;
  if (select count(*) from public.vendor v where v.tenant_id = v_tenant_id and v.id in (p_from_id, p_into_id)
      and v.deleted_at is null) <> 2 then
    raise exception 'vendor not found' using errcode = 'P0002';
  end if;
  if not exists (select 1 from public.vendor v where v.tenant_id = v_tenant_id and v.id = p_into_id and v.is_active) then
    raise exception 'cannot merge into an inactive vendor' using errcode = '22023';
  end if;

  -- Roles: the union. Name, code, contact basics and custom values of into stay (B8).
  update public.vendor i
  set roles = array(select distinct r from unnest(i.roles || f.roles) r order by r), updated_by = auth.uid()
  from public.vendor f
  where i.tenant_id = v_tenant_id and i.id = p_into_id and f.tenant_id = v_tenant_id and f.id = p_from_id
    and not f.roles <@ i.roles;
  select v.roles into v_roles from public.vendor v where v.tenant_id = v_tenant_id and v.id = p_into_id;

  update public.vendor set deleted_at = now(), updated_by = auth.uid()
  where tenant_id = v_tenant_id and id = p_from_id;

  -- Contacts move; into keeps its own primary.
  update public.vendor_contact c
  set vendor_id = p_into_id, updated_by = auth.uid(),
      is_primary = c.is_primary and not exists (
        select 1 from public.vendor_contact p where p.tenant_id = v_tenant_id and p.vendor_id = p_into_id
          and p.is_primary and p.deleted_at is null)
  where c.tenant_id = v_tenant_id and c.vendor_id = p_from_id;
  get diagnostics v_contacts = row_count;

  -- Category tags: from becomes into, without duplicates. A stale tag (from dropped the role, B4) is
  -- removed: into may not hold that role, and the tag check refuses a new id without it.
  update public.asset_category c
  set oem_vendor_ids = array(select distinct x from unnest(array_replace(c.oem_vendor_ids, p_from_id,
                         case when 'oem' = any (v_roles) then p_into_id end)) x where x is not null),
      om_vendor_ids  = array(select distinct x from unnest(array_replace(c.om_vendor_ids, p_from_id,
                         case when 'om' = any (v_roles) then p_into_id end)) x where x is not null),
      updated_by = auth.uid()
  where c.tenant_id = v_tenant_id and p_from_id = any (c.oem_vendor_ids || c.om_vendor_ids);
  get diagnostics v_categories = row_count;

  -- Assets, soft-deleted ones too (their history points at the vendor).
  update public.asset a
  set oem_vendor_id = case when a.oem_vendor_id = p_from_id then p_into_id else a.oem_vendor_id end,
      om_vendor_id  = case when a.om_vendor_id  = p_from_id then p_into_id else a.om_vendor_id end,
      updated_by = auth.uid()
  where a.tenant_id = v_tenant_id and (a.oem_vendor_id = p_from_id or a.om_vendor_id = p_from_id);
  get diagnostics v_assets = row_count;

  -- 4.2 adds the coverage repoint here.

  insert into public.audit_log (tenant_id, category, actor_type, actor_user_id, action, table_name, record_id, old_data, new_data)
  values (v_tenant_id, 'data', 'user', auth.uid(), 'merge', 'vendor', p_from_id, null,
          jsonb_build_object('into_id', p_into_id, 'contacts', v_contacts, 'categories', v_categories, 'assets', v_assets));
  insert into private.outbox_event (tenant_id, event_type, aggregate_type, aggregate_id, payload)
  values (v_tenant_id, 'vendor.merged', 'vendor', p_from_id,
          jsonb_build_object('into_id', p_into_id, 'contacts', v_contacts, 'categories', v_categories, 'assets', v_assets));
end;
$$;
revoke all on function public.merge_vendor(uuid, uuid) from public, anon;
grant execute on function public.merge_vendor(uuid, uuid) to authenticated;
