-- Story 3.6: asset_attachment and the 'attachments' storage policies (data-model-goal3.md §17).
-- Uses the seed: tenant A active, B read_only, starter-group users <role>.<a|b> (...0<a|b>000<n>:
-- 1 admin, 4 technician, 5 auditor), a1 in A and B with no groups, and supabase/test_harness.sql.
-- Storage rows are written directly, as the Storage API does under the user's role.
begin;
select plan(37);

create function pg_temp.p(t text, a text, i text) returns text language sql as $$
  select '00000000-0000-0000-0000-00000000000' || t || '/asset/00000000-0000-0000-0000-0000000036' || a || '/00000000-0000-0000-0000-0000000036' || i
$$;
-- An upload as the current role: the Storage API inserts the row with the uploader as owner.
create function pg_temp.upload(p_name text, p_owner text) returns void language sql as $$
  insert into storage.objects (bucket_id, name, owner_id, metadata)
  values ('attachments', p_name, p_owner, '{"size": 2048, "mimetype": "application/pdf"}')
$$;

-- Fixtures, as postgres.
insert into public.asset_category (id, tenant_id, name) values
  ('00000000-0000-0000-0000-0000000036c1', '00000000-0000-0000-0000-00000000000a', 'Machines'),
  ('00000000-0000-0000-0000-0000000036cb', '00000000-0000-0000-0000-00000000000b', 'B cat');
insert into public.asset (id, tenant_id, tag, name, category_id, deleted_at) values
  ('00000000-0000-0000-0000-0000000036a1', '00000000-0000-0000-0000-00000000000a', 'CNC-01', 'CNC 01', '00000000-0000-0000-0000-0000000036c1', null),
  ('00000000-0000-0000-0000-0000000036a2', '00000000-0000-0000-0000-00000000000a', 'OLD-01', 'Gone', '00000000-0000-0000-0000-0000000036c1', now()),
  ('00000000-0000-0000-0000-0000000036b1', '00000000-0000-0000-0000-00000000000b', 'B-01', 'B asset', '00000000-0000-0000-0000-0000000036cb', null);

select ok(exists (select 1 from storage.buckets where id = 'attachments' and not public and file_size_limit = 10485760
                  and not ('image/svg+xml' = any (allowed_mime_types)) and not ('text/html' = any (allowed_mime_types))),
  'bucket is private, 10 MB, no SVG or HTML');

-- Upload (storage insert). Technician has asset_attachment view and create.
select tests.act_as('00000000-0000-0000-0000-0000000a0004', '00000000-0000-0000-0000-00000000000a');
select lives_ok($$select pg_temp.upload(pg_temp.p('a', 'a1', 'f1'), '00000000-0000-0000-0000-0000000a0004')$$, 'upload to own tenant asset');
select throws_ok($$select pg_temp.upload(pg_temp.p('b', 'b1', 'f2'), '00000000-0000-0000-0000-0000000a0004')$$,
  '42501', null, 'upload to another tenant path: refused');
select throws_ok($$select pg_temp.upload(pg_temp.p('a', 'b1', 'f2'), '00000000-0000-0000-0000-0000000a0004')$$,
  '42501', null, 'own tenant prefix, another tenant asset: refused');
select throws_ok($$select pg_temp.upload(pg_temp.p('a', 'a2', 'f2'), '00000000-0000-0000-0000-0000000a0004')$$,
  '42501', null, 'upload to a deleted asset: refused');
select throws_ok($$select pg_temp.upload('00000000-0000-0000-0000-00000000000a/asset/../x', '00000000-0000-0000-0000-0000000a0004')$$,
  '42501', null, 'bad path: refused, not an error');
select throws_ok($$select pg_temp.upload(upper(pg_temp.p('a', 'a1', 'f2')) || '/x', '00000000-0000-0000-0000-0000000a0004')$$,
  '42501', null, 'extra path part: refused');
select throws_ok($$insert into storage.objects (bucket_id, name, owner_id) values ('other', 'x', '00000000-0000-0000-0000-0000000a0004')$$,
  '42501', null, 'other bucket: no policy');

select tests.act_as('00000000-0000-0000-0000-0000000a0005', '00000000-0000-0000-0000-00000000000a');
select throws_ok($$select pg_temp.upload(pg_temp.p('a', 'a1', 'f2'), '00000000-0000-0000-0000-0000000a0005')$$,
  '42501', null, 'auditor (no create): upload refused');
select tests.act_as('00000000-0000-0000-0000-0000000b0001', '00000000-0000-0000-0000-00000000000b');
select throws_ok($$select pg_temp.upload(pg_temp.p('b', 'b1', 'f2'), '00000000-0000-0000-0000-0000000b0001')$$,
  '42501', null, 'read_only tenant: upload refused');

-- Admin uploads a file and never writes its row: an orphan.
select tests.act_as('00000000-0000-0000-0000-0000000a0001', '00000000-0000-0000-0000-00000000000a');
select pg_temp.upload(pg_temp.p('a', 'a1', 'f9'), '00000000-0000-0000-0000-0000000a0001');

-- The row (after the upload).
select tests.act_as('00000000-0000-0000-0000-0000000a0004', '00000000-0000-0000-0000-00000000000a');
select lives_ok($$insert into public.asset_attachment (id, tenant_id, asset_id, file_name) values
  ('00000000-0000-0000-0000-0000000036f1', '00000000-0000-0000-0000-00000000000a', '00000000-0000-0000-0000-0000000036a1', 'Manual.pdf')$$,
  'row for an uploaded file');
select throws_ok($$insert into public.asset_attachment (id, tenant_id, asset_id, file_name) values
  ('00000000-0000-0000-0000-0000000036f3', '00000000-0000-0000-0000-00000000000a', '00000000-0000-0000-0000-0000000036a1', 'x.pdf')$$,
  '23503', 'attachment file not found', 'row without a file: refused');
