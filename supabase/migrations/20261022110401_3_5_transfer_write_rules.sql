-- Story 3.5 (data-model-goal3.md §16.1): a transfer is not a save, so the 2.5 mandatory check
-- waits, as it does for the status action. location_id and the 3.5 location columns join the
-- skip list. Safe: on update location_id is not in the user grant, only transfer_asset() sets it.
-- Same function as 3_3_asset_write_rules otherwise; the trigger keeps pointing at it.
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
  v_skip    text[]  := array['status', 'status_reason', 'status_changed_at', 'location_id', 'location_reason',
                             'location_changed_at', 'created_at', 'created_by',
                             'updated_at', 'updated_by', 'deleted_at'];
begin
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
