-- Story 4.5: create_asset_with_warranty saves the asset, its warranty lines and their links in one
-- transaction, under the caller's RLS and triggers (docs/data-model-goal4.md §29).
-- Uses the seed (tenant A active, B read_only; a1 in A and B, no groups) and supabase/test_harness.sql.
begin;
select plan(20);

insert into public.vendor (id, tenant_id, name, roles, is_active) values
  ('00000000-0000-0000-0000-00000045e001', '00000000-0000-0000-0000-00000000000a', 'Kirloskar', '{oem}', true),
  ('00000000-0000-0000-0000-00000045e002', '00000000-0000-0000-0000-00000000000a', 'Old works', '{oem}', false),
  ('00000000-0000-0000-0000-00000045e00b', '00000000-0000-0000-0000-00000000000b', 'B vendor',  '{oem}', true);
insert into public.asset_category (id, tenant_id, name, oem_vendor_ids) values
  ('00000000-0000-0000-0000-00000045c001', '00000000-0000-0000-0000-00000000000a', 'Pumps', '{00000000-0000-0000-0000-00000045e001}'),
  ('00000000-0000-0000-0000-00000045c00b', '00000000-0000-0000-0000-00000000000b', 'B cat', '{}');

-- What the form sends: the 3.3 insert payload, and one line per warranty.
create function pg_temp.asset(id text, extra jsonb default '{}') returns jsonb language sql as $$
  select jsonb_build_object('id', id, 'tenant_id', '00000000-0000-0000-0000-00000000000a', 'name', 'Pump 45',
    'category_id', '00000000-0000-0000-0000-00000045c001', 'quantity', 1, 'purchase_date', '2026-03-15',
    'oem_vendor_id', '00000000-0000-0000-0000-00000045e001') || extra;
$$;
create function pg_temp.line(extra jsonb default '{}') returns jsonb language sql as $$
  select jsonb_build_array(jsonb_build_object('coverage_type', 'warranty', 'vendor_id', '00000000-0000-0000-0000-00000045e001',
    'reference', 'WC-1', 'start_date', '2026-03-15', 'end_date', '2028-03-14') || extra);
$$;
grant execute on function pg_temp.asset(text, jsonb), pg_temp.line(jsonb) to authenticated;

-- Planner shape: asset create, coverage view, create and update.
select tests.grant('00000000-0000-0000-0000-00000000000a', '00000000-0000-0000-0000-0000000000a1', 'asset_core', '{view,create}');
select tests.act_as('00000000-0000-0000-0000-0000000000a1', '00000000-0000-0000-0000-00000000000a');

select throws_ok($$select public.create_asset_with_warranty(pg_temp.asset('00000000-0000-0000-0000-00000045a001'), pg_temp.line())$$,
  '42501', null, 'without coverage_contract.create refused');
select lives_ok($$insert into public.asset (id, tenant_id, name, category_id) values
  ('00000000-0000-0000-0000-00000045a002', '00000000-0000-0000-0000-00000000000a', 'Plain', '00000000-0000-0000-0000-00000045c001')$$,
  'the plain asset insert still works');
reset role;
select is((select count(*)::int from public.asset where id = '00000000-0000-0000-0000-00000045a001'), 0, 'refused call left no asset');

select tests.grant('00000000-0000-0000-0000-00000000000a', '00000000-0000-0000-0000-0000000000a1', 'coverage_contract', '{view,create,update}');
select tests.act_as('00000000-0000-0000-0000-0000000000a1', '00000000-0000-0000-0000-00000000000a');

-- Warranty plus extended warranty, one call.
select is(public.create_asset_with_warranty(pg_temp.asset('00000000-0000-0000-0000-00000045a003'),
  pg_temp.line() || jsonb_build_array(jsonb_build_object('coverage_type', 'extended_warranty',
    'vendor_id', '00000000-0000-0000-0000-00000045e001', 'start_date', '2028-03-15', 'end_date', '2030-03-14'))),
  '00000000-0000-0000-0000-00000045a003'::uuid, 'returns the asset id');
reset role;
select ok((select tag from public.asset where id = '00000000-0000-0000-0000-00000045a003') is not null, 'tag generated (A1)');
select results_eq($$select c.coverage_type, c.start_date, c.end_date, c.reference from public.coverage c
    join public.coverage_asset ca on ca.coverage_id = c.id
    where ca.asset_id = '00000000-0000-0000-0000-00000045a003' order by c.start_date$$,
  $$values ('warranty', '2026-03-15'::date, '2028-03-14'::date, 'WC-1'), ('extended_warranty', '2028-03-15'::date, '2030-03-14'::date, null)$$,
  'both lines stored and linked to the asset');
select is((select status from public.asset_coverage(array['00000000-0000-0000-0000-00000045a003'::uuid]) where coverage_group = 'warranty'),
  'active', 'asset_coverage shows the warranty');
