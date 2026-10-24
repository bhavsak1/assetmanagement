-- Story 4.1b (A5, B3 to B6, OQ-06 lean): the asset's OEM and O&M vendor. docs/data-model-goal4.md §11, §12.
-- Nullable columns on a table already on staging: the null default needs no backfill.
alter table public.asset
  add column oem_vendor_id uuid null,
  add column om_vendor_id  uuid null,
  add constraint asset_oem_vendor_fk foreign key (tenant_id, oem_vendor_id) references public.vendor (tenant_id, id),
  add constraint asset_om_vendor_fk  foreign key (tenant_id, om_vendor_id)  references public.vendor (tenant_id, id);

-- For the merge, the soft-delete guard, the vendor filter and the "in use" counts.
create index asset_oem_vendor_idx on public.asset (tenant_id, oem_vendor_id) where oem_vendor_id is not null and deleted_at is null;
create index asset_om_vendor_idx  on public.asset (tenant_id, om_vendor_id)  where om_vendor_id is not null and deleted_at is null;

-- Plain form fields, like parent_asset_id.
grant select (oem_vendor_id, om_vendor_id), insert (oem_vendor_id, om_vendor_id), update (oem_vendor_id, om_vendor_id)
  on public.asset to authenticated;

-- A new or changed link: the vendor is live and active, holds the column's role (B3), and is tagged to
-- the asset's category line (OQ-06). Unchanged links stay valid (B4). Data rules, so every writer.
-- A change away from a soft-deleted vendor is the merge_vendor repoint (§13): the role and tags moved
-- with the merge, so only live and active is checked there.
create function private.check_asset_vendors()
returns trigger language plpgsql security definer set search_path = '' as $$
declare
  v_role text;
  v_new  uuid;
  v_old  uuid;
begin
  foreach v_role in array array['oem', 'om'] loop
    v_new := case v_role when 'oem' then new.oem_vendor_id else new.om_vendor_id end;
    v_old := case when tg_op = 'INSERT' then null when v_role = 'oem' then old.oem_vendor_id else old.om_vendor_id end;
    continue when v_new is null or v_new is not distinct from v_old;
    if not exists (select 1 from public.vendor v where v.tenant_id = new.tenant_id and v.id = v_new
                   and v.is_active and v.deleted_at is null
                   and (v_role = any (v.roles)
                        or exists (select 1 from public.vendor o where o.tenant_id = new.tenant_id
                                   and o.id = v_old and o.deleted_at is not null))) then
      raise exception '%_vendor_id: vendor is inactive or not an % vendor', v_role, v_role using errcode = '23514';
    end if;
    if v_new <> all (private.allowed_vendor_ids(new.tenant_id, new.category_id, v_role))
       and not exists (select 1 from public.vendor o where o.tenant_id = new.tenant_id
                       and o.id = v_old and o.deleted_at is not null) then
      raise exception '%_vendor_id: vendor is not tagged to this category', v_role using errcode = '23514';
    end if;
  end loop;
  return new;
end;
$$;
revoke all on function private.check_asset_vendors() from public, anon, authenticated;

create trigger check_asset_vendors before insert or update of oem_vendor_id, om_vendor_id on public.asset
  for each row execute function private.check_asset_vendors();

-- A vendor still linked to a live asset is never soft-deleted: merge it instead. Checked at commit, so
-- merge_vendor can soft-delete first and repoint after, in one transaction.
create function private.check_vendor_unlinked()
returns trigger language plpgsql security definer set search_path = '' as $$
begin
  if exists (select 1 from public.asset a where a.tenant_id = new.tenant_id and a.deleted_at is null
             and (a.oem_vendor_id = new.id or a.om_vendor_id = new.id)) then
    raise exception 'vendor is linked to assets: merge it instead' using errcode = '23503';
  end if;
  return null;
end;
$$;
revoke all on function private.check_vendor_unlinked() from public, anon, authenticated;

create constraint trigger check_vendor_unlinked after update of deleted_at on public.vendor
  deferrable initially deferred for each row
  when (old.deleted_at is null and new.deleted_at is not null)
  execute function private.check_vendor_unlinked();

