-- Story 4.1: vendor contacts. docs/data-model-goal4.md §2. 1.4 RLS pattern on vendor_core
-- ("Vendor records and contacts"): anyone who sees the vendor sees its contacts (V4). Adding,
-- editing and removing a contact is editing the vendor, so all three need vendor_core.update (V7).

create table public.vendor_contact (
  id         uuid primary key default gen_random_uuid(),
  tenant_id  uuid not null references public.tenant (id),
  vendor_id  uuid not null,
  name       text not null check (length(btrim(name)) between 1 and 200),
  title      text null check (length(title) <= 200),
  phone      text null check (length(phone) <= 50),
  email      text null check (length(email) <= 254 and email ~ '^[^@\s]+@[^@\s]+$'),
  is_primary boolean not null default false,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  created_by uuid null references public.user_profile (id),
  updated_by uuid null references public.user_profile (id),
  deleted_at timestamptz null,
  unique (tenant_id, id),
  foreign key (tenant_id, vendor_id) references public.vendor (tenant_id, id)
);

create index vendor_contact_vendor_idx on public.vendor_contact (tenant_id, vendor_id) where deleted_at is null;
create unique index vendor_contact_primary_uq on public.vendor_contact (tenant_id, vendor_id)
  where is_primary and deleted_at is null;

-- One live primary per vendor: a new primary clears the old one, so the UI does one write.
-- Runs as the caller: the clearing update needs the same vendor_core.update the write already needs.
create function private.clear_other_primary()
returns trigger language plpgsql set search_path = '' as $$
begin
  if new.is_primary and new.deleted_at is null then
    update public.vendor_contact set is_primary = false
    where tenant_id = new.tenant_id and vendor_id = new.vendor_id and id <> new.id
      and is_primary and deleted_at is null;
  end if;
  return new;
end;
$$;
revoke all on function private.clear_other_primary() from public, anon;
grant execute on function private.clear_other_primary() to authenticated;

create trigger clear_other_primary before insert or update of is_primary on public.vendor_contact
  for each row execute function private.clear_other_primary();
create trigger check_soft_delete before update of deleted_at on public.vendor_contact
  for each row execute function private.check_soft_delete('vendor_core', 'update');
create trigger set_updated_at before update on public.vendor_contact
  for each row execute function private.set_updated_at();
create trigger audit after insert or update or delete on public.vendor_contact
  for each row execute function private.audit_row('data');

alter table public.vendor_contact enable row level security;

create policy vendor_contact_select on public.vendor_contact
  for select to authenticated
  using (tenant_id = (select private.current_tenant_id())
         and (select private.has_permission('vendor_core', 'view')));
create policy vendor_contact_insert on public.vendor_contact
  for insert to authenticated
  with check (tenant_id = (select private.current_tenant_id())
              and (select private.has_permission('vendor_core', 'update'))
              and (select private.tenant_can_write()));
create policy vendor_contact_update on public.vendor_contact
  for update to authenticated
  using (tenant_id = (select private.current_tenant_id())
         and (select private.has_permission('vendor_core', 'update'))
         and (select private.tenant_can_write()))
  with check (tenant_id = (select private.current_tenant_id())
              and (select private.has_permission('vendor_core', 'update'))
              and (select private.tenant_can_write()));

-- vendor_id never changes: a contact belongs to one vendor (the 4.1b merge moves them as postgres).
revoke all on public.vendor_contact from anon, authenticated;
grant select on public.vendor_contact to authenticated;
grant insert (id, tenant_id, vendor_id, name, title, phone, email, is_primary, created_by, updated_by)
  on public.vendor_contact to authenticated;
grant update (name, title, phone, email, is_primary, updated_by, deleted_at)
  on public.vendor_contact to authenticated;
