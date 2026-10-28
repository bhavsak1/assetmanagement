-- Story 5.2b: the 'attachments' storage policies take a second entity, service_record. data-model-goal5.md §12.6.
-- OWNER REVIEW (CLAUDE.md §9): file access. The 3.6 migration stays as applied; this replaces its upload check and
-- read policy. The asset branch is unchanged. Still no update or delete policy on storage.objects.
-- Paths: <tenant_id>/asset/<asset_id>/<asset_attachment.id>
--        <tenant_id>/service_record/<service_record_id>/<service_record_attachment.id>

create or replace function private.can_upload_attachment(p_name text)
returns boolean language plpgsql stable security definer set search_path = '' as $$
declare
  v_uuid constant text := '[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}';
  v_id   uuid;
begin
  if p_name is null or p_name !~ ('^' || v_uuid || '/(asset|service_record)/' || v_uuid || '/' || v_uuid || '$') then
    return false;
  end if;
  v_id := split_part(p_name, '/', 3)::uuid;
  -- A null anywhere (no tenant claim) makes the whole result null, which the policy treats as refused.
  return split_part(p_name, '/', 1)::uuid = private.current_tenant_id()
     and private.tenant_can_write()
     and case split_part(p_name, '/', 2)
           -- A live asset of the current tenant. 6.1 adds the scope clause here.
           when 'asset' then private.has_permission('asset_attachment', 'create')
             and exists (select 1 from public.asset a
                         where a.tenant_id = private.current_tenant_id() and a.id = v_id and a.deleted_at is null)
           -- A live (not undone) service record of the current tenant.
           when 'service_record' then private.has_permission('service_record', 'create')
             and exists (select 1 from public.service_record r
                         where r.tenant_id = private.current_tenant_id() and r.id = v_id and r.deleted_at is null)
         end;
end;
$$;

-- Read only through a live attachment row the user can see. Each row's RLS checks the tenant and its view
-- permission (asset_attachment.view, service_record.view). A file of an undone service record is not readable.
alter policy attachments_select on storage.objects
  using (bucket_id = 'attachments'
         and (exists (select 1 from public.asset_attachment a
                      where a.object_path = objects.name and a.deleted_at is null)
              or exists (select 1 from public.service_record_attachment a
                         join public.service_record r on r.tenant_id = a.tenant_id and r.id = a.service_record_id
                         where a.object_path = objects.name and a.deleted_at is null and r.deleted_at is null)));