-- Same function as 3_7_asset_status_id, plus one rule: a merge repoint (away from a soft-deleted
-- vendor) is not a save, so the 2.5 mandatory check waits and an incomplete asset cannot block a merge.
create or replace function private.check_asset_values()
returns trigger language plpgsql security definer set search_path = '' as $$
declare
  v_user    boolean := auth.uid() is not null;
  v_old     jsonb   := case when tg_op = 'UPDATE' then old.custom_values else '{}' end;
  v_hidden  text[];
  v_line    uuid[];
  v_key     text;
  v_value   jsonb;
  v_missing text[];
  f         record;
  -- Columns that are not "data": changing only these is not a save, so mandatory rules wait.
  v_skip    text[]  := array['status', 'status_id', 'status_reason', 'status_changed_at', 'location_id', 'location_reason',
                             'location_changed_at', 'created_at', 'created_by',
                             'updated_at', 'updated_by', 'deleted_at'];
begin
  if tg_op = 'UPDATE' and exists (select 1 from public.vendor v where v.tenant_id = new.tenant_id
                                  and v.id in (old.oem_vendor_id, old.om_vendor_id) and v.deleted_at is not null) then
    v_skip := v_skip || array['oem_vendor_id', 'om_vendor_id'];
  end if;

  if (tg_op = 'INSERT' or new.category_id is distinct from old.category_id)
     and not exists (select 1 from public.asset_category c where c.tenant_id = new.tenant_id
                     and c.id = new.category_id and c.is_active and c.deleted_at is null) then
    raise exception 'category is inactive or deleted' using errcode = '23514';
  end if;
  if new.location_id is not null and (tg_op = 'INSERT' or new.location_id is distinct from old.location_id)
     and not exists (select 1 from public.location l where l.tenant_id = new.tenant_id
                     and l.id = new.location_id and l.active and l.deleted_at is null) then
    raise exception 'location is inactive or deleted' using errcode = '23514';
  end if;

  if v_user and tg_op = 'INSERT' and new.status not in ('in_stock', 'active') then
    raise exception 'a new asset starts as in_stock or active' using errcode = '23514';
  end if;

  if v_user and not (private.has_permission('asset_financials', 'update') and private.has_permission('asset_financials', 'view'))
     and (case when tg_op = 'INSERT' then new.purchase_value is not null or new.purchase_currency is not null
               else (new.purchase_value, new.purchase_currency) is distinct from (old.purchase_value, old.purchase_currency) end) then
    raise exception 'no permission to change purchase value' using errcode = '42501';
  end if;

  -- A form never saw the keys the user cannot view, so it cannot change or blank them.
  if v_user then
    v_hidden := private.hidden_field_keys('asset');
    new.custom_values := (new.custom_values - v_hidden)
      || coalesce((select jsonb_object_agg(o.key, o.value) from jsonb_each(v_old) o where o.key = any (v_hidden)), '{}');
    -- Removing a key blanks the field: same permission as changing it (3.3).
    for v_key in
      select o.key from jsonb_each(v_old) o
      join public.field_definition fd on fd.tenant_id = new.tenant_id and fd.entity = 'asset' and fd.key = o.key
      join public.security_domain d on d.id = fd.security_domain_id
      where not new.custom_values ? o.key and not private.has_permission(d.code, 'update')
    loop
      raise exception 'no permission to change custom field %', v_key using errcode = '42501';
    end loop;
  end if;

  -- The category and its ancestors: the fields that apply (G3).
  with recursive up as (
    select c.id, c.parent_id from public.asset_category c where c.tenant_id = new.tenant_id and c.id = new.category_id
    union all
    select c.id, c.parent_id from public.asset_category c join up on c.tenant_id = new.tenant_id and c.id = up.parent_id
  )
  select array_agg(up.id) into v_line from up;

  for v_key, v_value in select o.key, o.value from jsonb_each(new.custom_values) o loop
    select fd.type, fd.options, fd.is_active, fd.deleted_at, d.code as domain_code,
           (fd.category_id is null or fd.category_id = any (v_line)) as in_line
      into f
    from public.field_definition fd
    join public.security_domain d on d.id = fd.security_domain_id
    where fd.tenant_id = new.tenant_id and fd.entity = 'asset' and fd.key = v_key;
    if not found then
      raise exception 'unknown custom field: %', v_key using errcode = '22023';
    end if;
    -- Unchanged values stay, even after a category change or a field deactivation (keys keep their meaning, G4).
    continue when v_old -> v_key is not distinct from v_value;
    if f.deleted_at is not null or not f.is_active then
      raise exception 'custom field % is inactive', v_key using errcode = '22023';
    end if;
    if not f.in_line then
      raise exception 'custom field % does not apply to this category', v_key using errcode = '22023';
    end if;
    if not private.custom_value_ok(f.type, f.options, v_value) then
      raise exception 'custom field % needs a % value', v_key, f.type using errcode = '22023';
    end if;
    if v_user and not private.has_permission(f.domain_code, 'update') then
      raise exception 'no permission to change custom field %', v_key using errcode = '42501';
    end if;
  end loop;

  -- Mandatory (2.5): on insert and on a user save that changes data. M2: skip fields the user cannot write.
  if v_user and new.deleted_at is null
     and (tg_op = 'INSERT' or (to_jsonb(new) - v_skip) is distinct from (to_jsonb(old) - v_skip)) then
    select array_agg(m.name order by m.name) into v_missing
    from (
      select fd.key as name
      from public.field_definition fd
      join public.security_domain d on d.id = fd.security_domain_id
      where fd.tenant_id = new.tenant_id and fd.entity = 'asset' and fd.is_required and fd.is_active
        and fd.deleted_at is null and (fd.category_id is null or fd.category_id = any (v_line))
        and not new.custom_values ? fd.key
        and private.has_permission(d.code, 'update')
      union all
      select r.field
      from public.tenant t, unnest(t.required_asset_fields) r (field)
      where t.id = new.tenant_id
        and to_jsonb(new) ->> (case r.field when 'location' then 'location_id' else r.field end) is null
        -- location changes only through the 3.5 transfer action, so an edit cannot fix it.
        and not (r.field = 'location' and tg_op = 'UPDATE')
        and (r.field <> 'purchase_value' or private.has_permission('asset_financials', 'update'))
    ) m;
    if v_missing is not null then
      raise exception 'missing mandatory fields: %', array_to_string(v_missing, ', ') using errcode = '23502';
    end if;
  end if;
  return new;
