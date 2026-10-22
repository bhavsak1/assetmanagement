-- Story 3.6: asset_attachment, the source of truth for files on assets. data-model-goal3.md §17.3.
-- 1.4 pattern on asset_attachment. The file itself lives in the private bucket 'attachments' at
-- object_path; the 3_6_attachment_storage migration ties every read of the file to a live row here.

create table public.asset_attachment (
  id          uuid primary key default gen_random_uuid(),
  tenant_id   uuid not null references public.tenant (id),
  asset_id    uuid not null,
  -- Untrusted: shown as text only, never part of a path.
  file_name   text not null check (btrim(file_name) <> '' and length(file_name) <= 255 and file_name !~ '[/\\[:cntrl:]]'),
  -- Both copied from the stored object by the insert trigger, never taken from the client.
  mime_type   text not null,
  size_bytes  bigint not null check (size_bytes >= 0),
  object_path text generated always as (tenant_id::text || '/asset/' || asset_id::text || '/' || id::text) stored,
  created_at  timestamptz not null default now(),
  updated_at  timestamptz not null default now(),
  created_by  uuid null default auth.uid() references public.user_profile (id),
  updated_by  uuid null references public.user_profile (id),
  deleted_at  timestamptz null,
  unique (tenant_id, id),
  unique (object_path),
  foreign key (tenant_id, asset_id) references public.asset (tenant_id, id)
);
create index asset_attachment_asset_idx on public.asset_attachment (tenant_id, asset_id, created_at desc) where deleted_at is null;

-- The object must already be uploaded (Z6: object first, then row). Fills mime type and size from it.
-- shortcut: reads Supabase's storage.objects, the one Supabase-only piece; a move off Supabase rewrites this function.
create function private.check_attachment_object()
returns trigger language plpgsql security definer set search_path = '' as $$
declare
  v_meta jsonb;
begin
  select o.metadata into v_meta
  from storage.objects o
  -- Same as object_path: a generated column is not computed yet in a before trigger.
  where o.bucket_id = 'attachments' and o.name = new.tenant_id::text || '/asset/' || new.asset_id::text || '/' || new.id::text
    -- A user can only claim a file they uploaded themselves.
    and (auth.uid() is null or o.owner_id = auth.uid()::text);
  if v_meta is null then
    raise exception 'attachment file not found' using errcode = '23503';
  end if;
  new.mime_type  := v_meta ->> 'mimetype';
  new.size_bytes := (v_meta ->> 'size')::bigint;
  return new;
end;
$$;

create trigger check_attachment_object before insert on public.asset_attachment
  for each row execute function private.check_attachment_object();
create trigger set_updated_at before update on public.asset_attachment
  for each row execute function private.set_updated_at();
create trigger check_soft_delete before update of deleted_at on public.asset_attachment
  for each row execute function private.check_soft_delete('asset_attachment', 'delete');
create trigger audit after insert or update or delete on public.asset_attachment
  for each row execute function private.audit_row('data');

-- Soft-deleted rows stay readable (history); the app and the storage read policy filter them.
-- 6.1 adds one set-form scope clause on asset_id to select and insert.
alter table public.asset_attachment enable row level security;

create policy asset_attachment_select on public.asset_attachment
  for select to authenticated
  using (tenant_id = (select private.current_tenant_id())
         and (select private.has_permission('asset_attachment', 'view')));
create policy asset_attachment_insert on public.asset_attachment
  for insert to authenticated
  with check (tenant_id = (select private.current_tenant_id())
              and (select private.has_permission('asset_attachment', 'create'))
              and (select private.tenant_can_write()));
-- The only user update is the soft delete, so it needs the delete operation.
create policy asset_attachment_update on public.asset_attachment
  for update to authenticated
  using (tenant_id = (select private.current_tenant_id())
         and (select private.has_permission('asset_attachment', 'delete'))
         and (select private.tenant_can_write()))
  with check (tenant_id = (select private.current_tenant_id())
              and (select private.has_permission('asset_attachment', 'delete'))
              and (select private.tenant_can_write()));

revoke all on public.asset_attachment from anon, authenticated;
grant select on public.asset_attachment to authenticated;
grant insert (id, tenant_id, asset_id, file_name) on public.asset_attachment to authenticated;
grant update (updated_by, deleted_at) on public.asset_attachment to authenticated;

-- Name of an active member of the current tenant, else null. Same rule as asset_history (H1 a).
create function private.member_name(p_user_id uuid)
returns text language sql stable security definer set search_path = '' as $$
  select p.display_name from public.user_profile p
  join public.tenant_membership m on m.user_id = p.id
  where p.id = p_user_id and m.tenant_id = private.current_tenant_id()
    and m.status = 'active' and m.deleted_at is null
$$;
revoke all on function private.member_name(uuid) from public, anon;
grant execute on function private.member_name(uuid) to authenticated;

-- The Attachments tab: live files of one asset, newest first. Invoker, so the RLS above decides.
create function public.asset_attachments(p_asset_id uuid)
returns table (id uuid, file_name text, mime_type text, size_bytes bigint, created_at timestamptz, uploaded_by text)
language sql stable set search_path = '' as $$
  select a.id, a.file_name, a.mime_type, a.size_bytes, a.created_at, private.member_name(a.created_by)
  from public.asset_attachment a
  where a.asset_id = p_asset_id and a.deleted_at is null
  order by a.created_at desc, a.id
$$;
revoke all on function public.asset_attachments(uuid) from public, anon;
grant execute on function public.asset_attachments(uuid) to authenticated;
