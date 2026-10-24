-- Story 4.1: vendors. Design and owner decisions V1 to V7: docs/data-model-goal4.md.
-- 1.4 RLS pattern on the existing catalog domain vendor_core. Roles are a fixed system list (V3).
-- Tax IDs (GSTIN, PAN) are vendor custom fields in vendor_tax_ids (V1), read only through vendor_view.

create table public.vendor (
  id            uuid primary key default gen_random_uuid(),
  tenant_id     uuid not null references public.tenant (id),
  name          text not null check (length(name) between 1 and 200),
  code          text null check (code ~ '^[A-Z0-9._-]{1,20}$'),
  roles         text[] not null default '{}' check (roles <@ array['oem', 'om', 'supplier']),
  phone         text null check (length(phone) <= 50),
  email         text null check (length(email) <= 254 and email ~ '^[^@\s]+@[^@\s]+$'),
  website       text null check (length(website) <= 200),
  address       text null check (length(address) <= 1000),
  notes         text null check (length(notes) <= 2000),
  -- Deactivate, never delete (CLAUDE.md §8, L2 a). deleted_at is for the 4.1b merge and mistakes.
  is_active     boolean not null default true,
  custom_values jsonb not null default '{}' check (jsonb_typeof(custom_values) = 'object'),
  created_at    timestamptz not null default now(),
  updated_at    timestamptz not null default now(),
  created_by    uuid null references public.user_profile (id),
  updated_by    uuid null references public.user_profile (id),
  deleted_at    timestamptz null,
  unique (tenant_id, id)
);

-- A deactivated vendor keeps its name, so no near-duplicate is added beside it.
create unique index vendor_name_uq on public.vendor (tenant_id, lower(name)) where deleted_at is null;
create unique index vendor_code_uq on public.vendor (tenant_id, code) where code is not null and deleted_at is null;
create index vendor_name_idx on public.vendor (tenant_id, name, id) where deleted_at is null;

-- Write rules (data-model-goal4.md §3): tidy name, code and roles; custom values as on asset (goal3 §4.1),
-- without a category line: every vendor field applies to every vendor.
create function private.check_vendor_values()
returns trigger language plpgsql security definer set search_path = '' as $$
declare
  v_user    boolean := auth.uid() is not null;
  v_old     jsonb   := case when tg_op = 'UPDATE' then old.custom_values else '{}' end;
  v_hidden  text[];
  v_key     text;
  v_value   jsonb;
  v_missing text[];
  f         record;
  -- Changing only these is not a save, so mandatory fields wait (deactivate, soft delete).
  v_skip    text[]  := array['is_active', 'created_at', 'created_by', 'updated_at', 'updated_by', 'deleted_at'];
begin
  new.name  := btrim(new.name);
  new.code  := upper(nullif(btrim(new.code), ''));
  new.roles := array(select distinct r from unnest(new.roles) r order by r);

  -- A form never saw the keys the user cannot view, so it cannot change or blank them.
  if v_user then
    v_hidden := private.hidden_field_keys('vendor');
    new.custom_values := (new.custom_values - v_hidden)
      || coalesce((select jsonb_object_agg(o.key, o.value) from jsonb_each(v_old) o where o.key = any (v_hidden)), '{}');
  end if;

  for v_key, v_value in select o.key, o.value from jsonb_each(new.custom_values) o loop
    select fd.type, fd.options, fd.is_active, fd.deleted_at, d.code as domain_code
      into f
    from public.field_definition fd
    join public.security_domain d on d.id = fd.security_domain_id
    where fd.tenant_id = new.tenant_id and fd.entity = 'vendor' and fd.key = v_key;
    if not found then
      raise exception 'unknown custom field: %', v_key using errcode = '22023';
    end if;
    continue when v_old -> v_key is not distinct from v_value;
    if f.deleted_at is not null or not f.is_active then
      raise exception 'custom field % is inactive', v_key using errcode = '22023';
    end if;
    if not private.custom_value_ok(f.type, f.options, v_value) then
      raise exception 'custom field % needs a % value', v_key, f.type using errcode = '22023';
    end if;
    if v_user and not private.has_permission(f.domain_code, 'update') then
      raise exception 'no permission to change custom field %', v_key using errcode = '42501';
    end if;
  end loop;

  -- Mandatory: on insert and on a user save that changes data. Skip fields the user cannot write (M2).
  if v_user and new.deleted_at is null
     and (tg_op = 'INSERT' or (to_jsonb(new) - v_skip) is distinct from (to_jsonb(old) - v_skip)) then
    select array_agg(fd.key order by fd.key) into v_missing
    from public.field_definition fd
    join public.security_domain d on d.id = fd.security_domain_id
    where fd.tenant_id = new.tenant_id and fd.entity = 'vendor' and fd.is_required and fd.is_active
      and fd.deleted_at is null and not new.custom_values ? fd.key
      and private.has_permission(d.code, 'update');
    if v_missing is not null then
      raise exception 'missing mandatory fields: %', array_to_string(v_missing, ', ') using errcode = '23502';
    end if;
  end if;
  return new;
