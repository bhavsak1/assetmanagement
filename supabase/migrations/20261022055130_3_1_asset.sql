-- Story 3.1: the asset register table. Design and owner decisions A1 to A6: docs/data-model-goal3.md.
-- 1.4 RLS pattern on the existing catalog domain asset_core. Money columns sit in asset_financials and
-- are read only through asset_view (next migration). Status changes go through change_asset_status().

-- A1: tenant-built tag pattern. Parts: {LOC}, {CAT}, {DATE:fmt}, literals, then exactly one {SEQ:n} last.
alter table public.tenant add column asset_tag_pattern text not null default 'AST-{SEQ:5}'
  constraint tenant_asset_tag_pattern_check check (asset_tag_pattern ~
    '^([A-Za-z0-9._/-]|\{LOC\}|\{CAT\}|\{DATE:(yyyy|yy|mmm|mm|dd)([-/.]?(yyyy|yy|mmm|mm|dd))*\})*\{SEQ:[3-9]\}$');

create table public.asset (
  id                uuid primary key default gen_random_uuid(),
  tenant_id         uuid not null references public.tenant (id),
  -- Upper case, so a lookup is plain `=`: leakproof, so it can use the index through asset_view.
  tag               text not null check (tag ~ '^[A-Z0-9][A-Z0-9._/-]{0,59}$'),
  name              text not null,
  category_id       uuid not null,
  location_id       uuid null,
  -- System lifecycle (A2). Tenant statuses mapped to these arrive in 3.7.
  status            text not null default 'active'
                    check (status in ('in_stock', 'active', 'under_maintenance', 'inactive', 'disposed')),
  status_reason     text null,
  status_changed_at timestamptz null,
  quantity          integer not null default 1 check (quantity >= 1),  -- OQ-01 lean: no split
  parent_asset_id   uuid null,                                         -- OQ-07 lean: max 5 levels
  criticality       text null check (criticality in ('A', 'B', 'C')),
  serial_number     text null,
  manufacturer      text null,
  model             text null,
  purchase_date     date null,
  purchase_value    numeric(19, 4) null check (purchase_value >= 0),     -- asset_financials
  purchase_currency char(3) null check (purchase_currency ~ '^[A-Z]{3}$'),
  in_service_date   date null,
  custom_values     jsonb not null default '{}' check (jsonb_typeof(custom_values) = 'object'),
  created_at        timestamptz not null default now(),
  updated_at        timestamptz not null default now(),
  created_by        uuid null references public.user_profile (id),
  updated_by        uuid null references public.user_profile (id),
  deleted_at        timestamptz null,
  unique (tenant_id, id),
  foreign key (tenant_id, category_id) references public.asset_category (tenant_id, id),
  foreign key (tenant_id, location_id) references public.location (tenant_id, id),
  foreign key (tenant_id, parent_asset_id) references public.asset (tenant_id, id),
  check (purchase_value is null or purchase_currency is not null)
);

-- Access path (spike 1.7 §6): partial like the view's filter and led by tenant_id, so a large
-- tenant's list walks the index and stops at the page size instead of reading every row.
create unique index asset_tag_uq on public.asset (tenant_id, tag) where deleted_at is null;
create index asset_name_idx on public.asset (tenant_id, name, id) where deleted_at is null;
create index asset_updated_idx on public.asset (tenant_id, updated_at desc, id) where deleted_at is null;
create index asset_category_idx on public.asset (tenant_id, category_id) where deleted_at is null;
create index asset_location_idx on public.asset (tenant_id, location_id) where deleted_at is null;
create index asset_parent_idx on public.asset (tenant_id, parent_asset_id) where parent_asset_id is not null;

-- Tag counter, one row per rendered prefix (so {DATE:yyyymm} restarts monthly). Private, like
-- location_closure: only the security definer tag code reads or writes it.
create table private.asset_tag_counter (
  tenant_id  uuid not null references public.tenant (id),
  prefix     text not null,
  last_value bigint not null,
  primary key (tenant_id, prefix)
);
alter table private.asset_tag_counter enable row level security;
revoke all on private.asset_tag_counter from public, anon, authenticated;

