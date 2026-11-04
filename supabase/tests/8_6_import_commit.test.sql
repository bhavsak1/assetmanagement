-- Story 8.6: idempotent commit and batch undo (docs/data-model-goal8.md §18).
-- Seed: tenant A active (dd-MM-yyyy, INR), B read_only; a1 in A and B.
begin;
select plan(41);

insert into public.asset_category (id, tenant_id, name, code) values
  ('00000000-0000-0000-0000-0000000086c1', '00000000-0000-0000-0000-00000000000a', 'Compressors 86', 'CMP86'),
  ('00000000-0000-0000-0000-0000000086c2', '00000000-0000-0000-0000-00000000000a', 'Pumps 86', 'PMP86');
insert into public.location (id, tenant_id, name, code) values
  ('00000000-0000-0000-0000-0000000086e1', '00000000-0000-0000-0000-00000000000a', 'Plant 86', 'P86');
insert into public.vendor (id, tenant_id, name, code, roles) values
  ('00000000-0000-0000-0000-0000000086f1', '00000000-0000-0000-0000-00000000000a', 'Atlas 86', 'ATL86', '{oem}');
update public.asset_category set oem_vendor_ids = '{00000000-0000-0000-0000-0000000086f1}'
where id = '00000000-0000-0000-0000-0000000086c1';

create function pg_temp.batch(p_id text, p_tenant text, p_rows int, p_targets text[]) returns void language sql as $$
  insert into public.import_batch (id, tenant_id, file_name, file_size, file_sha256, sheet_name, sheet_names, header_row,
                                   columns, row_count, status, mapping)
  select p_id::uuid, p_tenant::uuid, 'assets.xlsx', 100, repeat('a', 64), 'Sheet1', '{Sheet1}', 1,
         array_agg(t order by n), p_rows, 'mapped',
         jsonb_agg(jsonb_build_object('target', t, 'source', 'rules') order by n)
  from unnest(p_targets) with ordinality as x (t, n);
$$;
create function pg_temp.assets() returns int language sql as $$
  select count(*)::int from public.asset where tenant_id = '00000000-0000-0000-0000-00000000000a' and name like 'Imp86%';
$$;
grant execute on function pg_temp.assets() to authenticated;
create function pg_temp.live() returns int language sql as $$
  select count(*)::int from public.asset where tenant_id = '00000000-0000-0000-0000-00000000000a' and name like 'Imp86%' and deleted_at is null;
$$;

select pg_temp.batch('00000000-0000-0000-0000-0000000086b1', '00000000-0000-0000-0000-00000000000a', 4,
  array['name', 'category', 'location', 'purchase_value', 'oem_vendor', 'warranty_start', 'warranty_end']);
select pg_temp.batch('00000000-0000-0000-0000-0000000086bb', '00000000-0000-0000-0000-00000000000b', 0, array['name', 'category']);
insert into public.import_row (id, tenant_id, batch_id, row_number, cells)
select x.id::uuid, '00000000-0000-0000-0000-00000000000a', '00000000-0000-0000-0000-0000000086b1', x.n, x.c::jsonb
from (values
  ('00000000-0000-0000-0000-0000000086a2', 2, '["Imp86 one","CMP86","P86",1000,"ATL86","2026-01-01","2028-01-01"]'),
  ('00000000-0000-0000-0000-0000000086a3', 3, '["Imp86 two","PMP86","P86",null,null,null,null]'),
  ('00000000-0000-0000-0000-0000000086a4', 4, '["Imp86 bad","Nope","P86",null,null,null,null]'),
  ('00000000-0000-0000-0000-0000000086a5', 5, '["Imp86 three","CMP86",null,null,null,null,null]')
) as x (id, n, c);

-- Default deny, then a read-only tenant.
select tests.act_as('00000000-0000-0000-0000-0000000000a1', '00000000-0000-0000-0000-00000000000a');
select throws_ok($$select public.import_commit('00000000-0000-0000-0000-0000000086b1')$$, '42501', null, 'no grant: cannot commit');
select throws_ok($$select public.import_undo('00000000-0000-0000-0000-0000000086b1')$$, '42501', null, 'no grant: cannot undo');
reset role;
select tests.grant('00000000-0000-0000-0000-00000000000b', '00000000-0000-0000-0000-0000000000a1', 'excel_import', '{run,commit}');
select tests.grant('00000000-0000-0000-0000-00000000000b', '00000000-0000-0000-0000-0000000000a1', 'import_undo', '{undo}');
select tests.act_as('00000000-0000-0000-0000-0000000000a1', '00000000-0000-0000-0000-00000000000b');
select throws_ok($$select public.import_commit('00000000-0000-0000-0000-0000000086bb')$$, '42501', null, 'read-only tenant: cannot commit');
select throws_ok($$select public.import_undo('00000000-0000-0000-0000-0000000086bb')$$, '42501', null, 'read-only tenant: cannot undo');