end;
$$;
revoke all on function private.check_vendor_values() from public, anon, authenticated;

-- Before triggers fire by name: values, soft delete, updated_at, then the pattern check.
create trigger check_vendor_values before insert or update on public.vendor
  for each row execute function private.check_vendor_values();
create trigger check_soft_delete before update of deleted_at on public.vendor
  for each row execute function private.check_soft_delete('vendor_core', 'delete');
create trigger set_updated_at before update on public.vendor
  for each row execute function private.set_updated_at();
create trigger validate_field_pattern before insert or update of custom_values on public.vendor
  for each row execute function private.validate_field_pattern('vendor');
create trigger audit after insert or update or delete on public.vendor
  for each row execute function private.audit_row('data');

-- RLS, 1.4 pattern. Deactivate and roles are plain updates.
alter table public.vendor enable row level security;

create policy vendor_select on public.vendor
  for select to authenticated
  using (tenant_id = (select private.current_tenant_id())
         and (select private.has_permission('vendor_core', 'view')));
create policy vendor_insert on public.vendor
  for insert to authenticated
  with check (tenant_id = (select private.current_tenant_id())
              and (select private.has_permission('vendor_core', 'create'))
              and (select private.tenant_can_write()));
create policy vendor_update on public.vendor
  for update to authenticated
  using (tenant_id = (select private.current_tenant_id())
         and (select private.has_permission('vendor_core', 'update'))
         and (select private.tenant_can_write()))
  with check (tenant_id = (select private.current_tenant_id())
              and (select private.has_permission('vendor_core', 'update'))
              and (select private.tenant_can_write()));

-- RLS cannot hide columns: custom values (tax IDs among them) are read through vendor_view only.
revoke all on public.vendor from anon, authenticated;
grant select (id, tenant_id, name, code, roles, phone, email, website, address, notes, is_active,
              created_at, updated_at, created_by, updated_by, deleted_at)
  on public.vendor to authenticated;
grant insert (id, tenant_id, name, code, roles, phone, email, website, address, notes, is_active,
              custom_values, created_by, updated_by)
  on public.vendor to authenticated;
grant update (name, code, roles, phone, email, website, address, notes, is_active, custom_values,
              updated_by, deleted_at)
  on public.vendor to authenticated;

-- The app reads vendors only here. Same shape and reasons as asset_view (3.1 A6): owner-run so it can
-- read custom_values, the where clause repeats the base select policy, live rows only, and not
-- security_barrier so `order by name limit 50` walks vendor_name_idx. Owner review item.
create view public.vendor_view as
  select v.id, v.tenant_id, v.name, v.code, v.roles, v.phone, v.email, v.website, v.address, v.notes,
         v.is_active,
         v.custom_values - (select private.hidden_field_keys('vendor')) as custom_values,
         v.created_at, v.updated_at, v.created_by, v.updated_by
  from public.vendor v
  where v.tenant_id = (select private.current_tenant_id())
    and (select private.has_permission('vendor_core', 'view'))
    and v.deleted_at is null;
revoke all on public.vendor_view from public, anon, authenticated;
grant select on public.vendor_view to authenticated;
