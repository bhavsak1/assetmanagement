-- Story 5.3: Maintenance reads (list_obligations, list_completions, maintenance_counts). docs/data-model-goal5.md §13.
-- Uses the seed (tenant A active in Asia/Kolkata, B read_only; a1 in A and B, no groups; planner.a ...a0003)
-- and supabase/test_harness.sql.
begin;
select plan(49);

create function pg_temp.d(n int) returns date language sql as $$
  select (now() at time zone 'Asia/Kolkata')::date + n;
$$;
create function pg_temp.ob(p_name text) returns uuid language sql security definer as $$
  select id from public.obligation where name = p_name and deleted_at is null;
$$;
-- Names of one open bucket, in list order.
create function pg_temp.names(p_bucket text) returns text language sql as $$
  select string_agg(name, ',' order by next_due_date, id) from public.list_obligations(p_bucket);
$$;
-- Walk every page of a bucket (null = Completed) two rows at a time; returns ids in walk order.
create function pg_temp.walk(p_bucket text) returns uuid[] language plpgsql as $$
declare
  v_ids uuid[] := '{}';
  v_val text;
  v_id uuid;
  r record;
  n int;
begin
  loop
    n := 0;
    if p_bucket is null then
      for r in select l.id, l.done_on::text as k from public.list_completions(p_after_value => v_val, p_after_id => v_id, p_limit => 2) l loop
        v_ids := v_ids || r.id; v_val := r.k; v_id := r.id; n := n + 1;
      end loop;
    else
      for r in select l.id, l.next_due_date::text as k from public.list_obligations(p_bucket, p_after_value => v_val, p_after_id => v_id, p_limit => 2) l loop
        v_ids := v_ids || r.id; v_val := r.k; v_id := r.id; n := n + 1;
      end loop;
    end if;
    exit when n < 2;
  end loop;
  return v_ids;
end;
$$;
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

-- Fixtures, as postgres. Categories: Machines > Pumps. Locations: Pune > Plant 1.
insert into public.asset_category (id, tenant_id, parent_id, name) values
  ('00000000-0000-0000-0000-00000053c001', '00000000-0000-0000-0000-00000000000a', null, 'Machines'),
  ('00000000-0000-0000-0000-00000053c002', '00000000-0000-0000-0000-00000000000a', '00000000-0000-0000-0000-00000053c001', 'Pumps'),
  ('00000000-0000-0000-0000-00000053c00b', '00000000-0000-0000-0000-00000000000b', null, 'B cat');
insert into public.location (id, tenant_id, parent_id, name) values
  ('00000000-0000-0000-0000-00000053d001', '00000000-0000-0000-0000-00000000000a', null, 'Pune'),
  ('00000000-0000-0000-0000-00000053d002', '00000000-0000-0000-0000-00000000000a', '00000000-0000-0000-0000-00000053d001', 'Plant 1');
insert into public.asset (id, tenant_id, tag, name, category_id, location_id, purchase_value, purchase_currency, in_service_date) values
  ('00000000-0000-0000-0000-00000053a001', '00000000-0000-0000-0000-00000000000a', 'LTH-1', 'Lathe', '00000000-0000-0000-0000-00000053c001', '00000000-0000-0000-0000-00000053d002', 1000, 'INR', '2020-01-15'),
  ('00000000-0000-0000-0000-00000053a002', '00000000-0000-0000-0000-00000000000a', 'PMP-1', 'Pump', '00000000-0000-0000-0000-00000053c002', '00000000-0000-0000-0000-00000053d001', null, null, null),
  ('00000000-0000-0000-0000-00000053a003', '00000000-0000-0000-0000-00000000000a', 'SPR-1', 'Spare', '00000000-0000-0000-0000-00000053c001', null, null, null, null),
  ('00000000-0000-0000-0000-00000053a004', '00000000-0000-0000-0000-00000000000a', 'GON-1', 'Gone', '00000000-0000-0000-0000-00000053c001', null, null, null, null),
  ('00000000-0000-0000-0000-00000053a0bb', '00000000-0000-0000-0000-00000000000b', 'B-1', 'B asset', '00000000-0000-0000-0000-00000053c00b', null, null, null, null);