-- Next generated tag. Rolls back with the insert, so no gaps; skips numbers a typed tag already holds.
create function private.next_asset_tag(p_tenant_id uuid, p_location_id uuid, p_category_id uuid)
returns text language plpgsql security definer set search_path = '' as $$
declare
  v_pattern text;
  v_tz      text;
  v_prefix  text;
  v_width   int;
  v_code    text;
  v_n       bigint;
  v_tag     text;
  m         text[];
begin
  select t.asset_tag_pattern, t.time_zone into v_pattern, v_tz from public.tenant t where t.id = p_tenant_id;
  v_width  := substring(v_pattern from '\{SEQ:(\d)\}$')::int;
  v_prefix := regexp_replace(v_pattern, '\{SEQ:\d\}$', '');

  -- Dates first, so a location or category code can never be read as a token.
  for m in select regexp_matches(v_prefix, '\{DATE:([^}]*)\}', 'g') loop
    v_prefix := replace(v_prefix, '{DATE:' || m[1] || '}',
      to_char(now() at time zone v_tz,
        replace(replace(replace(replace(replace(m[1], 'yyyy', 'YYYY'), 'yy', 'YY'), 'mmm', 'MON'), 'mm', 'MM'), 'dd', 'DD')));
  end loop;

  if strpos(v_prefix, '{CAT}') > 0 then
    with recursive up as (
      select c.parent_id, c.code, 0 as depth from public.asset_category c
      where c.tenant_id = p_tenant_id and c.id = p_category_id
      union all
      select c.parent_id, c.code, up.depth + 1 from public.asset_category c
      join up on c.tenant_id = p_tenant_id and c.id = up.parent_id
    )
    select up.code into v_code from up where up.code is not null order by up.depth limit 1;
    if v_code is null then
      raise exception 'the tag pattern needs a category code: add one to the category or type a tag' using errcode = '22023';
    end if;
    v_prefix := replace(v_prefix, '{CAT}', v_code);
  end if;

  if strpos(v_prefix, '{LOC}') > 0 then
    v_code := null;
    select l.code into v_code
    from private.location_closure c
    join public.location l on l.tenant_id = c.tenant_id and l.id = c.ancestor_id
    where c.tenant_id = p_tenant_id and c.descendant_id = p_location_id and l.code is not null
    order by c.depth limit 1;
    if v_code is null then
      raise exception 'the tag pattern needs a location code: set a location with a code or type a tag' using errcode = '22023';
    end if;
    v_prefix := replace(v_prefix, '{LOC}', v_code);
  end if;
  v_prefix := upper(v_prefix);

  loop
    insert into private.asset_tag_counter as c (tenant_id, prefix, last_value) values (p_tenant_id, v_prefix, 1)
    on conflict (tenant_id, prefix) do update set last_value = c.last_value + 1
    returning c.last_value into v_n;
    -- lpad truncates, so never pad to less than the number itself.
    v_tag := v_prefix || lpad(v_n::text, greatest(v_width, length(v_n::text)), '0');
    exit when not exists (select 1 from public.asset a
                          where a.tenant_id = p_tenant_id and a.tag = v_tag and a.deleted_at is null);
  end loop;
  return v_tag;
end;
$$;

-- B9: generate when no tag is given; typing or changing one needs asset_core.set_tag.
-- "A user" is any write with a signed-in user behind it (auth.uid()), actions included, so the
-- same rules hold for the UI, the API and later imports. Provisioning and system jobs have none.
create function private.assign_asset_tag()
returns trigger language plpgsql security definer set search_path = '' as $$
begin
  if tg_op = 'INSERT' and new.tag is null then
    new.tag := private.next_asset_tag(new.tenant_id, new.location_id, new.category_id);
  elsif auth.uid() is not null and (tg_op = 'INSERT' or new.tag is distinct from old.tag)
        and not private.has_permission('asset_core', 'set_tag') then
    raise exception 'no permission to type or change an asset tag' using errcode = '42501';
  end if;
  new.tag := upper(new.tag);
  return new;
end;
$$;

-- Keys of p_entity custom fields whose domain the caller cannot view (CLAUDE.md §7.7).
-- Called once per statement in (select ...), then jsonb `-` per row.
create function private.hidden_field_keys(p_entity text)
returns text[] language sql stable security definer set search_path = '' as $$
  select coalesce(array_agg(f.key), '{}')
  from public.field_definition f
  join public.security_domain d on d.id = f.security_domain_id
  where f.tenant_id = private.current_tenant_id() and f.entity = p_entity
    and not private.has_permission(d.code, 'view');