end;
$$;

-- Same view as 3_7_asset_status_id with the vendor ids appended (B5: names come from vendor_view in
-- the app, under vendor_core.view; no join, so the list plan stays the same).
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
         a.oem_vendor_id, a.om_vendor_id
  from public.asset a
  where a.tenant_id = (select private.current_tenant_id())
    and (select private.has_permission('asset_core', 'view'))
    and a.deleted_at is null;

-- The 3.7 list functions with one more filter, p_vendor_id (B6 b: OEM or O&M). New argument last, with
-- a default: old calls are unchanged. Dropped and recreated (signature change; setof asset_view too).
drop function public.list_assets(text, text, uuid, uuid, text, text, uuid, integer, uuid);
drop function public.count_assets(text, text, uuid, uuid, uuid);
drop function private.asset_list_sql(text, text, uuid, uuid, text, text, uuid, integer, uuid);
drop function private.asset_list_where(text, text, uuid, uuid, uuid);

create function private.asset_list_where(p_term text, p_status text, p_category_id uuid, p_location_id uuid,
                                         p_status_id uuid default null, p_vendor_id uuid default null)
returns text language sql immutable set search_path = '' as $$
  select concat_ws(' and ', 'true',
    -- Set form, like the 6.1 scope: one array, then primary key lookups whatever the table stats say.
    case when btrim(p_term) <> ''
         then format('v.id = any ((select array(select private.search_asset_ids(%L)))::uuid[])', btrim(p_term)) end,
    case when p_status is not null then format('v.status = %L', p_status) end,
    case when p_status_id is not null then format('v.status_id = %L', p_status_id) end,
    case when p_vendor_id is not null then format('(v.oem_vendor_id = %1$L or v.om_vendor_id = %1$L)', p_vendor_id) end,
    case when p_category_id is not null
         then format('v.category_id = any ((select private.category_subtree_ids(%L))::uuid[])', p_category_id) end,
    case when p_location_id is not null
         then format('v.location_id = any ((select private.location_subtree_ids(%L))::uuid[])', p_location_id) end);
