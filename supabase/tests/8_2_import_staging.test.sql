-- Story 8.2: import_batch and import_row under RLS (docs/data-model-goal8.md §13.2).
-- Seed: tenant A active, B read_only; a1 in A and B.
begin;
select plan(42);

select policies_are('public', 'import_batch', array['import_batch_select', 'import_batch_insert']);
select policies_are('public', 'import_row', array['import_row_select', 'import_row_insert']);
select ok(not has_table_privilege('authenticated', 'public.import_batch', 'update'), 'batch: no update grant');
select ok(not has_table_privilege('authenticated', 'public.import_batch', 'delete'), 'batch: no delete grant');
select ok(not has_table_privilege('authenticated', 'public.import_row', 'update'), 'row: no update grant');
select ok(not has_table_privilege('authenticated', 'public.import_row', 'delete'), 'row: no delete grant');

create function pg_temp.batch(p_id text, p_tenant text) returns void language sql as $$
  insert into public.import_batch (id, tenant_id, file_name, file_size, file_sha256, sheet_name, sheet_names, header_row, columns, row_count)
  values (p_id::uuid, p_tenant::uuid, 'assets.xlsx', 100, repeat('a', 64), 'Sheet1', '{Sheet1}', 1, '{Name,Tag}', 1);
$$;
grant execute on function pg_temp.batch(text, text) to authenticated;

select pg_temp.batch('00000000-0000-0000-0000-0000000082a1', '00000000-0000-0000-0000-00000000000a');
select pg_temp.batch('00000000-0000-0000-0000-0000000082b1', '00000000-0000-0000-0000-00000000000b');
insert into public.import_row (tenant_id, batch_id, row_number, cells) values
  ('00000000-0000-0000-0000-00000000000a', '00000000-0000-0000-0000-0000000082a1', 2, '["Pump", "P-1"]'),
  ('00000000-0000-0000-0000-00000000000b', '00000000-0000-0000-0000-0000000082b1', 2, '["Fan", "F-1"]');

-- Default deny.
select tests.act_as('00000000-0000-0000-0000-0000000000a1', '00000000-0000-0000-0000-00000000000a');
select is((select count(*)::int from public.import_batch), 0, 'no grant: no batches');
select is((select count(*)::int from public.import_row), 0, 'no grant: no rows');
select throws_ok($$select pg_temp.batch('00000000-0000-0000-0000-0000000082a2', '00000000-0000-0000-0000-00000000000a')$$,
  '42501', null, 'no grant: no insert');

-- review only: reads, cannot stage.
reset role;
select tests.grant('00000000-0000-0000-0000-00000000000a', '00000000-0000-0000-0000-0000000000a1', 'excel_import', '{review}');
select tests.act_as('00000000-0000-0000-0000-0000000000a1', '00000000-0000-0000-0000-00000000000a');
select is((select count(*)::int from public.import_batch where id::text like '%82__'), 1, 'review reads batches');
select results_eq($$select cells from public.import_row where batch_id::text like '%82__'$$, $$values ('["Pump", "P-1"]'::jsonb)$$, 'review reads own tenant rows');
select throws_ok($$select pg_temp.batch('00000000-0000-0000-0000-0000000082a2', '00000000-0000-0000-0000-00000000000a')$$,
  '42501', null, 'review cannot stage a batch');

-- run: stages a batch and its rows, cannot change or remove them.
reset role;
select tests.grant('00000000-0000-0000-0000-00000000000a', '00000000-0000-0000-0000-0000000000a1', 'excel_import', '{run}');
select tests.act_as('00000000-0000-0000-0000-0000000000a1', '00000000-0000-0000-0000-00000000000a');
select lives_ok($$select pg_temp.batch('00000000-0000-0000-0000-0000000082a2', '00000000-0000-0000-0000-00000000000a')$$,
  'run stages a batch');
select lives_ok($$insert into public.import_row (tenant_id, batch_id, row_number, cells) values
  ('00000000-0000-0000-0000-00000000000a', '00000000-0000-0000-0000-0000000082a2', 2, '["x"]')$$, 'run stages a row');
set constraints all immediate;  -- the batch FK is deferred for the service; check it here
select throws_ok($$insert into public.import_row (tenant_id, batch_id, row_number, cells) values
  ('00000000-0000-0000-0000-00000000000a', '00000000-0000-0000-0000-0000000082b1', 3, '["x"]')$$,
  '23503', null, 'row cannot point at another tenant batch (composite FK)');
select throws_ok($$update public.import_row set cells = '[]'$$, '42501', null, 'run cannot edit staged rows');
select throws_ok($$delete from public.import_batch$$, '42501', null, 'run cannot delete batches');
select is((select created_by from public.import_batch where id = '00000000-0000-0000-0000-0000000082a2'),
  '00000000-0000-0000-0000-0000000000a1'::uuid, 'created_by is the uploader');

-- read_only tenant B: reads, no staging.
reset role;
select tests.grant('00000000-0000-0000-0000-00000000000b', '00000000-0000-0000-0000-0000000000a1', 'excel_import');
select tests.act_as('00000000-0000-0000-0000-0000000000a1', '00000000-0000-0000-0000-00000000000b');
select is((select count(*)::int from public.import_batch where id::text like '%82__'), 1, 'read_only tenant reads');
select throws_ok($$select pg_temp.batch('00000000-0000-0000-0000-0000000082b2', '00000000-0000-0000-0000-00000000000b')$$,
  '42501', null, 'read_only tenant cannot stage');

-- Audit on the batch only (I11).
reset role;
select is((select count(*)::int from public.audit_log where table_name = 'import_batch'
           and record_id = '00000000-0000-0000-0000-0000000082a2'), 1, 'batch insert is audited');
select is((select count(*)::int from public.audit_log where table_name = 'import_row'), 0, 'staged rows are not audited');

-- Purge (I9): expired staged rows go, the batch stays as history.
update public.import_batch set expires_at = now() - interval '1 minute' where id = '00000000-0000-0000-0000-0000000082a1';
select private.purge_expired_imports();
select is((select count(*)::int from public.import_row where batch_id = '00000000-0000-0000-0000-0000000082a1'), 0, 'purge removes expired rows');
select is((select status from public.import_batch where id = '00000000-0000-0000-0000-0000000082a1'), 'expired', 'purged batch is expired');
select is((select count(*)::int from public.import_row where batch_id = '00000000-0000-0000-0000-0000000082a2'), 1, 'live batch keeps its rows');
select is((select count(*)::int from cron.job where jobname = 'assetly_purge_expired_imports'), 1, 'purge job scheduled');

-- Harness.
select * from tests.cross_tenant('public.import_batch', 'excel_import',
  '{"file_name": "ct-row", "file_size": 1, "file_sha256": "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa", "sheet_name": "S", "sheet_names": ["S"], "header_row": 1, "columns": ["A"], "row_count": 0}');
-- 8 tests above, plus import_row on batches 82a2 (A) and 82b1 (B).
reset role;
select * from tests.cross_tenant('public.import_row', 'excel_import',
  '{"batch_id": "00000000-0000-0000-0000-0000000082a2", "row_number": 9, "cells": ["ct-row"]}',
  '{"batch_id": "00000000-0000-0000-0000-0000000082b1"}');

select * from finish();
rollback;