select is((select count(distinct transaction_id)::int from public.audit_log
    where record_id = '00000000-0000-0000-0000-00000045a003'
       or record_id in (select coverage_id from public.coverage_asset where asset_id = '00000000-0000-0000-0000-00000045a003')
       or record_id in (select id from public.coverage_asset where asset_id = '00000000-0000-0000-0000-00000045a003')), 1,
  'audit rows in one transaction');
select is((select count(*)::int from public.audit_log
    where record_id = '00000000-0000-0000-0000-00000045a003'
       or record_id in (select coverage_id from public.coverage_asset where asset_id = '00000000-0000-0000-0000-00000045a003')
       or record_id in (select id from public.coverage_asset where asset_id = '00000000-0000-0000-0000-00000045a003')), 5,
  'audit: asset, two coverages, two links');
select is((select count(*)::int from private.outbox_event
    where aggregate_id = '00000000-0000-0000-0000-00000045a003'
       or aggregate_id in (select coverage_id from public.coverage_asset where asset_id = '00000000-0000-0000-0000-00000045a003')
       or aggregate_id in (select id from public.coverage_asset where asset_id = '00000000-0000-0000-0000-00000045a003')), 5,
  'outbox: one event per row');

-- A failure in either part rolls back both.
update public.tenant set required_asset_fields = '{serial_number}' where id = '00000000-0000-0000-0000-00000000000a';
select tests.act_as('00000000-0000-0000-0000-0000000000a1', '00000000-0000-0000-0000-00000000000a');
select throws_ok($$select public.create_asset_with_warranty(pg_temp.asset('00000000-0000-0000-0000-00000045a004'), pg_temp.line())$$,
  '23502', null, 'missing mandatory field refused');
select throws_ok($$select public.create_asset_with_warranty(pg_temp.asset('00000000-0000-0000-0000-00000045a005', '{"serial_number": "S5"}'),
    pg_temp.line('{"vendor_id": "00000000-0000-0000-0000-00000045e002"}'))$$,
  '23514', 'vendor_id: vendor is inactive or not found', 'inactive warranty vendor refused');
select throws_ok($$select public.create_asset_with_warranty(pg_temp.asset('00000000-0000-0000-0000-00000045a006', '{"serial_number": "S6"}'),
    pg_temp.line('{"vendor_id": "00000000-0000-0000-0000-00000045e00b"}'))$$,
  '23514', null, 'another tenant''s vendor refused');
select throws_ok($$select public.create_asset_with_warranty(pg_temp.asset('00000000-0000-0000-0000-00000045a007',
    '{"serial_number": "S7", "category_id": "00000000-0000-0000-0000-00000045c00b"}'), pg_temp.line())$$,
  null, null, 'another tenant''s category refused');
select throws_ok($$select public.create_asset_with_warranty(pg_temp.asset('00000000-0000-0000-0000-00000045a008', '{"serial_number": "S8"}'),
    pg_temp.line('{"end_date": "2026-03-14"}'))$$,
  '23514', null, 'end before start refused');
select throws_ok($$select public.create_asset_with_warranty(pg_temp.asset('00000000-0000-0000-0000-00000045a009', '{"serial_number": "S9"}'),
    pg_temp.line('{"contract_value": 100}'))$$,
  '22023', 'coverages: unknown key', 'contract value key refused');
select throws_ok($$select public.create_asset_with_warranty(pg_temp.asset('00000000-0000-0000-0000-00000045a00a', '{"serial_number": "S10"}'),
    pg_temp.line('{"coverage_type": "amc"}'))$$,
  '22023', null, 'AMC refused (Coverage page only)');
reset role;
select is((select count(*)::int from public.asset where id::text like '00000000-0000-0000-0000-00000045a00%' and id <> '00000000-0000-0000-0000-00000045a002'
    and id <> '00000000-0000-0000-0000-00000045a003'), 0, 'no asset left behind by a failed call');
select is((select count(*)::int from public.coverage where tenant_id = '00000000-0000-0000-0000-00000000000a'
    and vendor_id = '00000000-0000-0000-0000-00000045e001'), 2, 'no coverage left behind by a failed call');

-- Read-only tenant: a1 also holds the grants there.
select tests.grant('00000000-0000-0000-0000-00000000000b', '00000000-0000-0000-0000-0000000000a1', 'asset_core', '{view,create}');
select tests.grant('00000000-0000-0000-0000-00000000000b', '00000000-0000-0000-0000-0000000000a1', 'coverage_contract', '{view,create,update}');
select tests.act_as('00000000-0000-0000-0000-0000000000a1', '00000000-0000-0000-0000-00000000000b');
select throws_ok($$select public.create_asset_with_warranty(jsonb_build_object('tenant_id', '00000000-0000-0000-0000-00000000000b',
    'name', 'B pump', 'category_id', '00000000-0000-0000-0000-00000045c00b'),
    jsonb_build_array(jsonb_build_object('coverage_type', 'warranty', 'vendor_id', '00000000-0000-0000-0000-00000045e00b',
      'start_date', '2026-01-01', 'end_date', '2026-12-31')))$$,
  '42501', null, 'read_only tenant refused');
reset role;

select * from finish();
rollback;
