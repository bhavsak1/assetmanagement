-- Story 2.3: the location tree. Design and owner decisions L1 to L4: docs/data-model-goal2-locations.md.
-- 1.4 RLS pattern. Domain location_hierarchy (view, manage) is already in the 1.2 catalog seed.
-- The closure table and its triggers are the next migration (2_3_location_closure).

create table public.location (
  id            uuid primary key default gen_random_uuid(),
  tenant_id     uuid not null references public.tenant (id),
  parent_id     uuid null,
  name          text not null,
  code          text null,
  location_type text null,                       -- L1: free text, data not an enum
  active        boolean not null default true,  -- L2: deactivate; deleted_at is for merge or mistakes
  created_at    timestamptz not null default now(),
  updated_at    timestamptz not null default now(),
  created_by    uuid null references public.user_profile (id),
  updated_by    uuid null references public.user_profile (id),
  deleted_at    timestamptz null,
  unique (tenant_id, id),
  foreign key (tenant_id, parent_id) references public.location (tenant_id, id)
);
-- Names unique among siblings (roots too: nulls not distinct). Also serves "children of X".
create unique index location_sibling_name_uq on public.location (tenant_id, parent_id, name)
  nulls not distinct where deleted_at is null;
create unique index location_code_uq on public.location (tenant_id, code)
  where code is not null and deleted_at is null;

-- Tree rules (L2). Invariant: an active row has an active, live parent. So "an active descendant"
-- is the same as "an active child", and only direct children need checking.
-- security definer: the check must see every row of the tenant, not only the rows RLS shows.
create function private.check_location_rules()
returns trigger language plpgsql security definer set search_path = '' as $$
begin
  if new.parent_id is not null and (tg_op = 'INSERT' or new.parent_id is distinct from old.parent_id
                                    or (new.active and not old.active)) then
    if exists (select 1 from public.location p
               where p.tenant_id = new.tenant_id and p.id = new.parent_id
                 and (p.deleted_at is not null or (new.active and not p.active))) then
      raise exception 'parent location is inactive or deleted' using errcode = '23514';
    end if;
  end if;

  if tg_op = 'UPDATE' and old.active and not new.active
     and exists (select 1 from public.location c
                 where c.tenant_id = new.tenant_id and c.parent_id = new.id and c.active and c.deleted_at is null) then
    raise exception 'deactivate the child locations first' using errcode = '23514';
  end if;

  if tg_op = 'UPDATE' and old.deleted_at is null and new.deleted_at is not null
     and exists (select 1 from public.location c
                 where c.tenant_id = new.tenant_id and c.parent_id = new.id and c.deleted_at is null) then
    raise exception 'location still has child locations' using errcode = '23514';
  end if;
  return new;
end;
$$;
revoke all on function private.check_location_rules() from public, anon, authenticated;

create trigger set_updated_at before update on public.location
  for each row execute function private.set_updated_at();
create trigger check_soft_delete before update of deleted_at on public.location
  for each row execute function private.check_soft_delete('location_hierarchy', 'manage');
create trigger check_location_rules before insert or update on public.location
  for each row execute function private.check_location_rules();
create trigger audit after insert or update or delete on public.location
  for each row execute function private.audit_row('data');

-- RLS: view reads; manage writes (insert, edit, move, deactivate, soft delete).
alter table public.location enable row level security;

create policy location_select on public.location
  for select to authenticated
  using (tenant_id = (select private.current_tenant_id())
         and (select private.has_permission('location_hierarchy', 'view')));
create policy location_insert on public.location
  for insert to authenticated
  with check (tenant_id = (select private.current_tenant_id())
              and (select private.has_permission('location_hierarchy', 'manage'))
              and (select private.tenant_can_write()));
create policy location_update on public.location
  for update to authenticated
  using (tenant_id = (select private.current_tenant_id())
         and (select private.has_permission('location_hierarchy', 'manage'))
         and (select private.tenant_can_write()))
  with check (tenant_id = (select private.current_tenant_id())
              and (select private.has_permission('location_hierarchy', 'manage'))
              and (select private.tenant_can_write()));

-- Deactivated or soft deleted, never hard deleted (CLAUDE.md §8).
revoke delete, truncate on public.location from anon, authenticated;
