-- Story 2.1: asset_category, a per-tenant tree (data-model-goal2.md §1.1, G1, G2).
-- 1.4 RLS pattern with the existing catalog domain category_config (view, manage). No new domain.

create table public.asset_category (
  id          uuid primary key default gen_random_uuid(),
  tenant_id   uuid not null references public.tenant (id),
  parent_id   uuid null,
  name        text not null,
  description text null,
  -- Deactivate, never delete (CLAUDE.md §8). deleted_at is for the later merge function.
  is_active   boolean not null default true,
  created_at  timestamptz not null default now(),
  updated_at  timestamptz not null default now(),
  created_by  uuid null references public.user_profile (id),
  updated_by  uuid null references public.user_profile (id),
  deleted_at  timestamptz null,
  unique (tenant_id, id),
  foreign key (tenant_id, parent_id) references public.asset_category (tenant_id, id)
);
create unique index asset_category_name_uq on public.asset_category (tenant_id, lower(name)) where deleted_at is null;
create index asset_category_parent_idx on public.asset_category (tenant_id, parent_id);

-- Refuse a parent change that makes a cycle. Definer so it sees every ancestor, whatever the
-- caller's grants; it only reads parent_id within the row's own tenant.
create function private.check_category_cycle()
returns trigger language plpgsql security definer set search_path = '' as $$
begin
  if new.parent_id is not null and exists (
    with recursive up as (
      select c.id, c.parent_id from public.asset_category c
      where c.tenant_id = new.tenant_id and c.id = new.parent_id
      union
      select c.id, c.parent_id from public.asset_category c
      join up on c.tenant_id = new.tenant_id and c.id = up.parent_id
    )
    select 1 from up where up.id = new.id
  ) then
    raise exception 'category cannot be its own ancestor' using errcode = '23514';
  end if;
  return new;
end;
$$;
revoke all on function private.check_category_cycle() from public, anon, authenticated;

create trigger check_category_cycle before update of parent_id on public.asset_category
  for each row execute function private.check_category_cycle();
create trigger set_updated_at before update on public.asset_category
  for each row execute function private.set_updated_at();
create trigger check_soft_delete before update of deleted_at on public.asset_category
  for each row execute function private.check_soft_delete('category_config', 'manage');
create trigger audit after insert or update or delete on public.asset_category
  for each row execute function private.audit_row('data');

alter table public.asset_category enable row level security;

create policy asset_category_select on public.asset_category
  for select to authenticated
  using (tenant_id = (select private.current_tenant_id())
         and (select private.has_permission('category_config', 'view')));
create policy asset_category_insert on public.asset_category
  for insert to authenticated
  with check (tenant_id = (select private.current_tenant_id())
              and (select private.has_permission('category_config', 'manage'))
              and (select private.tenant_can_write()));
create policy asset_category_update on public.asset_category
  for update to authenticated
  using (tenant_id = (select private.current_tenant_id())
         and (select private.has_permission('category_config', 'manage'))
         and (select private.tenant_can_write()))
  with check (tenant_id = (select private.current_tenant_id())
              and (select private.has_permission('category_config', 'manage'))
              and (select private.tenant_can_write()));

revoke delete, truncate on public.asset_category from anon, authenticated;
