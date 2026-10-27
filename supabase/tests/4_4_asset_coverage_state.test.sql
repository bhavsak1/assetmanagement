-- Story 4.4: stored coverage state on asset, its triggers and job, and the list coverage filter.
-- docs/data-model-goal4.md §33 to §38. Uses the seed (tenant A active in Asia/Kolkata, B read_only; a1
-- in A and B, no groups; admin.a ...a0001, planner.a ...a0003) and supabase/test_harness.sql.
begin;
select plan(48);

create function pg_temp.d(n int) returns date language sql as $$
  select (now() at time zone 'Asia/Kolkata')::date + n;
$$;
create function pg_temp.st(n int) returns text language sql as $$
  select coverage_state from public.asset where id = ('00000000-0000-0000-0000-00000044a0' || lpad(n::text, 2, '0'))::uuid;
$$;
create function pg_temp.states() returns text language sql as $$
  select string_agg(name || '=' || coverage_state, ',' order by name) from public.asset
  where id::text like '00000000-0000-0000-0000-00000044a0%' and tenant_id = '00000000-0000-0000-0000-00000000000a';
$$;
-- Names of the listed assets for a filter value, sorted.
create function pg_temp.names(p text) returns text language sql as $$
  select string_agg(name, ',' order by name) from public.list_assets(p_coverage => p, p_limit => 100);
$$;
grant execute on function pg_temp.names(text) to authenticated;

insert into public.vendor (id, tenant_id, name, roles, is_active) values
  ('00000000-0000-0000-0000-00000044e001', '00000000-0000-0000-0000-00000000000a', 'Siemens', '{oem}', true),
  ('00000000-0000-0000-0000-00000044e00b', '00000000-0000-0000-0000-00000000000b', 'B vendor', '{om}', true);
insert into public.asset_category (id, tenant_id, name) values
  ('00000000-0000-0000-0000-00000044c001', '00000000-0000-0000-0000-00000000000a', 'Machines'),
  ('00000000-0000-0000-0000-00000044c00b', '00000000-0000-0000-0000-00000000000b', 'B cat');
-- The seed's other tenant A assets have no coverage; keep them out of the name lists.
update public.asset set deleted_at = now() where tenant_id = '00000000-0000-0000-0000-00000000000a';
-- One asset per case (names sort the same in any collation):
-- a01 active, end at today + N; a02 warranty active plus AMC expiring; a03 ends today; a04 ended yesterday;
-- a05 only a future contract; a06 no links; a07 only a soft-deleted contract; a08 AMC active, warranty
-- expired; a09 extended warranty at today + N plus an expired warranty; a10 left for the trigger cases.
insert into public.asset (id, tenant_id, name, category_id)
select ('00000000-0000-0000-0000-00000044a0' || lpad(n::text, 2, '0'))::uuid, '00000000-0000-0000-0000-00000000000a',
       'a' || lpad(n::text, 2, '0'), '00000000-0000-0000-0000-00000044c001'
from generate_series(1, 10) n;
insert into public.asset (id, tenant_id, name, category_id) values
  ('00000000-0000-0000-0000-00000044a0bb', '00000000-0000-0000-0000-00000000000b', 'B asset', '00000000-0000-0000-0000-00000044c00b');
-- Default window N = 60: end today + 60 is active, today + 59 expiring.
insert into public.coverage (id, tenant_id, coverage_type, vendor_id, start_date, end_date)
select ('00000000-0000-0000-0000-00000044f0' || lpad(n::text, 2, '0'))::uuid, '00000000-0000-0000-0000-00000000000a', ty,
       '00000000-0000-0000-0000-00000044e001', s, e
from (values (1, 'warranty', pg_temp.d(-10), pg_temp.d(60)),
             (2, 'warranty', pg_temp.d(-10), pg_temp.d(300)), (3, 'amc', pg_temp.d(-10), pg_temp.d(59)),
             (4, 'warranty', pg_temp.d(-10), pg_temp.d(0)),
             (5, 'warranty', pg_temp.d(-400), pg_temp.d(-1)),
             (6, 'warranty', pg_temp.d(1), pg_temp.d(400)),
             (7, 'warranty', pg_temp.d(-10), pg_temp.d(400)),
             (8, 'warranty', pg_temp.d(-400), pg_temp.d(-5)), (9, 'amc', pg_temp.d(-10), pg_temp.d(200)),
             (10, 'extended_warranty', pg_temp.d(-10), pg_temp.d(60)), (11, 'warranty', pg_temp.d(-400), pg_temp.d(-30)),
             (12, 'amc', pg_temp.d(-10), pg_temp.d(100))) v (n, ty, s, e);
