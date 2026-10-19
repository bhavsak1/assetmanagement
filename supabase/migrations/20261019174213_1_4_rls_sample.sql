-- Story 1.4: the RLS pattern. Copy this file for every new tenant table (CLAUDE.md §7 "The RLS pattern").
-- rls_sample is a template, not business data. The data model names no sample table, so it is named
-- for what it is. Its tests are supabase/tests/1_4_rls_sample.test.sql.

-- 1. Domain as data (CLAUDE.md §7.10). Re-running inserts nothing new.
insert into public.security_domain (code, entity, kind, description)
values ('rls_sample', 'rls_sample', 'entity', 'Template table for the RLS pattern (story 1.4). Not business data')
on conflict (code) do nothing;
insert into public.domain_operation (security_domain_id, code, sort_order)
select d.id, o.code, o.sort_order
from (values ('view', 1), ('create', 2), ('update', 3), ('delete', 4)) as o (code, sort_order)
join public.security_domain d on d.code = 'rls_sample'
on conflict (security_domain_id, code) do nothing;

-- 2. Table: std columns, unique (tenant_id, id), composite same-tenant FKs, partial uniques.
create table public.rls_sample (
  id         uuid primary key default gen_random_uuid(),
  tenant_id  uuid not null references public.tenant (id),
  parent_id  uuid null,
  name       text not null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  created_by uuid null references public.user_profile (id),
  updated_by uuid null references public.user_profile (id),
  deleted_at timestamptz null,
  unique (tenant_id, id),
  -- Composite: a row can never point at another tenant's row.
  foreign key (tenant_id, parent_id) references public.rls_sample (tenant_id, id)
);
create unique index rls_sample_name_uq on public.rls_sample (tenant_id, name) where deleted_at is null;

create trigger set_updated_at before update on public.rls_sample
  for each row execute function private.set_updated_at();
create trigger check_soft_delete before update of deleted_at on public.rls_sample
  for each row execute function private.check_soft_delete('rls_sample', 'delete');

-- 3. RLS on, one policy per command. Soft-deleted rows stay readable (history); the app filters them.
alter table public.rls_sample enable row level security;

create policy rls_sample_select on public.rls_sample
  for select to authenticated
  using (tenant_id = (select private.current_tenant_id())
         and (select private.has_permission('rls_sample', 'view')));
create policy rls_sample_insert on public.rls_sample
  for insert to authenticated
  with check (tenant_id = (select private.current_tenant_id())
              and (select private.has_permission('rls_sample', 'create'))
              and (select private.tenant_can_write()));
create policy rls_sample_update on public.rls_sample
  for update to authenticated
  using (tenant_id = (select private.current_tenant_id())
         and (select private.has_permission('rls_sample', 'update'))
         and (select private.tenant_can_write()))
  with check (tenant_id = (select private.current_tenant_id())
              and (select private.has_permission('rls_sample', 'update'))
              and (select private.tenant_can_write()));

-- 4. No delete policy: soft delete only (CLAUDE.md §8). A removal is an update of deleted_at,
-- which the trigger above also checks against the delete operation.
revoke delete, truncate on public.rls_sample from anon, authenticated;