$$;
grant execute on function private.hidden_field_keys(text) to authenticated;

-- One custom value against its field type (data-model-goal2.md §2).
create function private.custom_value_ok(p_type text, p_options jsonb, p_value jsonb)
returns boolean language plpgsql immutable set search_path = '' as $$
begin
  case p_type
    when 'text'    then return jsonb_typeof(p_value) = 'string';
    when 'number'  then return jsonb_typeof(p_value) = 'number';
    when 'boolean' then return jsonb_typeof(p_value) = 'boolean';
    when 'list'    then
      return jsonb_typeof(p_value) = 'string'
         and exists (select 1 from jsonb_array_elements(p_options) o
                     where o ->> 'code' = p_value #>> '{}' and coalesce((o ->> 'is_active')::boolean, true));
    when 'date'    then
      if jsonb_typeof(p_value) <> 'string' or (p_value #>> '{}') !~ '^\d{4}-\d{2}-\d{2}$' then
        return false;
      end if;
      perform (p_value #>> '{}')::date;  -- 2024-02-30 raises, caught below
      return true;
  end case;
exception when others then
  return false;
end;
$$;

-- Write rules (data-model-goal3.md §4.1): active category and location, insert status, money
-- needs asset_financials.update, custom values (hidden keys kept, changed keys checked), mandatory.
create function private.check_asset_values()
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
  v_skip    text[]  := array['status', 'status_reason', 'status_changed_at', 'created_at', 'created_by',
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

  if v_user and not private.has_permission('asset_financials', 'update')
     and (case when tg_op = 'INSERT' then new.purchase_value is not null or new.purchase_currency is not null
               else (new.purchase_value, new.purchase_currency) is distinct from (old.purchase_value, old.purchase_currency) end) then
    raise exception 'no permission to change purchase value' using errcode = '42501';
  end if;

  -- A form never saw the keys the user cannot view, so it cannot change or blank them.
  if v_user then
    v_hidden := private.hidden_field_keys('asset');
    new.custom_values := (new.custom_values - v_hidden)
      || coalesce((select jsonb_object_agg(o.key, o.value) from jsonb_each(v_old) o where o.key = any (v_hidden)), '{}');
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

-- OQ-07 lean: no cycle, at most 5 levels. Reads every row of the tenant, whatever RLS shows.
create function private.check_asset_parent()
returns trigger language plpgsql security definer set search_path = '' as $$
declare
  v_levels int;
  v_cycle  boolean;
  v_height int := 1;
begin
  if new.parent_asset_id is null then
    return new;
  end if;
  with recursive up as (
    select a.id, a.parent_asset_id, 1 as level from public.asset a
    where a.tenant_id = new.tenant_id and a.id = new.parent_asset_id
    union all
    select a.id, a.parent_asset_id, up.level + 1 from public.asset a
    join up on a.tenant_id = new.tenant_id and a.id = up.parent_asset_id
    where up.id <> new.id
  )
  select max(level), bool_or(id = new.id) into v_levels, v_cycle from up;
  if v_cycle then
    raise exception 'an asset cannot be inside itself' using errcode = '23514';
  end if;
  if tg_op = 'UPDATE' then
    with recursive down as (
      select a.id, 2 as height from public.asset a where a.tenant_id = new.tenant_id and a.parent_asset_id = new.id
      union all
      select a.id, down.height + 1 from public.asset a
      join down on a.tenant_id = new.tenant_id and a.parent_asset_id = down.id
    )
    select coalesce(max(height), 1) into v_height from down;
  end if;
  if v_levels + v_height > 5 then
    raise exception 'assets can nest at most 5 levels deep' using errcode = '23514';
  end if;
  return new;
end;
$$;
revoke all on function private.next_asset_tag(uuid, uuid, uuid), private.assign_asset_tag(),
  private.custom_value_ok(text, jsonb, jsonb), private.check_asset_values(), private.check_asset_parent()
  from public, anon, authenticated;

-- Before triggers fire by name: tag, then parent, values, soft delete, updated_at.
create trigger assign_asset_tag before insert or update of tag on public.asset
  for each row execute function private.assign_asset_tag();
create trigger check_asset_parent before insert or update of parent_asset_id on public.asset
  for each row execute function private.check_asset_parent();
create trigger check_asset_values before insert or update on public.asset
  for each row execute function private.check_asset_values();
create trigger check_soft_delete before update of deleted_at on public.asset
  for each row execute function private.check_soft_delete('asset_core', 'delete');
create trigger set_updated_at before update on public.asset
  for each row execute function private.set_updated_at();
create trigger audit after insert or update or delete on public.asset
  for each row execute function private.audit_row('data');

-- RLS, 1.4 pattern. Soft-deleted rows stay readable here; asset_view shows live rows only.
alter table public.asset enable row level security;

create policy asset_select on public.asset
  for select to authenticated
  using (tenant_id = (select private.current_tenant_id())
         and (select private.has_permission('asset_core', 'view')));
create policy asset_insert on public.asset
  for insert to authenticated
  with check (tenant_id = (select private.current_tenant_id())
              and (select private.has_permission('asset_core', 'create'))
              and (select private.tenant_can_write()));
create policy asset_update on public.asset
  for update to authenticated
  using (tenant_id = (select private.current_tenant_id())
         and (select private.has_permission('asset_core', 'update'))
         and (select private.tenant_can_write()))
  with check (tenant_id = (select private.current_tenant_id())
              and (select private.has_permission('asset_core', 'update'))
              and (select private.tenant_can_write()));

-- Column grants (§3, §5). RLS cannot hide columns: money and custom values are read through
-- asset_view only. status, location and tenant_id change only through actions.
revoke all on public.asset from anon, authenticated;
grant select (id, tenant_id, tag, name, category_id, location_id, status, status_reason, status_changed_at,
              quantity, parent_asset_id, criticality, serial_number, manufacturer, model, purchase_date,
              in_service_date, created_at, updated_at, created_by, updated_by, deleted_at)
  on public.asset to authenticated;
grant insert (id, tenant_id, tag, name, category_id, location_id, status, quantity, parent_asset_id, criticality,
              serial_number, manufacturer, model, purchase_date, purchase_value, purchase_currency,
              in_service_date, custom_values, created_by, updated_by)
  on public.asset to authenticated;
grant update (tag, name, category_id, quantity, parent_asset_id, criticality, serial_number, manufacturer, model,
              purchase_date, purchase_value, purchase_currency, in_service_date, custom_values, updated_by, deleted_at)
  on public.asset to authenticated;

-- A1: the only way a user changes the tag pattern (tenant has no user write grant, 2.5).
-- The Settings field is story 3.8. Writes its own audit row, as update_tenant_settings() does.
create function public.set_asset_tag_pattern(p_pattern text)
returns void language plpgsql security definer set search_path = '' as $$
declare
  v_tenant_id uuid := private.current_tenant_id();
  v_old       text;
begin
  if v_tenant_id is null
     or not private.has_permission('tenant_settings', 'manage')
     or not private.tenant_can_write() then
    raise exception 'not allowed to change tenant settings' using errcode = '42501';
  end if;

  select asset_tag_pattern into v_old from public.tenant where id = v_tenant_id;
  if v_old = p_pattern then
    return;
  end if;
  update public.tenant set asset_tag_pattern = p_pattern, updated_by = auth.uid() where id = v_tenant_id;

  insert into public.audit_log (tenant_id, category, actor_type, actor_user_id, action, table_name, record_id, old_data, new_data)
  values (v_tenant_id, 'data', 'user', auth.uid(), 'update', 'tenant', v_tenant_id,
          jsonb_build_object('asset_tag_pattern', v_old), jsonb_build_object('asset_tag_pattern', p_pattern));
  insert into private.outbox_event (tenant_id, event_type, aggregate_type, aggregate_id, payload)
  values (v_tenant_id, 'tenant.update', 'tenant', v_tenant_id,
          jsonb_build_object('old', jsonb_build_object('asset_tag_pattern', v_old),
                             'new', jsonb_build_object('asset_tag_pattern', p_pattern)));
end;
$$;
revoke all on function public.set_asset_tag_pattern(text) from public, anon;
grant execute on function public.set_asset_tag_pattern(text) to authenticated;