select throws_ok($$insert into public.asset_attachment (id, tenant_id, asset_id, file_name) values
  ('00000000-0000-0000-0000-0000000036f9', '00000000-0000-0000-0000-00000000000a', '00000000-0000-0000-0000-0000000036a1', 'x.pdf')$$,
  '23503', 'attachment file not found', 'row for a file someone else uploaded: refused');
select throws_ok($$insert into public.asset_attachment (id, tenant_id, asset_id, file_name, mime_type) values
  ('00000000-0000-0000-0000-0000000036f1', '00000000-0000-0000-0000-00000000000a', '00000000-0000-0000-0000-0000000036a1', 'x.pdf', 'text/html')$$,
  '42501', null, 'client cannot set the mime type (column grant)');
select throws_ok($$insert into public.asset_attachment (id, tenant_id, asset_id, file_name) values
  ('00000000-0000-0000-0000-0000000036f1', '00000000-0000-0000-0000-00000000000a', '00000000-0000-0000-0000-0000000036a1', '../etc/x')$$,
  '23514', null, 'file name with a slash: refused');
select results_eq($$select file_name, mime_type, size_bytes, uploaded_by from public.asset_attachments('00000000-0000-0000-0000-0000000036a1')$$,
  $$values ('Manual.pdf', 'application/pdf', 2048::bigint, 'TEST tech.a@example.com')$$,
  'list: mime and size from the stored file, uploader name');

-- Read (storage select, signed URLs): only files with a live row the user can see.
select is((select count(*)::int from storage.objects where bucket_id = 'attachments'), 1, 'technician reads the file with a row, not the orphan');
select tests.act_as('00000000-0000-0000-0000-0000000a0001', '00000000-0000-0000-0000-00000000000a');
select is((select count(*)::int from storage.objects where bucket_id = 'attachments'), 1, 'admin cannot read their own orphan upload');
select tests.act_as('00000000-0000-0000-0000-0000000000a1', '00000000-0000-0000-0000-00000000000a');
select is((select count(*)::int from storage.objects where bucket_id = 'attachments'), 0, 'no asset_attachment.view: no files');
select tests.act_as('00000000-0000-0000-0000-0000000b0001', '00000000-0000-0000-0000-00000000000b');
select is((select count(*)::int from storage.objects where bucket_id = 'attachments'), 0, 'other tenant admin: no files');
select tests.act_as('00000000-0000-0000-0000-0000000a0002', '00000000-0000-0000-0000-00000000000b');
select is((select count(*)::int from storage.objects where bucket_id = 'attachments'), 0, 'tenant A plant manager forging tenant B: no files');

-- No update or delete of stored files, by anyone.
select tests.act_as('00000000-0000-0000-0000-0000000a0001', '00000000-0000-0000-0000-00000000000a');
update storage.objects set metadata = '{}' where bucket_id = 'attachments';
select is((select count(*)::int from storage.objects where bucket_id = 'attachments' and metadata = '{}'), 0, 'stored files cannot be overwritten');
-- Direct SQL deletes are blocked by Storage's own trigger; API deletes run under these policies, and none allows delete.
select policies_are('storage', 'objects', array['attachments_insert', 'attachments_select'], 'storage: only insert and select policies, no update or delete');

-- Soft delete needs asset_attachment.delete, then the file is unreadable.
select tests.act_as('00000000-0000-0000-0000-0000000a0004', '00000000-0000-0000-0000-00000000000a');
update public.asset_attachment set deleted_at = now() where id = '00000000-0000-0000-0000-0000000036f1';
select is((select count(*)::int from public.asset_attachment where deleted_at is not null), 0, 'technician (no delete): soft delete touches nothing');
select throws_ok($$delete from public.asset_attachment where id = '00000000-0000-0000-0000-0000000036f1'$$,
  '42501', null, 'no hard delete');
select tests.act_as('00000000-0000-0000-0000-0000000a0001', '00000000-0000-0000-0000-00000000000a');
select lives_ok($$update public.asset_attachment set deleted_at = now() where id = '00000000-0000-0000-0000-0000000036f1'$$, 'admin soft deletes');
select is((select count(*)::int from storage.objects where bucket_id = 'attachments'), 0, 'deleted attachment: file no longer readable');
select is((select count(*)::int from public.asset_attachments('00000000-0000-0000-0000-0000000036a1')), 0, 'deleted attachment: not listed');

reset role;
select is((select count(*)::int from public.audit_log where table_name = 'asset_attachment' and record_id = '00000000-0000-0000-0000-0000000036f1'),
  2, 'audit rows for upload and soft delete');

-- Harness. Rows inserted as postgres (no user), so the uploader check does not apply; the files exist.
select set_config('request.jwt.claims', '', true);
insert into storage.objects (bucket_id, name, owner_id, metadata) values
  ('attachments', pg_temp.p('a', 'a1', 'c1'), '00000000-0000-0000-0000-0000000000a1', '{"size": 1, "mimetype": "text/plain"}'),
  ('attachments', pg_temp.p('b', 'b1', 'cb'), '00000000-0000-0000-0000-0000000000a1', '{"size": 1, "mimetype": "text/plain"}');
select * from tests.cross_tenant('public.asset_attachment', 'asset_attachment',
  '{"id": "00000000-0000-0000-0000-0000000036c1", "asset_id": "00000000-0000-0000-0000-0000000036a1", "file_name": "ct-row"}',
  '{"id": "00000000-0000-0000-0000-0000000036cb", "asset_id": "00000000-0000-0000-0000-0000000036b1"}');

select * from finish();
rollback;