insert into public.obligation (tenant_id, asset_id, name, obligation_type, interval_count, interval_unit, anchor, first_due_date, is_active)
select t, a, n, ty, c, u, an, pg_temp.d(f), act
from (values
  ('00000000-0000-0000-0000-00000000000a'::uuid, '00000000-0000-0000-0000-00000053a001'::uuid, 'od1', 'service', 1, 'month', 'completion', -10, true),
  ('00000000-0000-0000-0000-00000000000a'::uuid, '00000000-0000-0000-0000-00000053a001'::uuid, 'od2', 'inspection', 1, 'year', 'fixed', -3, true),
  ('00000000-0000-0000-0000-00000000000a'::uuid, '00000000-0000-0000-0000-00000053a001'::uuid, 'ds1', 'service', 3, 'month', 'completion', 5, true),
  ('00000000-0000-0000-0000-00000000000a'::uuid, '00000000-0000-0000-0000-00000053a001'::uuid, 'ds2', 'calibration', 1, 'year', 'fixed', 5, true),
  ('00000000-0000-0000-0000-00000000000a'::uuid, '00000000-0000-0000-0000-00000053a002'::uuid, 'ds3', 'service', 1, 'year', 'completion', 10, true),
  ('00000000-0000-0000-0000-00000000000a'::uuid, '00000000-0000-0000-0000-00000053a001'::uuid, 'sc1', 'service', 1, 'year', 'completion', 60, true),
  ('00000000-0000-0000-0000-00000000000a'::uuid, '00000000-0000-0000-0000-00000053a001'::uuid, 'c1', 'service', 1, 'year', 'completion', -5, true),
  ('00000000-0000-0000-0000-00000000000a'::uuid, '00000000-0000-0000-0000-00000053a002'::uuid, 'c2', 'service', 1, 'year', 'completion', -5, true),
  ('00000000-0000-0000-0000-00000000000a'::uuid, '00000000-0000-0000-0000-00000053a001'::uuid, 'off', 'service', 1, 'year', 'completion', -5, false),
  ('00000000-0000-0000-0000-00000000000a'::uuid, '00000000-0000-0000-0000-00000053a003'::uuid, 'sp', 'service', 1, 'year', 'completion', -5, true),
  ('00000000-0000-0000-0000-00000000000a'::uuid, '00000000-0000-0000-0000-00000053a004'::uuid, 'del', 'service', 1, 'year', 'completion', -5, true),
  ('00000000-0000-0000-0000-00000000000a'::uuid, '00000000-0000-0000-0000-00000053a001'::uuid, 'rm', 'service', 1, 'year', 'completion', -5, true),
  ('00000000-0000-0000-0000-00000000000b'::uuid, '00000000-0000-0000-0000-00000053a0bb'::uuid, 'bod', 'service', 1, 'year', 'completion', -5, true)
) v (t, a, n, ty, c, u, an, f, act);
-- Paused by asset: Spare inactive, Gone deleted. rm: a deleted obligation.
update public.asset set status = 'inactive',
  status_id = (select id from public.asset_status where tenant_id = '00000000-0000-0000-0000-00000000000a' and code = 'inactive')
  where id = '00000000-0000-0000-0000-00000053a003';
update public.asset set deleted_at = now() where id = '00000000-0000-0000-0000-00000053a004';
update public.obligation set deleted_at = now() where name = 'rm';
-- A tenant B record (B is read_only, so no action can write it).
insert into public.service_record (tenant_id, obligation_id, asset_id, done_on, advanced, cost_amount, cost_currency)
values ('00000000-0000-0000-0000-00000000000b', pg_temp.ob('bod'), '00000000-0000-0000-0000-00000053a0bb', pg_temp.d(-1), false, 9, 'USD');

-- Completions as the planner (plus asset_financials.view): c1 twice, c2 twice, then the latest c2 undone.
select tests.grant('00000000-0000-0000-0000-00000000000a', '00000000-0000-0000-0000-0000000a0003', 'asset_financials', '{view}');
select tests.act_as('00000000-0000-0000-0000-0000000a0003', '00000000-0000-0000-0000-00000000000a');
select public.complete_obligation(pg_temp.ob('c1'), pg_temp.d(-3));
select public.complete_obligation(pg_temp.ob('c1'), pg_temp.d(-2), p_cost => 500);
select public.complete_obligation(pg_temp.ob('c2'), pg_temp.d(-2));
select public.undo_completion(public.complete_obligation(pg_temp.ob('c2'), pg_temp.d(-1)));

