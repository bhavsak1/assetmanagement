-- Story 3.7 (A2): tenant asset statuses, each mapped to one of the 5 fixed system statuses.
-- Design and owner decisions R0 to R8: docs/data-model-goal3.md §18. 1.4 RLS pattern on the
-- existing domain category_config (R6). Deactivate, never delete (CLAUDE.md §8).

create table public.asset_status (
  id            uuid primary key default gen_random_uuid(),
  tenant_id     uuid not null references public.tenant (id),
  -- Never changes, never reused (like field keys, G4): saved views, imports and the API use it.
  code          text not null check (code ~ '^[a-z][a-z0-9_]{0,39}$'),
  label         text not null check (btrim(label) <> '' and length(label) <= 60),
  -- Never changes: asset (tenant_id, status_id, status) references (tenant_id, id, system_status).
  system_status text not null check (system_status in ('in_stock', 'active', 'under_maintenance', 'inactive', 'disposed')),
  -- The 4 tag tones in tokens.css (R5).
  tone          text not null default 'neutral' check (tone in ('ok', 'warn', 'error', 'neutral')),
  is_active     boolean not null default true,
  created_at    timestamptz not null default now(),
  updated_at    timestamptz not null default now(),
  created_by    uuid null references public.user_profile (id),
  updated_by    uuid null references public.user_profile (id),
  deleted_at    timestamptz null,
  unique (tenant_id, id),
  unique (tenant_id, id, system_status),
  -- All rows, deleted or not: a code never takes a new meaning.
  unique (tenant_id, code),
  -- A system code names the default row of that system status only (R3).
  check (code not in ('in_stock', 'active', 'under_maintenance', 'inactive', 'disposed') or code = system_status)
);
create unique index asset_status_label_uq on public.asset_status (tenant_id, lower(label)) where deleted_at is null;

-- code and system_status never change; the default row of each system status (code = system_status)
-- stays active and live, so a system status always has somewhere to map (R3).
create function private.check_asset_status_row()
returns trigger language plpgsql set search_path = '' as $$
begin
  if new.code <> old.code or new.system_status <> old.system_status then
    raise exception 'status code and system status cannot change' using errcode = '22023';
  end if;
  if new.code = new.system_status and (not new.is_active or new.deleted_at is not null) then
    raise exception 'the default status of a system status cannot be deactivated' using errcode = '22023';
  end if;
  return new;
end;
$$;
revoke all on function private.check_asset_status_row() from public, anon, authenticated;

create trigger check_asset_status_row before update on public.asset_status
  for each row execute function private.check_asset_status_row();
create trigger set_updated_at before update on public.asset_status
  for each row execute function private.set_updated_at();
create trigger check_soft_delete before update of deleted_at on public.asset_status
  for each row execute function private.check_soft_delete('category_config', 'manage');
create trigger audit after insert or update or delete on public.asset_status
  for each row execute function private.audit_row('data');

alter table public.asset_status enable row level security;

-- Anyone who sees an asset must see its status label (R6); labels are not sensitive.
create policy asset_status_select on public.asset_status
  for select to authenticated
  using (tenant_id = (select private.current_tenant_id())
         and ((select private.has_permission('category_config', 'view'))
              or (select private.has_permission('asset_core', 'view'))));
create policy asset_status_insert on public.asset_status
  for insert to authenticated
  with check (tenant_id = (select private.current_tenant_id())
              and (select private.has_permission('category_config', 'manage'))
              and (select private.tenant_can_write()));
create policy asset_status_update on public.asset_status
  for update to authenticated
  using (tenant_id = (select private.current_tenant_id())
         and (select private.has_permission('category_config', 'manage'))
         and (select private.tenant_can_write()))
  with check (tenant_id = (select private.current_tenant_id())
              and (select private.has_permission('category_config', 'manage'))
              and (select private.tenant_can_write()));

revoke all on public.asset_status from anon, authenticated;
grant select on public.asset_status to authenticated;
grant insert (id, tenant_id, code, label, system_status, tone, is_active, created_by, updated_by) on public.asset_status to authenticated;
grant update (label, tone, is_active, updated_by, deleted_at) on public.asset_status to authenticated;

-- The 5 default rows of a tenant (R3). Idempotent. Tones as the 3.2 list tags.
create function private.seed_asset_statuses(p_tenant_id uuid)
returns void language sql security definer set search_path = '' as $$
  insert into public.asset_status (tenant_id, code, label, system_status, tone)
  select p_tenant_id, s.code, s.label, s.code, s.tone
  from (values ('in_stock', 'In Stock', 'neutral'), ('active', 'Active', 'ok'),
               ('under_maintenance', 'Under maintenance', 'warn'), ('inactive', 'Inactive', 'neutral'),
               ('disposed', 'Disposed', 'error')) as s (code, label, tone)
  on conflict (tenant_id, code) do nothing;
$$;
revoke all on function private.seed_asset_statuses(uuid) from public, anon, authenticated;

-- Every tenant, however it is made (provisioning, seed, tests), has its default statuses (R7).
create function private.seed_tenant_statuses()
returns trigger language plpgsql security definer set search_path = '' as $$
begin
  perform private.seed_asset_statuses(new.id);
  return null;
end;
$$;
revoke all on function private.seed_tenant_statuses() from public, anon, authenticated;

create trigger seed_asset_statuses after insert on public.tenant
  for each row execute function private.seed_tenant_statuses();

select private.seed_asset_statuses(id) from public.tenant;
