-- Story 5.2b: service_record_attachment and the service_record branch of the 'attachments' storage policies
-- (data-model-goal5.md §12.6). The asset branch is covered unchanged by 3_6_attachments.test.sql.
-- Uses the seed: tenant A active, B read_only, starter-group users <role>.<a|b> (...0<a|b>000<n>:
-- 1 admin, 2 plant manager, 4 technician, 5 auditor), a1 in A and B with no groups, and supabase/test_harness.sql.
-- Storage rows are written directly, as the Storage API does under the user's role.
begin;
select plan(41);

create function pg_temp.id(s text) returns uuid language sql as $$
  select ('00000000-0000-0000-0000-0000052b00' || s)::uuid
$$;
create function pg_temp.p(t text, kind text, e text, i text) returns text language sql as $$
  select '00000000-0000-0000-0000-00000000000' || t || '/' || kind || '/' || pg_temp.id(e) || '/' || pg_temp.id(i)
$$;
create function pg_temp.sr(t text, e text, i text) returns text language sql as $$
  select pg_temp.p(t, 'service_record', e, i)
$$;
create function pg_temp.upload(p_name text, p_owner text) returns void language sql as $$
  insert into storage.objects (bucket_id, name, owner_id, metadata)
  values ('attachments', p_name, p_owner, '{"size": 4096, "mimetype": "application/pdf"}')
$$;
create function pg_temp.row(r text, f text, n text) returns void language sql as $$
  insert into public.service_record_attachment (id, tenant_id, service_record_id, file_name)
  values (pg_temp.id(f), '00000000-0000-0000-0000-00000000000a', pg_temp.id(r), n)
$$;
create function pg_temp.files() returns int language sql as $$
  select count(*)::int from storage.objects where bucket_id = 'attachments'
$$;

-- Fixtures, as postgres: one asset and obligation per tenant; records a1, a2 (undone later), a3 (undone) in A, b1 in B.
insert into public.asset_category (id, tenant_id, name) values
  (pg_temp.id('ca'), '00000000-0000-0000-0000-00000000000a', 'Machines'),
  (pg_temp.id('cb'), '00000000-0000-0000-0000-00000000000b', 'B cat');
insert into public.asset (id, tenant_id, name, category_id) values
  (pg_temp.id('da'), '00000000-0000-0000-0000-00000000000a', 'Boiler', pg_temp.id('ca')),
  (pg_temp.id('db'), '00000000-0000-0000-0000-00000000000b', 'B asset', pg_temp.id('cb'));
insert into public.obligation (id, tenant_id, asset_id, name, obligation_type, interval_count, interval_unit, anchor, first_due_date) values
  (pg_temp.id('ea'), '00000000-0000-0000-0000-00000000000a', pg_temp.id('da'), 'Inspection', 'inspection', 1, 'year', 'fixed', '2027-01-01'),
  (pg_temp.id('eb'), '00000000-0000-0000-0000-00000000000b', pg_temp.id('db'), 'B ob', 'service', 1, 'year', 'fixed', '2027-01-01');
insert into public.service_record (id, tenant_id, obligation_id, asset_id, done_on, advanced, deleted_at) values
  (pg_temp.id('a1'), '00000000-0000-0000-0000-00000000000a', pg_temp.id('ea'), pg_temp.id('da'), '2026-10-01', false, null),
  (pg_temp.id('a2'), '00000000-0000-0000-0000-00000000000a', pg_temp.id('ea'), pg_temp.id('da'), '2026-09-01', false, null),
  (pg_temp.id('a3'), '00000000-0000-0000-0000-00000000000a', pg_temp.id('ea'), pg_temp.id('da'), '2026-08-01', false, now()),
  (pg_temp.id('b1'), '00000000-0000-0000-0000-00000000000b', pg_temp.id('eb'), pg_temp.id('db'), '2026-10-01', false, null);

-- Upload (storage insert). Technician has service_record view, create and update.
select tests.act_as('00000000-0000-0000-0000-0000000a0004', '00000000-0000-0000-0000-00000000000a');
select lives_ok($$select pg_temp.upload(pg_temp.sr('a', 'a1', 'f1'), '00000000-0000-0000-0000-0000000a0004')$$, 'upload to own tenant service record');
select throws_ok($$select pg_temp.upload(pg_temp.sr('b', 'b1', 'f2'), '00000000-0000-0000-0000-0000000a0004')$$,
  '42501', null, 'upload to another tenant path: refused');