-- Buckets follow the stored state; paused, deleted and other-tenant rows are in none.
select is(pg_temp.names('overdue'), 'od1,od2', 'Overdue: most overdue first');
select is((select string_agg(name, ',' order by next_due_date, name) from public.list_obligations('due_soon')), 'ds1,ds2,ds3', 'Due soon: soonest first');
select is((select string_agg(name, ',' order by next_due_date, name) from public.list_obligations('scheduled')), 'sc1,c1,c2', 'Scheduled: completed rows moved here');
select is((select count(*)::int from public.obligation o where o.due_state = 'paused' and o.deleted_at is null), 3, 'three paused rows exist (off, sp, del)');
select is((select count(*)::int from (select * from public.list_obligations('overdue') union all select * from public.list_obligations('due_soon')
           union all select * from public.list_obligations('scheduled')) x where x.name in ('off', 'sp', 'del', 'rm', 'bod')), 0,
  'paused, deleted and tenant B obligations are in no bucket');
select is((select string_agg(l.due_state, ',' order by l.next_due_date, l.id) from public.list_obligations('overdue') l),
  (select string_agg(o.due_state, ',' order by o.next_due_date, o.id) from public.obligation o where o.tenant_id = '00000000-0000-0000-0000-00000000000a' and o.due_state = 'overdue' and o.deleted_at is null and o.asset_id <> '00000000-0000-0000-0000-00000053a004'),
  'Overdue rows equal the stored overdue state');
select is((select tag || ' ' || asset_name || ' ' || purchase_value::int || ' ' || purchase_currency from public.list_obligations('overdue') limit 1),
  'LTH-1 Lathe 1000 INR', 'asset columns with the purchase value for asset_financials.view');

-- Filters.
select is((select string_agg(name, ',' order by name) from public.list_obligations('due_soon', p_category_id => '00000000-0000-0000-0000-00000053c001')), 'ds1,ds2,ds3', 'category with descendants');
select is((select string_agg(name, ',' order by name) from public.list_obligations('due_soon', p_category_id => '00000000-0000-0000-0000-00000053c002')), 'ds3', 'child category only');
select is((select string_agg(name, ',' order by name) from public.list_obligations('due_soon', p_location_id => '00000000-0000-0000-0000-00000053d001')), 'ds1,ds2,ds3', 'location with descendants');
select is((select string_agg(name, ',' order by name) from public.list_obligations('due_soon', p_location_id => '00000000-0000-0000-0000-00000053d002')), 'ds1,ds2', 'child location only');
select is(pg_temp.names('overdue'), (select string_agg(name, ',') from public.list_obligations('overdue', p_term => 'lth')), 'search by tag');
select is((select string_agg(name, ',' order by name) from public.list_obligations('due_soon', p_term => 'pump')), 'ds3', 'search by name');
select is((select string_agg(name, ',') from public.list_obligations('overdue', p_type => 'inspection')), 'od2', 'obligation type');
select is((select count(*)::int from public.list_obligations('overdue', p_coverage => 'none')), 2, 'coverage filter (4.4 state)');
select is((select count(*)::int from public.list_obligations('overdue', p_coverage => 'active')), 0, 'coverage filter excludes');
select is((select count(*)::int from public.list_obligations('overdue', p_category_id => '00000000-0000-0000-0000-00000053c00b')), 0, 'tenant B category as a filter: nothing');

-- Completed: newest first, undone record absent, cost for service_values.view.
select is((select string_agg(obligation_name || '@' || (done_on - pg_temp.d(0)), ',' order by done_on desc, obligation_name) from public.list_completions()),
  'c1@-2,c2@-2,c1@-3', 'Completed: undone c2 absent, B absent');

select is((select cost_amount::int || ' ' || cost_currency from public.list_completions(p_term => 'lathe') where cost_amount is not null), '500 INR', 'cost with service_values.view');
select is((select string_agg(distinct done_by_name, ',') is not null from public.list_completions()), true, 'done by name');
select is((select attachments from public.list_completions() limit 1), 0, 'attachments count');
select is((select count(*)::int from public.list_completions(p_category_id => '00000000-0000-0000-0000-00000053c002')), 1, 'Completed: category filter');

