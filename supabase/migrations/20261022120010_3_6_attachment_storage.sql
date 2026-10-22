-- Story 3.6: the private 'attachments' bucket and its storage.objects policies. data-model-goal3.md §17.2.
-- OWNER REVIEW (CLAUDE.md §9): file access.
-- Object path: <tenant_id>/asset/<asset_id>/<asset_attachment.id>. No file name in the path.
-- Users may upload (insert) and read (select, signed URLs). No update or delete policy: users can
-- never overwrite or remove a stored file. Removal is a soft delete of the asset_attachment row.

-- Z4, Z5: the bucket and its limits live here, so local and staging get the same from db push.
-- Storage itself refuses a bigger file or another type. No SVG or HTML: both can carry script.
insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values ('attachments', 'attachments', false, 10485760, array[
  'image/jpeg', 'image/png', 'image/webp', 'image/heic',
  'application/pdf',
  'application/msword', 'application/vnd.openxmlformats-officedocument.wordprocessingml.document',
  'application/vnd.ms-excel', 'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet',
  'application/vnd.ms-powerpoint', 'application/vnd.openxmlformats-officedocument.presentationml.presentation',
  'text/plain', 'text/csv'])
on conflict (id) do update
  set public = excluded.public, file_size_limit = excluded.file_size_limit, allowed_mime_types = excluded.allowed_mime_types;

-- Upload check for one object name. Parses the path with plain string functions (portable, not
-- storage.foldername) and casts only after the format check, so a bad path is refused, never an error.
create function private.can_upload_attachment(p_name text)
returns boolean language plpgsql stable security definer set search_path = '' as $$
declare
  v_uuid constant text := '[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}';
begin
  if p_name is null or p_name !~ ('^' || v_uuid || '/asset/' || v_uuid || '/' || v_uuid || '$') then
    return false;
  end if;
  return split_part(p_name, '/', 1)::uuid = private.current_tenant_id()
     and private.has_permission('asset_attachment', 'create')
     and private.tenant_can_write()
     -- A live asset of the current tenant. 6.1 adds the scope clause here.
     and exists (select 1 from public.asset a
                 where a.tenant_id = private.current_tenant_id()
                   and a.id = split_part(p_name, '/', 3)::uuid
                   and a.deleted_at is null);
end;
$$;
revoke all on function private.can_upload_attachment(text) from public, anon;
grant execute on function private.can_upload_attachment(text) to authenticated;

create policy attachments_insert on storage.objects
  for insert to authenticated
  with check (bucket_id = 'attachments' and private.can_upload_attachment(name));

-- Read (download, signed URL) only through a live attachment row the user can see. The row's own RLS
-- checks the tenant and asset_attachment.view, so a soft-deleted file, an orphan upload or another
-- tenant's path gives nothing.
create policy attachments_select on storage.objects
  for select to authenticated
  using (bucket_id = 'attachments'
         and exists (select 1 from public.asset_attachment a
                     where a.object_path = objects.name and a.deleted_at is null));