select throws_ok($$select pg_temp.upload(pg_temp.sr('a', 'b1', 'f2'), '00000000-0000-0000-0000-0000000a0004')$$,
  '42501', null, 'own tenant prefix, another tenant record: refused');
select throws_ok($$select pg_temp.upload(pg_temp.sr('a', 'a3', 'f2'), '00000000-0000-0000-0000-0000000a0004')$$,
  '42501', null, 'upload to an undone record: refused');
select throws_ok($$select pg_temp.upload(pg_temp.p('a', 'asset', 'a1', 'f2'), '00000000-0000-0000-0000-0000000a0004')$$,
  '42501', null, 'wrong entity segment (record id under asset): refused');
select throws_ok($$select pg_temp.upload(pg_temp.p('a', 'service_record', 'da', 'f2'), '00000000-0000-0000-0000-0000000a0004')$$,
  '42501', null, 'wrong entity segment (asset id under service_record): refused');
select throws_ok($$select pg_temp.upload(pg_temp.p('a', 'service', 'a1', 'f2'), '00000000-0000-0000-0000-0000000a0004')$$,
  '42501', null, 'unknown entity segment: refused');
select throws_ok($$select pg_temp.upload(pg_temp.sr('a', 'a1', 'f2') || '/x', '00000000-0000-0000-0000-0000000a0004')$$,
  '42501', null, 'extra path part: refused');

select tests.act_as('00000000-0000-0000-0000-0000000a0005', '00000000-0000-0000-0000-00000000000a');
select throws_ok($$select pg_temp.upload(pg_temp.sr('a', 'a1', 'f2'), '00000000-0000-0000-0000-0000000a0005')$$,
  '42501', null, 'auditor (no service_record.create): upload refused');
select tests.act_as('00000000-0000-0000-0000-0000000000a1', '00000000-0000-0000-0000-00000000000a');
select throws_ok($$select pg_temp.upload(pg_temp.sr('a', 'a1', 'f2'), '00000000-0000-0000-0000-0000000000a1')$$,
  '42501', null, 'no groups: upload refused');
select tests.act_as('00000000-0000-0000-0000-0000000b0001', '00000000-0000-0000-0000-00000000000b');
select throws_ok($$select pg_temp.upload(pg_temp.sr('b', 'b1', 'f2'), '00000000-0000-0000-0000-0000000b0001')$$,
  '42501', null, 'read_only tenant: upload refused');

-- Admin uploads a file and never writes its row: an orphan.
select tests.act_as('00000000-0000-0000-0000-0000000a0001', '00000000-0000-0000-0000-00000000000a');
select pg_temp.upload(pg_temp.sr('a', 'a1', 'f9'), '00000000-0000-0000-0000-0000000a0001');

-- The row (after the upload).
select tests.act_as('00000000-0000-0000-0000-0000000a0004', '00000000-0000-0000-0000-00000000000a');
select lives_ok($$select pg_temp.row('a1', 'f1', 'Report.pdf')$$, 'row for an uploaded file');
select throws_ok($$select pg_temp.row('a1', 'f3', 'x.pdf')$$, '23503', 'attachment file not found', 'row without a file: refused');
select throws_ok($$select pg_temp.row('a1', 'f9', 'x.pdf')$$, '23503', 'attachment file not found', 'row for a file someone else uploaded: refused');
select throws_ok($$insert into public.service_record_attachment (id, tenant_id, service_record_id, file_name, mime_type) values
  (pg_temp.id('f1'), '00000000-0000-0000-0000-00000000000a', pg_temp.id('a1'), 'x.pdf', 'text/html')$$,
  '42501', null, 'client cannot set the mime type (column grant)');
select throws_ok($$select pg_temp.row('a1', 'f1', '../etc/x')$$, '23514', null, 'file name with a slash: refused');
select results_eq($$select file_name, mime_type, size_bytes, uploaded_by from public.service_record_attachments(pg_temp.id('a1'))$$,
  $$values ('Report.pdf', 'application/pdf', 4096::bigint, 'TEST tech.a@example.com')$$,
  'list: mime and size from the stored file, uploader name');

