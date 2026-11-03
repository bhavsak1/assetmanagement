-- Story 8.2: staged import rows. docs/data-model-goal8.md §13.
-- OWNER REVIEW (CLAUDE.md §9): RLS policies.
-- The service (POST /imports) parses an .xlsx file and inserts one import_batch and its import_row rows
-- under the user's token. Domain: the catalog's excel_import action domain (run, review, commit), 1.2.
-- Rows are written once (I10): insert policies only, no update or delete for users. 8.3 to 8.6 change
-- them through action functions.

create table public.import_batch (
  id          uuid primary key default gen_random_uuid(),
  tenant_id   uuid not null references public.tenant (id),
  file_name   text not null check (length(file_name) between 1 and 255),
  file_size   int not null check (file_size > 0),
  file_sha256 text not null check (file_sha256 ~ '^[0-9a-f]{64}$'),
  sheet_name  text not null,
  sheet_names text[] not null,
  header_row  int not null check (header_row >= 1),
  columns     text[] not null,
  row_count   int not null check (row_count >= 0),
  warnings    jsonb not null default '{"list": [], "total": 0}',
  -- Hook (§13.6): 8.3 to 8.6 add mapped, validated, committed, undone in their own migrations.
  status      text not null default 'staged' check (status in ('staged', 'expired')),
  expires_at  timestamptz not null default now() + interval '30 days',
  created_at  timestamptz not null default now(),
  updated_at  timestamptz not null default now(),
  created_by  uuid null default auth.uid() references public.user_profile (id),
  updated_by  uuid null references public.user_profile (id),
  deleted_at  timestamptz null,
  unique (tenant_id, id)
);
create index import_batch_recent_idx on public.import_batch (tenant_id, created_at desc);
create index import_batch_expiry_idx on public.import_batch (expires_at) where status = 'staged';

-- A scratch copy of the sheet, not a business record (I9): no soft delete, no audit (I11).
create table public.import_row (
  id         uuid primary key default gen_random_uuid(),
  tenant_id  uuid not null references public.tenant (id),
  batch_id   uuid not null,
  row_number int not null check (row_number >= 1),  -- the Excel row number, so errors point at the real row
  cells      jsonb not null check (jsonb_typeof(cells) = 'array'),
  created_at timestamptz not null default now(),
  unique (tenant_id, id),
  unique (batch_id, row_number),
  -- Deferred: the service inserts the rows first and the batch, with its final counts, last (one transaction).
  foreign key (tenant_id, batch_id) references public.import_batch (tenant_id, id) deferrable initially deferred
);

create trigger set_updated_at before update on public.import_batch
  for each row execute function private.set_updated_at();
create trigger audit after insert or update or delete on public.import_batch
  for each row execute function private.audit_row('data');

alter table public.import_batch enable row level security;
alter table public.import_row enable row level security;

create policy import_batch_select on public.import_batch
  for select to authenticated
  using (tenant_id = (select private.current_tenant_id())
         and ((select private.has_permission('excel_import', 'run'))
              or (select private.has_permission('excel_import', 'review'))));
create policy import_batch_insert on public.import_batch
  for insert to authenticated
  with check (tenant_id = (select private.current_tenant_id())
              and (select private.has_permission('excel_import', 'run'))
              and (select private.tenant_can_write()));

create policy import_row_select on public.import_row
  for select to authenticated
  using (tenant_id = (select private.current_tenant_id())
         and ((select private.has_permission('excel_import', 'run'))
              or (select private.has_permission('excel_import', 'review'))));
create policy import_row_insert on public.import_row
  for insert to authenticated
  with check (tenant_id = (select private.current_tenant_id())
              and (select private.has_permission('excel_import', 'run'))
              and (select private.tenant_can_write()));

revoke update, delete, truncate on public.import_batch, public.import_row from anon, authenticated;

-- I9: staged rows of uncommitted batches go after 30 days; the batch stays as history.
create function private.purge_expired_imports()
returns void language plpgsql set search_path = '' as $$
begin
  delete from public.import_row r
  using public.import_batch b
  where b.tenant_id = r.tenant_id and b.id = r.batch_id
    and b.status = 'staged' and b.expires_at <= now();
  update public.import_batch set status = 'expired'
  where status = 'staged' and expires_at <= now();
end;
$$;
revoke all on function private.purge_expired_imports() from public, anon, authenticated;

select cron.schedule('assetly_purge_expired_imports', '17 3 * * *', 'select private.purge_expired_imports()');