$$;

create function private.asset_list_sql(
  p_term text, p_status text, p_category_id uuid, p_location_id uuid,
  p_sort text, p_after_value text, p_after_id uuid, p_limit integer, p_status_id uuid default null,
  p_vendor_id uuid default null)
returns text language plpgsql immutable set search_path = '' as $$
declare
  v_sql text := 'select v.* from public.asset_view v where '
                || private.asset_list_where(p_term, p_status, p_category_id, p_location_id, p_status_id, p_vendor_id);
begin
  if p_sort is null or p_sort not in ('name', 'tag', 'updated') then
    raise exception 'unknown sort: %', p_sort using errcode = '22023';
  end if;
  if p_limit is null or p_limit not between 1 and 100 then
    raise exception 'limit must be 1 to 100' using errcode = '22023';
  end if;
  if p_after_id is not null then
    v_sql := v_sql || case p_sort
      when 'name' then format(' and (v.name, v.id) > (%L, %L::uuid)', p_after_value, p_after_id)
      when 'tag'  then format(' and v.tag > %L', p_after_value)
      -- The index is (updated_at desc, id): start at the cursor time, then skip ids already shown.
      else format(' and v.updated_at <= %1$L::timestamptz and (v.updated_at < %1$L::timestamptz or v.id > %2$L::uuid)',
                  p_after_value, p_after_id)
    end;
  end if;
  v_sql := v_sql || case p_sort
    when 'name' then ' order by v.name, v.id'
    when 'tag'  then ' order by v.tag'
    else ' order by v.updated_at desc, v.id'
  end || format(' limit %s', p_limit);
  return v_sql;
end;
$$;

create function public.list_assets(
  p_term text default null, p_status text default null, p_category_id uuid default null,
  p_location_id uuid default null, p_sort text default 'name', p_after_value text default null,
  p_after_id uuid default null, p_limit integer default 50, p_status_id uuid default null,
  p_vendor_id uuid default null)
returns setof public.asset_view language plpgsql stable set search_path = '' as $$
begin
  return query execute private.asset_list_sql(p_term, p_status, p_category_id, p_location_id,
                                              p_sort, p_after_value, p_after_id, p_limit, p_status_id, p_vendor_id);
end;
$$;

create function public.count_assets(
  p_term text default null, p_status text default null, p_category_id uuid default null,
  p_location_id uuid default null, p_status_id uuid default null, p_vendor_id uuid default null)
returns integer language plpgsql stable set search_path = '' as $$
declare
  v_n integer;
begin
  execute 'select count(*)::int from (select 1 from public.asset_view v where '
          || private.asset_list_where(p_term, p_status, p_category_id, p_location_id, p_status_id, p_vendor_id)
          || ' limit 10001) c'
    into v_n;
  return v_n;
end;
$$;

revoke all on function private.asset_list_where(text, text, uuid, uuid, uuid, uuid),
  private.asset_list_sql(text, text, uuid, uuid, text, text, uuid, integer, uuid, uuid),
  public.list_assets(text, text, uuid, uuid, text, text, uuid, integer, uuid, uuid),
  public.count_assets(text, text, uuid, uuid, uuid, uuid)
  from public, anon;
grant execute on function private.asset_list_where(text, text, uuid, uuid, uuid, uuid),
  private.asset_list_sql(text, text, uuid, uuid, text, text, uuid, integer, uuid, uuid),
  public.list_assets(text, text, uuid, uuid, text, text, uuid, integer, uuid, uuid),
  public.count_assets(text, text, uuid, uuid, uuid, uuid)
  to authenticated;