-- Read (storage select, signed URLs): only files with a live row the user can see.
select is(pg_temp.files(), 1, 'technician reads the file with a row, not the orphan');
select tests.act_as('00000000-0000-0000-0000-0000000a0005', '00000000-0000-0000-0000-00000000000a');
select is(pg_temp.files(), 1, 'auditor (service_record.view) reads the file');
select tests.act_as('00000000-0000-0000-0000-0000000a0001', '00000000-0000-0000-0000-00000000000a');
select is(pg_temp.files(), 1, 'admin cannot read their own orphan upload');
select tests.act_as('00000000-0000-0000-0000-0000000000a1', '00000000-0000-0000-0000-00000000000a');
select is(pg_temp.files(), 0, 'no service_record.view: no files');
select tests.act_as('00000000-0000-0000-0000-0000000b0001', '00000000-0000-0000-0000-00000000000b');
select is(pg_temp.files(), 0, 'other tenant admin: no files');
select tests.act_as('00000000-0000-0000-0000-0000000a0002', '00000000-0000-0000-0000-00000000000b');
select is(pg_temp.files(), 0, 'tenant A plant manager forging tenant B: no files');

-- No update or delete of stored files, by anyone.
select tests.act_as('00000000-0000-0000-0000-0000000a0001', '00000000-0000-0000-0000-00000000000a');
update storage.objects set metadata = '{}' where bucket_id = 'attachments';
select is((select count(*)::int from storage.objects where bucket_id = 'attachments' and metadata = '{}'), 0, 'stored files cannot be overwritten');
select policies_are('storage', 'objects', array['attachments_insert', 'attachments_select'], 'storage: still only insert and select policies');

-- Soft delete needs service_record.update, then the file is unreadable.
select tests.act_as('00000000-0000-0000-0000-0000000a0005', '00000000-0000-0000-0000-00000000000a');
update public.service_record_attachment set deleted_at = now() where id = pg_temp.id('f1');
select is((select count(*)::int from public.service_record_attachment where deleted_at is not null), 0, 'auditor (no update): soft delete touches nothing');
select throws_ok($$delete from public.service_record_attachment where id = pg_temp.id('f1')$$, '42501', null, 'no hard delete');
select tests.act_as('00000000-0000-0000-0000-0000000a0004', '00000000-0000-0000-0000-00000000000a');
select lives_ok($$update public.service_record_attachment set deleted_at = now() where id = pg_temp.id('f1')$$, 'technician soft deletes');
select is(pg_temp.files(), 0, 'deleted attachment: file no longer readable');
select is((select count(*)::int from public.service_record_attachments(pg_temp.id('a1'))), 0, 'deleted attachment: not listed');

-- A file on a record that is undone afterwards is no longer readable.
select pg_temp.upload(pg_temp.sr('a', 'a2', 'f2'), '00000000-0000-0000-0000-0000000a0004');
select pg_temp.row('a2', 'f2', 'Certificate.pdf');
select is(pg_temp.files(), 1, 'file on record a2 readable');
reset role;
select set_config('request.jwt.claims', '', true);
update public.service_record set deleted_at = now() where id = pg_temp.id('a2');
select tests.act_as('00000000-0000-0000-0000-0000000a0004', '00000000-0000-0000-0000-00000000000a');
select is(pg_temp.files(), 0, 'record undone: its file is no longer readable');

reset role;
select is((select count(*)::int from public.audit_log where table_name = 'service_record_attachment' and record_id = pg_temp.id('f1')),
  2, 'audit rows for upload and soft delete');

-- Harness. Rows inserted as postgres (no user), so the uploader check does not apply; the files exist.
select set_config('request.jwt.claims', '', true);
insert into storage.objects (bucket_id, name, owner_id, metadata) values
  ('attachments', pg_temp.sr('a', 'a1', '0a'), '00000000-0000-0000-0000-0000000000a1', '{"size": 1, "mimetype": "text/plain"}'),
  ('attachments', pg_temp.sr('b', 'b1', '0b'), '00000000-0000-0000-0000-0000000000a1', '{"size": 1, "mimetype": "text/plain"}');
select * from tests.cross_tenant('public.service_record_attachment', 'service_record',
  jsonb_build_object('id', pg_temp.id('0a'), 'service_record_id', pg_temp.id('a1'), 'file_name', 'ct-row'),
  jsonb_build_object('id', pg_temp.id('0b'), 'service_record_id', pg_temp.id('b1')));

select * from finish();
rollback;
