-- Story 3.2: saved views on lists (owner decisions S2a, S3a, S4a, docs/data-model-goal3.md §13.3).
-- One table for every list (entity), assets first. Personal: each user sees and changes only their own.
-- 1.4 pattern on asset_core.view (S4a: a personal view is a preference, not asset data), plus the owner check.

create table public.saved_view (
  id          uuid primary key default gen_random_uuid(),
  tenant_id   uuid not null references public.tenant (id),
  user_id     uuid not null default auth.uid() references public.user_profile (id),
  entity      text not null check (entity in ('asset')),
  name        text not null check (btrim(name) <> '' and length(name) <= 100),
  -- {"q": text, "status": text, "category_id": uuid, "location_id": uuid}. The app drops unknown ids on load.
  filters     jsonb not null default '{}' check (jsonb_typeof(filters) = 'object'),
  sort        text not null default 'name' check (sort in ('name', 'tag', 'updated')),
  created_at  timestamptz not null default now(),
  updated_at  timestamptz not null default now(),
  created_by  uuid null references public.user_profile (id),
  updated_by  uuid null references public.user_profile (id),
  deleted_at  timestamptz null,
  unique (tenant_id, id),
  foreign key (tenant_id, user_id) references public.tenant_membership (tenant_id, user_id)
);
create unique index saved_view_name_uq on public.saved_view (tenant_id, user_id, entity, lower(name)) where deleted_at is null;

create trigger set_updated_at before update on public.saved_view
  for each row execute function private.set_updated_at();
create trigger check_soft_delete before update of deleted_at on public.saved_view
  for each row execute function private.check_soft_delete('asset_core', 'view');
create trigger audit after insert or update or delete on public.saved_view
  for each row execute function private.audit_row('data');

alter table public.saved_view enable row level security;

create policy saved_view_select on public.saved_view
  for select to authenticated
  using (tenant_id = (select private.current_tenant_id())
         and user_id = (select auth.uid())
         and (select private.has_permission('asset_core', 'view')));
create policy saved_view_insert on public.saved_view
  for insert to authenticated
  with check (tenant_id = (select private.current_tenant_id())
              and user_id = (select auth.uid())
              and (select private.has_permission('asset_core', 'view'))
              and (select private.tenant_can_write()));
create policy saved_view_update on public.saved_view
  for update to authenticated
  using (tenant_id = (select private.current_tenant_id())
         and user_id = (select auth.uid())
         and (select private.has_permission('asset_core', 'view'))
         and (select private.tenant_can_write()))
  with check (tenant_id = (select private.current_tenant_id())
              and user_id = (select auth.uid())
              and (select private.has_permission('asset_core', 'view'))
              and (select private.tenant_can_write()));

-- No hard delete: removal is a soft delete (update of deleted_at). tenant_id and user_id never change.
revoke all on public.saved_view from anon, authenticated;
grant select on public.saved_view to authenticated;
grant insert (id, tenant_id, user_id, entity, name, filters, sort, created_by, updated_by) on public.saved_view to authenticated;
grant update (name, filters, sort, updated_by, deleted_at) on public.saved_view to authenticated;