-- run but not commit.
reset role;
select tests.grant('00000000-0000-0000-0000-00000000000a', '00000000-0000-0000-0000-0000000000a1', 'excel_import', '{run}');
select tests.grant('00000000-0000-0000-0000-00000000000a', '00000000-0000-0000-0000-0000000000a1', 'asset_core', '{view,create,update}');
select tests.grant('00000000-0000-0000-0000-00000000000a', '00000000-0000-0000-0000-0000000000a1', 'coverage_contract', '{view,create,update}');
select tests.act_as('00000000-0000-0000-0000-0000000000a1', '00000000-0000-0000-0000-00000000000a');
select throws_ok($$select public.import_commit('00000000-0000-0000-0000-0000000086b1')$$, '42501', null, 'run only: cannot commit');

-- 6.2: purchase value is mapped, but the user may not set it: the commit stops, nothing is written.
reset role;
select tests.grant('00000000-0000-0000-0000-00000000000a', '00000000-0000-0000-0000-0000000000a1', 'excel_import', '{commit}');
select tests.act_as('00000000-0000-0000-0000-0000000000a1', '00000000-0000-0000-0000-00000000000a');
select throws_ok($$select public.import_commit('00000000-0000-0000-0000-0000000086b1')$$, '22023',
  'mapping: unknown or not allowed target', 'masked field mapped: commit refused');
select is(pg_temp.assets(), 0, 'masked field mapped: no asset');

-- The finish step alone cannot mark a batch committed.
select throws_ok($$select private.import_commit_finish('00000000-0000-0000-0000-0000000086b1')$$, '22023', null,
  'finish without a check in this transaction: refused');
select throws_ok($$select public.import_commit('00000000-0000-0000-0000-0000000086bb')$$, 'P0002', null, 'another tenant''s batch: not found');

-- Commit, scoped to Compressors (6.1): the Pumps row is out of scope and skipped with the error rows.
reset role;
select tests.grant('00000000-0000-0000-0000-00000000000a', '00000000-0000-0000-0000-0000000000a1', 'asset_financials', '{view,update}');
insert into public.scope_profile (id, tenant_id, name) values
  ('00000000-0000-0000-0000-0000000086f9', '00000000-0000-0000-0000-00000000000a', 'Compressors 86');
insert into public.scope_profile_rule (tenant_id, scope_profile_id, dimension, category_id) values
  ('00000000-0000-0000-0000-00000000000a', '00000000-0000-0000-0000-0000000086f9', 'category', '00000000-0000-0000-0000-0000000086c1');
update public.user_group_assignment set scope_profile_id = '00000000-0000-0000-0000-0000000086f9'
where id = (select a.id from public.user_group_assignment a
            join public.group_domain_policy p on p.security_group_id = a.security_group_id
            join public.domain_operation o on o.id = p.domain_operation_id
            where a.user_id = '00000000-0000-0000-0000-0000000000a1' and o.code = 'create'
              and o.security_domain_id = (select id from public.security_domain where code = 'asset_core'));
select tests.act_as('00000000-0000-0000-0000-0000000000a1', '00000000-0000-0000-0000-00000000000a');
select is(public.import_commit('00000000-0000-0000-0000-0000000086b1') - 'committed_at',
  '{"created_assets": 2, "created_coverages": 1, "skipped": 2, "as_user": "00000000-0000-0000-0000-0000000000a1"}',
  'commit: two assets, one warranty, two rows skipped');
reset role;
select is(pg_temp.assets(), 2, 'two assets written');
select ok(exists (select 1 from public.asset where id = '00000000-0000-0000-0000-0000000086a2' and name = 'Imp86 one'
                  and purchase_value = 1000 and purchase_currency = 'INR' and location_id = '00000000-0000-0000-0000-0000000086e1'
                  and oem_vendor_id = '00000000-0000-0000-0000-0000000086f1' and tag <> '' and status_id is not null),
  'row 2: payload values, defaulted currency, generated tag and status');
select ok(not exists (select 1 from public.asset where id in ('00000000-0000-0000-0000-0000000086a3', '00000000-0000-0000-0000-0000000086a4')),
  'out of scope and error rows: no asset');
select is((select end_date from public.coverage c join public.coverage_asset l on l.coverage_id = c.id
           where l.asset_id = '00000000-0000-0000-0000-0000000086a2'), '2028-01-01'::date, 'warranty line linked to its asset');
select is((select count(*)::int from public.audit_log where record_id in ('00000000-0000-0000-0000-0000000086a2', '00000000-0000-0000-0000-0000000086a5')
           and table_name = 'asset' and action = 'insert'), 2, 'one audit row per asset, same transaction');