insert into public.coverage (id, tenant_id, coverage_type, vendor_id, start_date, end_date) values
  ('00000000-0000-0000-0000-00000044f0bb', '00000000-0000-0000-0000-00000000000b', 'amc', '00000000-0000-0000-0000-00000044e00b', pg_temp.d(-10), pg_temp.d(300));
-- a07's contract is soft-deleted after linking (a link needs a live contract), which refreshes it to none.
insert into public.coverage_asset (tenant_id, coverage_id, asset_id)
select '00000000-0000-0000-0000-00000000000a', ('00000000-0000-0000-0000-00000044f0' || lpad(k::text, 2, '0'))::uuid,
       ('00000000-0000-0000-0000-00000044a0' || lpad(a::text, 2, '0'))::uuid
from (values (1, 1), (2, 2), (3, 2), (4, 3), (5, 4), (6, 5), (7, 7), (8, 8), (9, 8), (10, 9), (11, 9)) v (k, a);
insert into public.coverage_asset (tenant_id, coverage_id, asset_id) values
  ('00000000-0000-0000-0000-00000000000b', '00000000-0000-0000-0000-00000044f0bb', '00000000-0000-0000-0000-00000044a0bb');
update public.coverage set deleted_at = now() where id = '00000000-0000-0000-0000-00000044f007';

-- States, set by the triggers.
select is(pg_temp.states(), 'a01=active,a02=expiring,a03=expiring,a04=out,a05=out,a06=none,a07=none,a08=active,a09=active,a10=none',
  'each case gets its state from the link and contract triggers');
select is((select coverage_state from public.asset where id = '00000000-0000-0000-0000-00000044a0bb'), 'active', 'tenant B asset has its own state');
select is((select coverage_state_until from public.asset where id = '00000000-0000-0000-0000-00000044a001'), pg_temp.d(1),
  'until: end at today + N becomes expiring tomorrow');
select is((select coverage_state_until from public.asset where id = '00000000-0000-0000-0000-00000044a003'), pg_temp.d(1),
  'until: ends today, changes tomorrow');
select is((select coverage_state_until from public.asset where id = '00000000-0000-0000-0000-00000044a005'), pg_temp.d(1),
  'until: a future contract starts tomorrow');
select ok((select coverage_state_until is null from public.asset where id = '00000000-0000-0000-0000-00000044a004'),
  'until: only expired contracts, no date changes it');
select ok((select coverage_state_until is null from public.asset where id = '00000000-0000-0000-0000-00000044a006'),
  'until: never covered, no date changes it');

-- The list filter, as planner.a.
select tests.act_as('00000000-0000-0000-0000-0000000a0003', '00000000-0000-0000-0000-00000000000a');
select is(pg_temp.names('active'), 'a01,a08,a09', 'filter active');
select is(pg_temp.names('expiring'), 'a02,a03', 'filter expiring');
select is(pg_temp.names('out'), 'a04,a05', 'filter out of coverage: expired or only future');
select is(pg_temp.names('none'), 'a06,a07,a10', 'filter never covered: no links, or only a soft-deleted contract');
select is(pg_temp.names(null), 'a01,a02,a03,a04,a05,a06,a07,a08,a09,a10', 'no coverage filter: every asset');
select is(pg_temp.names('lease'), null, 'unknown value matches nothing');
select is(public.count_assets(p_coverage => 'expiring'), 2, 'count takes the filter');
select is((select string_agg(name, ',') from public.list_assets(p_coverage => 'active', p_limit => 1,
  p_after_value => 'a01', p_after_id => '00000000-0000-0000-0000-00000044a001')), 'a08', 'keyset next page with the filter');
select ok((select bool_and(coverage_state is not null) from public.list_assets()), 'asset_view returns the state');
select throws_ok($$update public.asset set coverage_state = 'active' where id = '00000000-0000-0000-0000-00000044a006'$$,
  '42501', null, 'planner cannot write the state');
select tests.act_as('00000000-0000-0000-0000-0000000a0001', '00000000-0000-0000-0000-00000000000a');
select throws_ok($$update public.asset set coverage_state_until = current_date where id = '00000000-0000-0000-0000-00000044a006'$$,
  '42501', null, 'tenant admin cannot write it either');

-- asset_core.view without coverage_contract.view: the filter matches nothing.
reset role;
select tests.grant('00000000-0000-0000-0000-00000000000a', '00000000-0000-0000-0000-0000000000a1', 'asset_core', '{view}');
select tests.act_as('00000000-0000-0000-0000-0000000000a1', '00000000-0000-0000-0000-00000000000a');
select is(public.count_assets(p_coverage => 'none'), 0, 'no coverage_contract.view: filter matches nothing');
select is(public.count_assets(), 10, 'no coverage_contract.view: the list itself still shows');