-- Keyset: every page of every bucket returns each row once, in list order (ties on the same date included).
select is(pg_temp.walk('due_soon'), (select array_agg(id order by next_due_date, id) from public.list_obligations('due_soon')), 'Due soon pages');
select is(pg_temp.walk('scheduled'), (select array_agg(id order by next_due_date, id) from public.list_obligations('scheduled')), 'Scheduled pages (tie)');
select is(pg_temp.walk(null), (select array_agg(id order by done_on desc, id) from public.list_completions()), 'Completed pages (tie)');

-- Counts match the lists.
select is((select row(overdue, due_soon, scheduled, completed)::text from public.maintenance_counts()), '(2,3,3,3)', 'counts per bucket');
select is((select row(next_7, next_30)::text from public.maintenance_counts()), '(2,3)', 'next 7 days and next 30 days');
select is((select row(overdue, due_soon, scheduled, completed)::text from public.maintenance_counts(p_category_id => '00000000-0000-0000-0000-00000053c002')), '(0,1,1,1)', 'counts take the filters');
select throws_ok($$select * from public.list_obligations('paused')$$, '22023', 'unknown bucket: paused', 'paused is not a bucket');
select throws_ok($$select * from public.list_completions(p_limit => 101)$$, '22023', 'limit must be 1 to 100', 'limit checked');

-- Permission steps for a1 (no groups in A).
reset role;
select tests.act_as('00000000-0000-0000-0000-0000000000a1', '00000000-0000-0000-0000-00000000000a');
select is((select overdue + due_soon + scheduled + completed from public.maintenance_counts()), 0, 'no grant: nothing');
reset role;
select tests.grant('00000000-0000-0000-0000-00000000000a', '00000000-0000-0000-0000-0000000000a1', 'obligation', '{view}');
select tests.act_as('00000000-0000-0000-0000-0000000000a1', '00000000-0000-0000-0000-00000000000a');
select is((select count(*)::int from public.list_obligations('overdue')), 0, 'obligation.view without asset_core.view: nothing');
reset role;
select tests.grant('00000000-0000-0000-0000-00000000000a', '00000000-0000-0000-0000-0000000000a1', 'asset_core', '{view}');
select tests.act_as('00000000-0000-0000-0000-0000000000a1', '00000000-0000-0000-0000-00000000000a');
select is(pg_temp.names('overdue'), 'od1,od2', 'obligation.view and asset_core.view: the bucket');
select is((select bool_and(purchase_value is null and purchase_currency is null) from public.list_obligations('overdue')), true, 'purchase value masked without asset_financials.view');
select is((select count(*)::int from public.list_completions()), 0, 'Completed needs service_record.view');
select is((select count(*)::int from public.list_obligations('overdue', p_coverage => 'none')), 0, 'coverage filter needs coverage_contract.view');
reset role;
select tests.grant('00000000-0000-0000-0000-00000000000a', '00000000-0000-0000-0000-0000000000a1', 'service_record', '{view}');
select tests.act_as('00000000-0000-0000-0000-0000000000a1', '00000000-0000-0000-0000-00000000000a');
select is((select count(*)::int from public.list_completions()), 3, 'service_record.view: Completed');
select is((select bool_and(cost_amount is null and cost_currency is null) from public.list_completions()), true, 'cost masked without service_values.view');
select is((select bool_and(vendor_name is null) from public.list_completions()), true, 'no vendor name without vendor_core.view');

-- Cross-tenant: a1 in tenant B with the same grants sees only B.
reset role;
select tests.grant('00000000-0000-0000-0000-00000000000b', '00000000-0000-0000-0000-0000000000a1', 'obligation', '{view}');
select tests.grant('00000000-0000-0000-0000-00000000000b', '00000000-0000-0000-0000-0000000000a1', 'asset_core', '{view}');
select tests.grant('00000000-0000-0000-0000-00000000000b', '00000000-0000-0000-0000-0000000000a1', 'service_record', '{view}');
select tests.act_as('00000000-0000-0000-0000-0000000000a1', '00000000-0000-0000-0000-00000000000b');
select is(pg_temp.names('overdue'), 'bod', 'tenant B: only B obligations');
select is((select string_agg(tag, ',') from public.list_completions()), 'B-1', 'tenant B: only B records');
select is((select count(*)::int from public.list_obligations('due_soon', p_category_id => '00000000-0000-0000-0000-00000053c001')), 0, 'tenant A category as a filter in B: nothing');

