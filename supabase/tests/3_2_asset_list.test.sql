-- Story 3.2: list_assets(), count_assets(), the search helper, saved_view. docs/data-model-goal3.md Â§13.
-- Uses the seed (tenant A active, B read_only, starter role users) and supabase/test_harness.sql.
-- planner.a (...a0003) views assets without asset_financials; auditor.a (...a0005) views both.
begin;
select plan(59);

-- Fixtures as postgres: no signed-in user, so the user write rules do not apply.
insert into public.asset_category (id, tenant_id, parent_id, name) values
  ('00000000-0000-0000-0000-0000000032c1', '00000000-0000-0000-0000-00000000000a', null, 'Machines'),
  ('00000000-0000-0000-0000-0000000032c2', '00000000-0000-0000-0000-00000000000a', '00000000-0000-0000-0000-0000000032c1', 'CNC'),
  ('00000000-0000-0000-0000-0000000032c3', '00000000-0000-0000-0000-00000000000a', null, 'Utilities'),
  ('00000000-0000-0000-0000-0000000032cb', '00000000-0000-0000-0000-00000000000b', null, 'B cat');
insert into public.location (id, tenant_id, parent_id, name) values
  ('00000000-0000-0000-0000-0000000032e1', '00000000-0000-0000-0000-00000000000a', null, 'Pune'),
  ('00000000-0000-0000-0000-0000000032e2', '00000000-0000-0000-0000-00000000000a', '00000000-0000-0000-0000-0000000032e1', 'Bay 3'),
  ('00000000-0000-0000-0000-0000000032e3', '00000000-0000-0000-0000-00000000000a', null, 'Nashik');
insert into public.asset (id, tenant_id, name, category_id, location_id, status, serial_number, purchase_value, purchase_currency, deleted_at) values
  ('00000000-0000-0000-0000-0000000032a1', '00000000-0000-0000-0000-00000000000a', 'Lathe 04', '00000000-0000-0000-0000-0000000032c2',
   '00000000-0000-0000-0000-0000000032e2', 'active', 'SN-77', 1000, 'INR', null),
  ('00000000-0000-0000-0000-0000000032a2', '00000000-0000-0000-0000-00000000000a', 'Pump 01', '00000000-0000-0000-0000-0000000032c3',
   '00000000-0000-0000-0000-0000000032e3', 'in_stock', null, null, null, null),
  ('00000000-0000-0000-0000-0000000032a3', '00000000-0000-0000-0000-00000000000a', 'Pump 02', '00000000-0000-0000-0000-0000000032c1',
   '00000000-0000-0000-0000-0000000032e1', 'active', null, null, null, null),
  ('00000000-0000-0000-0000-0000000032a4', '00000000-0000-0000-0000-00000000000a', 'Pump 99', '00000000-0000-0000-0000-0000000032c3',
   null, 'active', null, null, null, now()),
  ('00000000-0000-0000-0000-0000000032b1', '00000000-0000-0000-0000-00000000000b', 'Pump B', '00000000-0000-0000-0000-0000000032cb',
   null, 'active', null, null, null, null);

-- Default deny: test.user has no groups.
select tests.act_as('00000000-0000-0000-0000-0000000000a1', '00000000-0000-0000-0000-00000000000a');
select is((select count(*)::int from public.list_assets()), 0, 'no grant, empty list');
select is((select count(*)::int from private.search_asset_ids('pump')), 0, 'no grant, search finds nothing');
select is(public.count_assets(), 0, 'no grant, count 0');

-- Planner in A.
select tests.act_as('00000000-0000-0000-0000-0000000a0003', '00000000-0000-0000-0000-00000000000a');
select results_eq($$select name from public.list_assets()$$,
  array['Lathe 04', 'Pump 01', 'Pump 02'], 'live rows of the own tenant, by name');
select is((select count(*)::int from private.search_asset_ids('pump')), 2, 'search skips deleted and other tenant rows');
select results_eq($$select name from public.list_assets(p_term => 'PUMP')$$, array['Pump 01', 'Pump 02'], 'search by name, any case');
select results_eq($$select name from public.list_assets(p_term => 'ast-0000')$$,
  array['Lathe 04', 'Pump 01', 'Pump 02'], 'search by tag');