-- Cross-tenant: a forged claim sees nothing; a1 in B sees only B's asset.
select tests.act_as('00000000-0000-0000-0000-0000000a0003', '00000000-0000-0000-0000-00000000000b');
select is(public.count_assets(p_coverage => 'active'), 0, 'forged tenant claim: nothing');
reset role;
select tests.grant('00000000-0000-0000-0000-00000000000b', '00000000-0000-0000-0000-0000000000a1', 'asset_core', '{view}');
select tests.grant('00000000-0000-0000-0000-00000000000b', '00000000-0000-0000-0000-0000000000a1', 'coverage_contract', '{view}');
select tests.act_as('00000000-0000-0000-0000-0000000000a1', '00000000-0000-0000-0000-00000000000b');
select is((select string_agg(name, ',') from public.list_assets(p_coverage => 'active')), 'B asset', 'tenant B: only its own asset');
reset role;

-- Trigger paths. A link insert, then its soft delete.
insert into public.coverage_asset (id, tenant_id, coverage_id, asset_id) values
  ('00000000-0000-0000-0000-00000044b010', '00000000-0000-0000-0000-00000000000a', '00000000-0000-0000-0000-00000044f012', '00000000-0000-0000-0000-00000044a010');
select is(pg_temp.st(10), 'active', 'link inserted: active');
update public.coverage_asset set deleted_at = now() where id = '00000000-0000-0000-0000-00000044b010';
select is(pg_temp.st(10), 'none', 'link soft-deleted: never covered again');
-- Contract dates: a01 moves to an end within N.
update public.coverage set end_date = pg_temp.d(30) where id = '00000000-0000-0000-0000-00000044f001';
select is(pg_temp.st(1), 'expiring', 'contract end moved: state follows');
-- Contract type: a02's AMC becomes a warranty, so the warranty group runs to + 300.
update public.coverage set coverage_type = 'warranty' where id = '00000000-0000-0000-0000-00000044f003';
select is(pg_temp.st(2), 'active', 'contract type changed: groups follow');
-- Contract soft delete: a08 loses its AMC; only the expired warranty is left.
update public.coverage set deleted_at = now() where id = '00000000-0000-0000-0000-00000044f009';
select is(pg_temp.st(8), 'out', 'contract soft-deleted: state follows');
-- One AMC over several assets in one statement.
insert into public.coverage_asset (tenant_id, coverage_id, asset_id)
select '00000000-0000-0000-0000-00000000000a', '00000000-0000-0000-0000-00000044f012', id
from public.asset where id in ('00000000-0000-0000-0000-00000044a006', '00000000-0000-0000-0000-00000044a007', '00000000-0000-0000-0000-00000044a010');
select is(pg_temp.states(), 'a01=expiring,a02=active,a03=expiring,a04=out,a05=out,a06=active,a07=active,a08=out,a09=active,a10=active',
  'one AMC linked to three assets in one statement: all three refreshed');
-- A vendor change on the contract is not a coverage change: no refresh needed, state kept.
update public.coverage set reference = 'X-1' where id = '00000000-0000-0000-0000-00000044f012';
select is(pg_temp.st(6), 'active', 'other contract edits keep the state');

-- A refresh is not an asset edit: updated_at stays, no audit row. A real edit still does both.
set local session_replication_role = replica;
update public.asset set updated_at = '2026-01-01' where id = '00000000-0000-0000-0000-00000044a006';
set local session_replication_role = origin;
select is(pg_temp.st(6), 'active', 'fixture');
create temp table audit_before as select count(*) as n from public.audit_log where record_id = '00000000-0000-0000-0000-00000044a006';
update public.coverage set end_date = pg_temp.d(10) where id = '00000000-0000-0000-0000-00000044f012';
select is(pg_temp.st(6), 'expiring', 'refresh changed the state');
select is((select updated_at from public.asset where id = '00000000-0000-0000-0000-00000044a006'), '2026-01-01'::timestamptz,
  'refresh does not move updated_at');
select is((select count(*) from public.audit_log where record_id = '00000000-0000-0000-0000-00000044a006'), (select n from audit_before),
  'refresh writes no asset audit row');
update public.asset set serial_number = 'SN-44' where id = '00000000-0000-0000-0000-00000044a006';
select isnt((select updated_at from public.asset where id = '00000000-0000-0000-0000-00000044a006'), '2026-01-01'::timestamptz,
  'a real edit still moves updated_at');
select is((select count(*) from public.audit_log where record_id = '00000000-0000-0000-0000-00000044a006'), (select n + 1 from audit_before),
  'a real edit still writes an audit row');