-- Plans on a larger tenant: each bucket walks its index, no sort. Bulk rows skip triggers.
reset role;
set local session_replication_role = replica;
insert into public.asset (id, tenant_id, tag, name, category_id, status_id)
select ('00000000-0000-0000-0001-' || lpad(n::text, 12, '0'))::uuid, '00000000-0000-0000-0000-00000000000a', 'BLK-' || lpad(n::text, 6, '0'), 'Bulk ' || n,
       '00000000-0000-0000-0000-00000053c001',
       (select id from public.asset_status where tenant_id = '00000000-0000-0000-0000-00000000000a' and code = 'active')
from generate_series(1, 20000) n;
insert into public.obligation (tenant_id, asset_id, name, obligation_type, interval_count, interval_unit, anchor, first_due_date, next_due_date, due_state)
select '00000000-0000-0000-0000-00000000000a', ('00000000-0000-0000-0001-' || lpad(n::text, 12, '0'))::uuid, 'Bulk ob', 'service', 1, 'year', 'completion',
       pg_temp.d(n % 400 - 20), pg_temp.d(n % 400 - 20),
       case when n % 400 < 20 then 'overdue' when n % 400 < 50 then 'due_soon' else 'scheduled' end
from generate_series(1, 20000) n;
insert into public.service_record (tenant_id, obligation_id, asset_id, done_on, advanced)
select '00000000-0000-0000-0000-00000000000a', o.id, o.asset_id, pg_temp.d(-(n % 365)), true
from generate_series(1, 20000) n
join public.obligation o on o.asset_id = ('00000000-0000-0000-0001-' || lpad(n::text, 12, '0'))::uuid;
set local session_replication_role = origin;
analyze public.asset;
analyze public.obligation;
analyze public.service_record;
select tests.act_as('00000000-0000-0000-0000-0000000a0003', '00000000-0000-0000-0000-00000000000a');
select matches(pg_temp.plan(private.obligation_list_sql('overdue', null, null, null, null, null, null, null, null, 51)),
  'Index Scan using obligation_state_idx', 'Overdue walks obligation_state_idx');
select matches(pg_temp.plan(private.obligation_list_sql('scheduled', null, null, null, null, null, null, pg_temp.d(100)::text, '00000000-0000-0000-0000-000000000000', 51)),
  'Index Scan using obligation_state_idx[^\n]*\n[^\n]*Index Cond: [^\n]*ROW\(next_due_date, id\) >', 'Scheduled deep page starts at the cursor');
select doesnt_match(pg_temp.plan(private.obligation_list_sql('due_soon', null, null, null, null, null, null, null, null, 51)),
  '\mSort\M', 'Due soon: no sort');
select matches(pg_temp.plan(private.completion_list_sql(null, null, null, null, null, null, null, null, 51)),
  'Index Scan using service_record_done_idx', 'Completed walks service_record_done_idx');
select doesnt_match(pg_temp.plan(private.completion_list_sql(null, null, null, null, null, null, pg_temp.d(-100)::text, '00000000-0000-0000-0000-000000000000', 51)),
  '\mSort\M', 'Completed deep page: no sort');
select is((select scheduled from public.maintenance_counts()), 10001, 'counts cap at 10,001');
select is((select count(*)::int from public.list_obligations('scheduled', p_term => 'Bulk')), 50, 'a term matching over 1,000 assets keeps the set form');
-- analyze writes the row counts in place (not rolled back): remove the bulk rows and analyze again.
reset role;
set local session_replication_role = replica;
delete from public.service_record where asset_id in (select id from public.asset where tag like 'BLK-%');
delete from public.obligation where name = 'Bulk ob';
delete from public.asset where tag like 'BLK-%';
set local session_replication_role = origin;
analyze public.asset;
analyze public.obligation;
analyze public.service_record;

select * from finish();
rollback;