select results_eq($$select name from public.list_assets(p_term => 'sn-77')$$, array['Lathe 04'], 'search by serial number');
select is((select count(*)::int from public.list_assets(p_term => '%')), 0, 'wildcards in the term are literal');
select is((select count(*)::int from public.list_assets(p_term => $t$x' or true --$t$)), 0, 'a quote in the term is data');
select is((select count(*)::int from public.list_assets(p_term => '  ')), 3, 'blank term is no search');
select results_eq($$select name from public.list_assets(p_status => 'in_stock')$$, array['Pump 01'], 'status filter: In Stock');
select results_eq($$select name from public.list_assets(p_category_id => '00000000-0000-0000-0000-0000000032c1')$$,
  array['Lathe 04', 'Pump 02'], 'category filter includes child categories');
select results_eq($$select name from public.list_assets(p_location_id => '00000000-0000-0000-0000-0000000032e1')$$,
  array['Lathe 04', 'Pump 02'], 'location filter includes child locations');
select results_eq($$select name from public.list_assets(p_term => 'pump', p_location_id => '00000000-0000-0000-0000-0000000032e3')$$,
  array['Pump 01'], 'search and filters combine');
select results_eq($$select name from public.list_assets(p_category_id => '00000000-0000-0000-0000-0000000032cb')$$,
  array[]::text[], 'another tenant category matches nothing');

-- Keyset paging.
select results_eq($$select name from public.list_assets(p_limit => 2)$$, array['Lathe 04', 'Pump 01'], 'first page');
select results_eq($$select name from public.list_assets(p_after_value => 'Pump 01', p_after_id => '00000000-0000-0000-0000-0000000032a2', p_limit => 2)$$,
  array['Pump 02'], 'next page by name starts after the cursor');
select results_eq($$select tag from public.list_assets(p_sort => 'tag', p_after_value => 'AST-00001', p_after_id => '00000000-0000-0000-0000-0000000032a1')$$,
  array['AST-00002', 'AST-00003'], 'next page by tag');
-- Replica role: set_updated_at would overwrite the test time.
reset role;
set local session_replication_role = replica;
update public.asset set updated_at = '2026-10-01' where id = '00000000-0000-0000-0000-0000000032a2';
set local session_replication_role = origin;
select tests.act_as('00000000-0000-0000-0000-0000000a0003', '00000000-0000-0000-0000-00000000000a');
select is((select name from public.list_assets(p_sort => 'updated') limit 1 offset 2), 'Pump 01', 'updated sort: newest first');
select results_eq($$select name from public.list_assets(p_sort => 'updated', p_after_value => '2026-10-01 00:00:00+00',
                    p_after_id => '00000000-0000-0000-0000-000000000000')$$,
  array['Pump 01'], 'next page by updated keeps rows with the cursor time and a later id');
select throws_ok($$select * from public.list_assets(p_sort => 'cost')$$, '22023', null, 'unknown sort refused');
select throws_ok($$select * from public.list_assets(p_limit => 101)$$, '22023', null, 'limit over 100 refused');
select is(public.count_assets(), 3, 'count');
select is(public.count_assets(p_term => 'pump'), 2, 'count with search');

-- Masking stays: the list reads asset_view.
select is((select purchase_value from public.list_assets(p_term => 'lathe')), null, 'planner: purchase value masked in the list');
select is((select purchase_value from public.list_assets(p_term => 'lathe')), null, 'planner: masked through search too');
select tests.act_as('00000000-0000-0000-0000-0000000a0005', '00000000-0000-0000-0000-00000000000a');
select is((select purchase_value from public.list_assets(p_term => 'lathe')), 1000.0000::numeric, 'auditor: purchase value shown');

-- Cross tenant: a2 is in B only and forges an A claim.
select tests.act_as('00000000-0000-0000-0000-0000000000a2', '00000000-0000-0000-0000-00000000000a');
select is((select count(*)::int from public.list_assets()), 0, 'forged tenant claim: empty list');
select is((select count(*)::int from private.search_asset_ids('pump')), 0, 'forged tenant claim: search finds nothing');
select is(private.location_subtree_ids('00000000-0000-0000-0000-0000000032e1'), '{}'::uuid[], 'forged tenant claim: no location ids');
-- Planner in B (read_only tenant) sees only B.
select tests.act_as('00000000-0000-0000-0000-0000000b0003', '00000000-0000-0000-0000-00000000000b');
select results_eq($$select name from public.list_assets(p_term => 'pump')$$, array['Pump B'], 'tenant B search sees only tenant B');

-- Access path on a large tenant (spike 1.7). Bulk rows skip the triggers; rolled back with the test.
reset role;
set local session_replication_role = replica;
insert into public.asset (tenant_id, tag, name, category_id, serial_number, status_id)
select '00000000-0000-0000-0000-00000000000a', 'BLK-' || lpad(n::text, 6, '0'),
       (array['Pump', 'Motor', 'Valve', 'Lathe'])[n % 4 + 1] || ' ' || n, '00000000-0000-0000-0000-0000000032c1', 'SN' || n,
       (select id from public.asset_status where tenant_id = '00000000-0000-0000-0000-00000000000a' and code = 'active')
from generate_series(1, 30000) n;
set local session_replication_role = origin;
-- New GIN entries sit in the pending list until a vacuum, which makes the planner avoid the index.
select gin_clean_pending_list('public.asset_search_trgm'::regclass);
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
select matches(pg_temp.plan(private.asset_list_sql(null, null, null, null, 'name', 'Pump 100', '00000000-0000-0000-0000-000000000000', 51)),
  'Index Scan using asset_name_idx[^\n]*\n[^\n]*Index Cond: [^\n]*ROW\(name, id\) >', 'name page starts at the cursor in asset_name_idx');
select doesnt_match(pg_temp.plan(private.asset_list_sql(null, null, null, null, 'name', 'Pump 100', '00000000-0000-0000-0000-000000000000', 51)),
  'Sort', 'name page needs no sort');
-- 3.7: the tenant status filter keeps the keyset walk.
select matches(pg_temp.plan(private.asset_list_sql(null, null, null, null, 'name', 'Pump 100', '00000000-0000-0000-0000-000000000000', 51,
  (select id from public.asset_status where tenant_id = '00000000-0000-0000-0000-00000000000a' and code = 'active'))),
  'Index Scan using asset_name_idx[^\n]*\n[^\n]*Index Cond: [^\n]*ROW\(name, id\) >', 'status_id filter: name page still starts at the cursor');
select matches(pg_temp.plan(private.asset_list_sql(null, 'active', null, null, 'updated', '2026-10-22', '00000000-0000-0000-0000-000000000000', 51)),
  'Index Scan using asset_updated_idx', 'updated page walks asset_updated_idx');
select matches(pg_temp.plan(private.asset_list_sql(null, null, null, null, 'tag', 'BLK-001000', '00000000-0000-0000-0000-000000000000', 51)),
  'Index Scan using asset_tag_uq', 'tag page walks asset_tag_uq');
select matches(pg_temp.plan(private.asset_list_sql('lathe 2999', null, null, null, 'name', null, null, 51)),
  'Index Cond: [^\n]*id = ANY', 'search list looks up the found ids in an index');
select doesnt_match(pg_temp.plan(private.asset_list_sql('lathe 2999', null, null, null, 'name', null, null, 51)),
  'Seq Scan', 'search list reads no whole table');
-- The helper's own statement: claims stay set after reset role.
reset role;
select matches(pg_temp.plan(private.asset_search_sql('lathe 2999')),
  'Bitmap Index Scan on asset_search_trgm', 'search uses the trigram index');
select doesnt_match(pg_temp.plan(private.asset_search_sql('lathe 2999')), 'Seq Scan', 'search reads no whole table');
-- analyze writes the row count in place (not rolled back). Remove the bulk rows and analyze again,
-- or later test runs plan for 30k assets.
set local session_replication_role = replica;
delete from public.asset where tag like 'BLK-%';
set local session_replication_role = origin;
analyze public.asset;

-- saved_view: personal, 1.4 pattern on asset_core.view.
select policies_are('public', 'saved_view', array['saved_view_select', 'saved_view_insert', 'saved_view_update']);
select ok(not has_table_privilege('authenticated', 'public.saved_view', 'delete'), 'saved_view: no hard delete grant');

select tests.act_as('00000000-0000-0000-0000-0000000000a1', '00000000-0000-0000-0000-00000000000a');
select throws_ok($$insert into public.saved_view (tenant_id, entity, name) values ('00000000-0000-0000-0000-00000000000a', 'asset', 'x')$$,
  '42501', null, 'no asset_core.view, no saved view');

select tests.act_as('00000000-0000-0000-0000-0000000a0003', '00000000-0000-0000-0000-00000000000a');
insert into public.saved_view (id, tenant_id, entity, name, filters, sort) values
  ('00000000-0000-0000-0000-0000000032f1', '00000000-0000-0000-0000-00000000000a', 'asset', 'In stock pumps',
   '{"q": "pump", "status": "in_stock"}', 'tag');
select results_eq($$select name, filters, sort from public.saved_view$$,
  $$values ('In stock pumps'::text, '{"q": "pump", "status": "in_stock"}'::jsonb, 'tag'::text)$$, 'planner saves and reads own view');
select throws_ok($$insert into public.saved_view (tenant_id, entity, name) values ('00000000-0000-0000-0000-00000000000a', 'asset', 'IN STOCK PUMPS')$$,
  '23505', null, 'view names are unique per user, any case');
select throws_ok($$insert into public.saved_view (tenant_id, user_id, entity, name)
                   values ('00000000-0000-0000-0000-00000000000a', '00000000-0000-0000-0000-0000000a0005', 'asset', 'x')$$,
  '42501', null, 'cannot save a view for another user');

select tests.act_as('00000000-0000-0000-0000-0000000a0005', '00000000-0000-0000-0000-00000000000a');
select is((select count(*)::int from public.saved_view), 0, 'another user sees none of my views');
update public.saved_view set name = 'taken' where id = '00000000-0000-0000-0000-0000000032f1';
select tests.act_as('00000000-0000-0000-0000-0000000a0003', '00000000-0000-0000-0000-00000000000a');
select is((select name from public.saved_view), 'In stock pumps', 'another user cannot change my view');
update public.saved_view set deleted_at = now() where id = '00000000-0000-0000-0000-0000000032f1';
select is((select count(*)::int from public.saved_view where deleted_at is not null), 1, 'owner soft deletes own view');

select tests.act_as('00000000-0000-0000-0000-0000000b0003', '00000000-0000-0000-0000-00000000000b');
select throws_ok($$insert into public.saved_view (tenant_id, entity, name) values ('00000000-0000-0000-0000-00000000000b', 'asset', 'x')$$,
  '42501', null, 'read_only tenant: no new views');

reset role;
select * from tests.cross_tenant('public.saved_view', 'asset_core',
  '{"name": "ct-row", "entity": "asset", "user_id": "00000000-0000-0000-0000-0000000000a1"}');

select * from finish();
rollback;