-- The job. Nothing due today: no change.
select is(private.refresh_due_coverage_states(), 0, 'job: nothing due, nothing written');
-- Tomorrow in the tenant's zone: a03 (ended today) goes out, a05 (starts tomorrow) goes active.
select ok(private.refresh_due_coverage_states(now() + interval '1 day') >= 2, 'job tomorrow: due assets refreshed');
select is(pg_temp.st(3) || ',' || pg_temp.st(5), 'out,active', 'job tomorrow: ended today is out, started tomorrow is active');
do $$ begin perform private.refresh_coverage_state(array(select id from public.asset where id::text like '00000000-0000-0000-0000-00000044a0%')); end $$;

-- Midnight is the tenant's: a03 ends today; at the same UTC moment one zone is past it and one is not.
update public.coverage set end_date = '2026-06-15' , start_date = '2026-01-01' where id = '00000000-0000-0000-0000-00000044f004';
update public.tenant set time_zone = 'Pacific/Pago_Pago' where id = '00000000-0000-0000-0000-00000000000a';
do $$ begin perform private.refresh_coverage_state(array['00000000-0000-0000-0000-00000044a003'::uuid], '2026-06-15 20:00+00'); end $$;
select is(pg_temp.st(3), 'expiring', 'Pago Pago (UTC-11): still 15 Jun, ends today');
update public.tenant set time_zone = 'Asia/Kolkata' where id = '00000000-0000-0000-0000-00000000000a';
do $$ begin perform private.refresh_coverage_state(array['00000000-0000-0000-0000-00000044a003'::uuid], '2026-06-15 20:00+00'); end $$;
select is(pg_temp.st(3), 'out', 'Kolkata (UTC+5:30): already 16 Jun, ended');
do $$ begin perform private.refresh_coverage_state(array['00000000-0000-0000-0000-00000044a003'::uuid]); end $$;

-- C15: N changes queue the tenant; the job walks it in batches and clears the queue.
update public.tenant set coverage_refresh_after = null where id = '00000000-0000-0000-0000-00000000000a';
update public.tenant set coverage_expiring_days = 365 where id = '00000000-0000-0000-0000-00000000000a';
select isnt((select coverage_refresh_after from public.tenant where id = '00000000-0000-0000-0000-00000000000a'), null,
  'N changed: tenant queued');
select is(pg_temp.st(9), 'active', 'before the job the old N still applies');
select ok(private.refresh_due_coverage_states(p_batch => 2) > 0, 'job refreshes the queued tenant in batches of 2');
select is((select coverage_refresh_after from public.tenant where id = '00000000-0000-0000-0000-00000000000a'), null,
  'queue cleared when the walk is done');
select is(pg_temp.st(9), 'expiring', 'N = 365: an end at + 60 is now expiring');

-- Plans on a larger tenant: each sort walks its coverage index with no sort.
set local session_replication_role = replica;
insert into public.asset (tenant_id, tag, name, category_id, status_id, coverage_state)
select '00000000-0000-0000-0000-00000000000a', 'BLK-' || lpad(n::text, 6, '0'), 'Bulk ' || n, '00000000-0000-0000-0000-00000044c001',
       (select id from public.asset_status where tenant_id = '00000000-0000-0000-0000-00000000000a' and code = 'active'),
       (array['active', 'expiring', 'out', 'none'])[n % 4 + 1]
from generate_series(1, 30000) n;
set local session_replication_role = origin;
analyze public.asset;
create function pg_temp.plan(q text) returns text language plpgsql as $$
declare
  r text;
  v text := '';
begin
  for r in execute 'explain ' || q loop
    v := v || r || E'\n';
  end loop;
  return v;
end;
$$;
select tests.act_as('00000000-0000-0000-0000-0000000a0003', '00000000-0000-0000-0000-00000000000a');
select matches(pg_temp.plan(private.asset_list_sql(null, null, null, null, 'name', 'Bulk 100', '00000000-0000-0000-0000-000000000000', 51, null, null, 'expiring')),
  'Index Scan using asset_coverage_name_idx[^\n]*\n[^\n]*Index Cond: [^\n]*ROW\(name, id\) >', 'name: walks asset_coverage_name_idx from the cursor');
select matches(pg_temp.plan(private.asset_list_sql(null, null, null, null, 'tag', 'BLK-001000', '00000000-0000-0000-0000-000000000000', 51, null, null, 'out')),
  'Index Scan using asset_coverage_tag_idx', 'tag: walks asset_coverage_tag_idx');
select matches(pg_temp.plan(private.asset_list_sql(null, null, null, null, 'updated', '2026-10-22', '00000000-0000-0000-0000-000000000000', 51, null, null, 'none')),
  'Index Scan using asset_coverage_updated_idx', 'updated: walks asset_coverage_updated_idx');
-- analyze writes the row count in place (not rolled back): remove the bulk rows and analyze again.
reset role;
set local session_replication_role = replica;
delete from public.asset where tag like 'BLK-%';
set local session_replication_role = origin;
analyze public.asset;

select * from finish();
rollback;
