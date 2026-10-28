-- Story 5.2b: service_record_attachment, files on a service record (a report, a certificate). data-model-goal5.md
-- §12.6, owner decision S9 a (28 Oct 2026): a copy of asset_attachment (3.6) with service_record_id. No new domain:
-- view service_record.view, upload service_record.create, remove service_record.update.
-- The file lives in the 3.6 bucket 'attachments' at object_path; 5_2b_attachment_storage ties every read to a live row.

create table public.service_record_attachment (
  id                uuid primary key default gen_random_uuid(),
  tenant_id         uuid not null references public.tenant (id),
  service_record_id uuid not null,
  -- Untrusted: shown as text only, never part of a path.
  file_name   text not null check (btrim(file_name) <> '' and length(file_name) <= 255 and file_name !~ '[/\\[:cntrl:]]'),
  -- Both copied from the stored object by the insert trigger, never taken from the client.
  mime_type   text not null,
  size_bytes  bigint not null check (size_bytes >= 0),
  object_path text generated always as (tenant_id::text || '/service_record/' || service_record_id::text || '/' || id::text) stored,
  created_at  timestamptz not null default now(),
  updated_at  timestamptz not null default now(),
  created_by  uuid null default auth.uid() references public.user_profile (id),
  updated_by  uuid null references public.user_profile (id),
  deleted_at  timestamptz null,
  unique (tenant_id, id),
  unique (object_path),
  foreign key (tenant_id, service_record_id) references public.service_record (tenant_id, id)
);
create index service_record_attachment_record_idx on public.service_record_attachment (tenant_id, service_record_id, created_at desc) where deleted_at is null;

-- Same as private.check_attachment_object (3.6) for this path: the object must already be uploaded (Z6), by the caller.
-- shortcut: reads Supabase's storage.objects, the one Supabase-only piece; a move off Supabase rewrites this function.
create function private.check_service_attachment_object()
returns trigger language plpgsql security definer set search_path = '' as $$
declare
  v_meta jsonb;
begin
  select o.metadata into v_meta
  from storage.objects o
  where o.bucket_id = 'attachments'
    and o.name = new.tenant_id::text || '/service_record/' || new.service_record_id::text || '/' || new.id::text
    and (auth.uid() is null or o.owner_id = auth.uid()::text);
  if v_meta is null then
    raise exception 'attachment file not found' using errcode = '23503';
  end if;
  new.mime_type  := v_meta ->> 'mimetype';
  new.size_bytes := (v_meta ->> 'size')::bigint;
  return new;
end;
$$;
revoke all on function private.check_service_attachment_object() from public, anon, authenticated;

create trigger check_attachment_object before insert on public.service_record_attachment
  for each row execute function private.check_service_attachment_object();
create trigger set_updated_at before update on public.service_record_attachment
  for each row execute function private.set_updated_at();
create trigger check_soft_delete before update of deleted_at on public.service_record_attachment
  for each row execute function private.check_soft_delete('service_record', 'update');
create trigger audit after insert or update or delete on public.service_record_attachment
  for each row execute function private.audit_row('data');

-- Soft-deleted rows stay readable (history); the app and the storage read policy filter them.
-- 6.1 adds the same scope clause as service_record (on its asset).
alter table public.service_record_attachment enable row level security;

create policy service_record_attachment_select on public.service_record_attachment
  for select to authenticated
  using (tenant_id = (select private.current_tenant_id())
         and (select private.has_permission('service_record', 'view')));
create policy service_record_attachment_insert on public.service_record_attachment
  for insert to authenticated
  with check (tenant_id = (select private.current_tenant_id())
              and (select private.has_permission('service_record', 'create'))
              and (select private.tenant_can_write()));
-- The only user update is the soft delete.
create policy service_record_attachment_update on public.service_record_attachment
  for update to authenticated
  using (tenant_id = (select private.current_tenant_id())
         and (select private.has_permission('service_record', 'update'))
         and (select private.tenant_can_write()))
  with check (tenant_id = (select private.current_tenant_id())
              and (select private.has_permission('service_record', 'update'))
              and (select private.tenant_can_write()));

revoke all on public.service_record_attachment from anon, authenticated;
grant select on public.service_record_attachment to authenticated;
grant insert (id, tenant_id, service_record_id, file_name) on public.service_record_attachment to authenticated;
grant update (updated_by, deleted_at) on public.service_record_attachment to authenticated;

-- Live files of one service record, newest first. Invoker, so the RLS above decides.
create function public.service_record_attachments(p_service_record_id uuid)
returns table (id uuid, file_name text, mime_type text, size_bytes bigint, created_at timestamptz, uploaded_by text)
language sql stable set search_path = '' as $$
  select a.id, a.file_name, a.mime_type, a.size_bytes, a.created_at, private.member_name(a.created_by)
  from public.service_record_attachment a
  where a.service_record_id = p_service_record_id and a.deleted_at is null
  order by a.created_at desc, a.id
$$;
revoke all on function public.service_record_attachments(uuid) from public, anon;
grant execute on function public.service_record_attachments(uuid) to authenticated;