select is((select count(*)::int from private.outbox_event where aggregate_id in ('00000000-0000-0000-0000-0000000086a2', '00000000-0000-0000-0000-0000000086a5')),
  2, 'one outbox event per asset');
select is((select status || ':' || (committed_by = '00000000-0000-0000-0000-0000000000a1') from public.import_batch
           where id = '00000000-0000-0000-0000-0000000086b1'), 'committed:true', 'batch committed, by whom');

-- K2: commit again creates nothing; the batch can no longer be mapped or checked.
select tests.act_as('00000000-0000-0000-0000-0000000000a1', '00000000-0000-0000-0000-00000000000a');
select is((public.import_commit('00000000-0000-0000-0000-0000000086b1') ->> 'created_assets')::int, 2, 'commit again: same outcome');
select is(pg_temp.assets(), 2, 'commit again: nothing created twice');
select throws_ok($$select public.import_validate('00000000-0000-0000-0000-0000000086b1')$$, '22023', 'batch is committed', 'committed: no new check');
select throws_ok($$select public.import_save_mapping('00000000-0000-0000-0000-0000000086b1',
  (select mapping from public.import_batch where id = '00000000-0000-0000-0000-0000000086b1'))$$, '22023', 'batch is committed', 'committed: no new mapping');

-- Undo: needs import_undo.undo.
select throws_ok($$select public.import_undo('00000000-0000-0000-0000-0000000086b1')$$, '42501', null, 'no import_undo: cannot undo');
reset role;
select tests.grant('00000000-0000-0000-0000-00000000000a', '00000000-0000-0000-0000-0000000000a1', 'import_undo', '{undo}');
-- Row 5 is edited after the commit. The test is one transaction (now() never moves), so the edit time is set
-- by hand with the triggers off.
set local session_replication_role = replica;
update public.asset set model = 'Edited', updated_at = now() + interval '1 minute' where id = '00000000-0000-0000-0000-0000000086a5';
set local session_replication_role = origin;
select tests.act_as('00000000-0000-0000-0000-0000000000a1', '00000000-0000-0000-0000-00000000000b');
select throws_ok($$select public.import_undo('00000000-0000-0000-0000-0000000086b1')$$, '42501', null, 'undo from another tenant: refused (read-only B)');
select tests.act_as('00000000-0000-0000-0000-0000000000a1', '00000000-0000-0000-0000-00000000000a');
select is(public.import_undo('00000000-0000-0000-0000-0000000086b1') - 'committed_at' - 'undone_at',
  '{"created_assets": 2, "created_coverages": 1, "skipped": 2, "as_user": "00000000-0000-0000-0000-0000000000a1",
    "undone": 1, "blocked": 1, "blocked_by": {"changed": 1}, "undone_by": "00000000-0000-0000-0000-0000000000a1"}',
  'undo: one row undone, the edited row blocked');
reset role;
select is(pg_temp.live(), 1, 'undo: the edited asset stays');
select ok((select deleted_at is not null from public.asset where id = '00000000-0000-0000-0000-0000000086a2'), 'undo: soft delete, the row stays');
select ok((select bool_and(c.deleted_at is not null and l.deleted_at is not null) from public.coverage c
           join public.coverage_asset l on l.coverage_id = c.id where l.asset_id = '00000000-0000-0000-0000-0000000086a2'),
  'undo: warranty line and link soft-deleted');
select is((select count(*)::int from public.audit_log where record_id = '00000000-0000-0000-0000-0000000086a2'
           and table_name = 'asset' and action = 'soft_delete'), 1, 'undo is audited');
select is((select undo_blocked from public.import_row where id = '00000000-0000-0000-0000-0000000086a5'), 'changed', 'row 5 says why');
select is((select status from public.import_batch where id = '00000000-0000-0000-0000-0000000086b1'), 'undone', 'batch undone');

-- Undo again: retries only the blocked row; commit on an undone batch creates nothing.
select tests.act_as('00000000-0000-0000-0000-0000000000a1', '00000000-0000-0000-0000-00000000000a');
select is((public.import_undo('00000000-0000-0000-0000-0000000086b1') ->> 'undone')::int, 1, 'undo again: nothing new undone');
select is((public.import_commit('00000000-0000-0000-0000-0000000086b1') ->> 'created_assets')::int, 2, 'commit after undo: outcome only');
select is(pg_temp.assets(), 2, 'commit after undo: nothing created');

-- Undo outside the caller's update scope is blocked.
reset role;
set local session_replication_role = replica;  -- put row 2 back as the commit left it
update public.asset set deleted_at = null, updated_at = now() where id = '00000000-0000-0000-0000-0000000086a2';
update public.coverage set deleted_at = null, updated_at = now() where id = private.import_coverage_id('00000000-0000-0000-0000-0000000086a2');
set local session_replication_role = origin;
update public.import_row set undone_at = null where id = '00000000-0000-0000-0000-0000000086a2';
update public.user_group_assignment set scope_profile_id = '00000000-0000-0000-0000-0000000086f9'
where user_id = '00000000-0000-0000-0000-0000000000a1' and tenant_id = '00000000-0000-0000-0000-00000000000a';
update public.scope_profile_rule set category_id = '00000000-0000-0000-0000-0000000086c2'
where scope_profile_id = '00000000-0000-0000-0000-0000000086f9';
select tests.act_as('00000000-0000-0000-0000-0000000000a1', '00000000-0000-0000-0000-00000000000a');
select is(public.import_undo('00000000-0000-0000-0000-0000000086b1') -> 'blocked_by', '{"changed": 1, "out_of_scope": 1}',
  'undo outside the update scope: blocked');
reset role;
select is(pg_temp.live(), 2, 'out of scope: asset stays');

-- A row with a live child asset is blocked.
update public.user_group_assignment set scope_profile_id = null
where user_id = '00000000-0000-0000-0000-0000000000a1' and tenant_id = '00000000-0000-0000-0000-00000000000a';
insert into public.asset (tenant_id, name, category_id, parent_asset_id) values
  ('00000000-0000-0000-0000-00000000000a', 'Child 86', '00000000-0000-0000-0000-0000000086c1', '00000000-0000-0000-0000-0000000086a2');
select tests.act_as('00000000-0000-0000-0000-0000000000a1', '00000000-0000-0000-0000-00000000000a');
select is(public.import_undo('00000000-0000-0000-0000-0000000086b1') -> 'blocked_by', '{"changed": 1, "has_children": 1}',
  'a live child asset blocks undo of its parent');

-- K8: more than 2,000 rows is refused before anything is written.
reset role;
select pg_temp.batch('00000000-0000-0000-0000-0000000086b4', '00000000-0000-0000-0000-00000000000a', 2001,
  array['name', 'category']);
insert into public.import_row (tenant_id, batch_id, row_number, cells)
select '00000000-0000-0000-0000-00000000000a', '00000000-0000-0000-0000-0000000086b4', n + 1, jsonb_build_array('Cap86 ' || n, 'CMP86')
from generate_series(1, 2001) n;
select tests.act_as('00000000-0000-0000-0000-0000000000a1', '00000000-0000-0000-0000-00000000000a');
select throws_ok($$select public.import_commit('00000000-0000-0000-0000-0000000086b4')$$, '54000', null,
  'more than 2,000 rows: refused, split the file (K8)');

-- 2,000 rows: commit and undo time. Every row goes through the asset triggers (K1).
reset role;
update public.tenant set asset_tag_pattern = 'IMP-{SEQ:5}' where id = '00000000-0000-0000-0000-00000000000a';
select pg_temp.batch('00000000-0000-0000-0000-0000000086b3', '00000000-0000-0000-0000-00000000000a', 2000,
  array['name', 'category', 'location', 'oem_vendor', 'warranty_start', 'warranty_end']);
insert into public.import_row (tenant_id, batch_id, row_number, cells)
select '00000000-0000-0000-0000-00000000000a', '00000000-0000-0000-0000-0000000086b3', n + 1,
       jsonb_build_array('Imp86 m' || n, 'CMP86', 'P86', 'ATL86', '2026-01-01', '2028-01-01')
from generate_series(1, 2000) n;
create temp table t0 (t timestamptz);
grant all on t0 to authenticated;
insert into t0 values (clock_timestamp());
select tests.act_as('00000000-0000-0000-0000-0000000000a1', '00000000-0000-0000-0000-00000000000a');
select is((public.import_commit('00000000-0000-0000-0000-0000000086b3') ->> 'created_assets')::int, 2000, '2,000 rows committed');
select diag('commit 2,000 rows: ' || round(extract(epoch from clock_timestamp() - (select t from t0)), 1) || ' s');
select cmp_ok(extract(epoch from clock_timestamp() - (select t from t0)), '<', 120::numeric, '2,000 rows commit well inside the service timeout (K1)');
update t0 set t = clock_timestamp();
select is((public.import_undo('00000000-0000-0000-0000-0000000086b3') ->> 'undone')::int, 2000, '2,000 rows undone');
select diag('undo 2,000 rows: ' || round(extract(epoch from clock_timestamp() - (select t from t0)), 1) || ' s');
select cmp_ok(extract(epoch from clock_timestamp() - (select t from t0)), '<', 120::numeric, '2,000 rows undo well inside the service timeout (K1)');

select * from finish();
rollback;
