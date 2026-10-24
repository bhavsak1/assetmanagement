-- Story 4.2: coverage, coverage_asset, coverage_view (OQ-26 visibility, value masking, live status),
-- asset_coverage, the expiring-days setting, merge_vendor and the vendor guard with coverage.
-- docs/data-model-goal4.md §18 to §25. Uses the seed (tenant A active in Asia/Kolkata, B read_only;
-- a1 in A and B, no groups) and supabase/test_harness.sql.
begin;
select plan(70);

-- Tenant A's today plus n days, for fixtures written as postgres.
create function pg_temp.d(n int) returns date language sql as $$
  select (now() at time zone 'Asia/Kolkata')::date + n;
$$;

insert into public.vendor (id, tenant_id, name, roles, is_active) values
  ('00000000-0000-0000-0000-00000042e001', '00000000-0000-0000-0000-00000000000a', 'Siemens',     '{oem}', true),
  ('00000000-0000-0000-0000-00000042e002', '00000000-0000-0000-0000-00000000000a', 'Atlas',       '{om}',  true),
  ('00000000-0000-0000-0000-00000042e003', '00000000-0000-0000-0000-00000000000a', 'Old works',   '{oem}', false),
  ('00000000-0000-0000-0000-00000042e004', '00000000-0000-0000-0000-00000000000a', 'Siemens dup', '{oem}', true),
  ('00000000-0000-0000-0000-00000042e00b', '00000000-0000-0000-0000-00000000000b', 'B vendor',    '{om}',  true);
insert into public.asset_category (id, tenant_id, name) values
  ('00000000-0000-0000-0000-00000042c001', '00000000-0000-0000-0000-00000000000a', 'Machines'),
  ('00000000-0000-0000-0000-00000042c00b', '00000000-0000-0000-0000-00000000000b', 'B cat');
insert into public.asset (id, tenant_id, name, category_id) values
  ('00000000-0000-0000-0000-00000042a001', '00000000-0000-0000-0000-00000000000a', 'Lathe',      '00000000-0000-0000-0000-00000042c001'),
  ('00000000-0000-0000-0000-00000042a002', '00000000-0000-0000-0000-00000000000a', 'Compressor', '00000000-0000-0000-0000-00000042c001'),
  ('00000000-0000-0000-0000-00000042a003', '00000000-0000-0000-0000-00000000000a', 'Chiller',    '00000000-0000-0000-0000-00000042c001'),
  ('00000000-0000-0000-0000-00000042a004', '00000000-0000-0000-0000-00000000000a', 'Gone',       '00000000-0000-0000-0000-00000042c001'),
  ('00000000-0000-0000-0000-00000042a00b', '00000000-0000-0000-0000-00000000000b', 'B asset',    '00000000-0000-0000-0000-00000042c00b');
-- k1..k7 on Lathe and Compressor (Chiller has none), k8 only on Gone (soft-deleted below), k9 on no asset.
insert into public.coverage (id, tenant_id, coverage_type, vendor_id, start_date, end_date, contract_value, contract_currency) values
  ('00000000-0000-0000-0000-00000042f001', '00000000-0000-0000-0000-00000000000a', 'warranty',          '00000000-0000-0000-0000-00000042e001', pg_temp.d(0),    pg_temp.d(365), 1000, 'INR'),
  ('00000000-0000-0000-0000-00000042f002', '00000000-0000-0000-0000-00000000000a', 'amc',               '00000000-0000-0000-0000-00000042e002', pg_temp.d(-300), pg_temp.d(0),   null, null),
  ('00000000-0000-0000-0000-00000042f003', '00000000-0000-0000-0000-00000000000a', 'warranty',          '00000000-0000-0000-0000-00000042e001', pg_temp.d(-400), pg_temp.d(-1),  null, null),
  ('00000000-0000-0000-0000-00000042f004', '00000000-0000-0000-0000-00000000000a', 'amc',               '00000000-0000-0000-0000-00000042e002', pg_temp.d(10),   pg_temp.d(375), null, null),
  ('00000000-0000-0000-0000-00000042f005', '00000000-0000-0000-0000-00000000000a', 'extended_warranty', '00000000-0000-0000-0000-00000042e001', pg_temp.d(-10),  pg_temp.d(59),  null, null),
  ('00000000-0000-0000-0000-00000042f006', '00000000-0000-0000-0000-00000000000a', 'other',             '00000000-0000-0000-0000-00000042e002', pg_temp.d(-10),  pg_temp.d(60),  null, null),
  ('00000000-0000-0000-0000-00000042f007', '00000000-0000-0000-0000-00000000000a', 'warranty',          '00000000-0000-0000-0000-00000042e001', pg_temp.d(-700), pg_temp.d(-366), null, null),
  ('00000000-0000-0000-0000-00000042f008', '00000000-0000-0000-0000-00000000000a', 'other',             '00000000-0000-0000-0000-00000042e002', pg_temp.d(-5),   pg_temp.d(5),   null, null),
  ('00000000-0000-0000-0000-00000042f009', '00000000-0000-0000-0000-00000000000a', 'amc',               '00000000-0000-0000-0000-00000042e004', pg_temp.d(0),    pg_temp.d(30),  null, null),
  ('00000000-0000-0000-0000-00000042f00b', '00000000-0000-0000-0000-00000000000b', 'amc',               '00000000-0000-0000-0000-00000042e00b', pg_temp.d(0),    pg_temp.d(30),  null, null);
insert into public.coverage_asset (tenant_id, coverage_id, asset_id)
select '00000000-0000-0000-0000-00000000000a', ('00000000-0000-0000-0000-00000042f00' || k)::uuid, ('00000000-0000-0000-0000-00000042a00' || a)::uuid
from (values (1, 1), (2, 1), (7, 1), (3, 2), (4, 2), (5, 2), (6, 2), (8, 4)) v (k, a);
update public.asset set deleted_at = now() where id = '00000000-0000-0000-0000-00000042a004';

-- Data rules, for every writer.
select throws_ok($$insert into public.coverage (tenant_id, coverage_type, vendor_id, start_date, end_date) values
  ('00000000-0000-0000-0000-00000000000a', 'amc', '00000000-0000-0000-0000-00000042e003', '2026-01-01', '2026-12-31')$$,
  '23514', 'vendor_id: vendor is inactive or not found', 'inactive vendor refused');
select throws_ok($$insert into public.coverage (tenant_id, coverage_type, vendor_id, start_date, end_date) values
  ('00000000-0000-0000-0000-00000000000a', 'amc', '00000000-0000-0000-0000-00000042e00b', '2026-01-01', '2026-12-31')$$,
  '23514', null, 'another tenant''s vendor refused');
select throws_ok($$insert into public.coverage (tenant_id, coverage_type, vendor_id, start_date, end_date) values
  ('00000000-0000-0000-0000-00000000000a', 'amc', '00000000-0000-0000-0000-00000042e002', '2026-12-31', '2026-01-01')$$,
  '23514', null, 'end before start refused');
select throws_ok($$insert into public.coverage (tenant_id, coverage_type, vendor_id, start_date, end_date) values
  ('00000000-0000-0000-0000-00000000000a', 'lease', '00000000-0000-0000-0000-00000042e002', '2026-01-01', '2026-12-31')$$,
  '23514', null, 'unknown type refused');
select throws_ok($$insert into public.coverage_asset (tenant_id, coverage_id, asset_id) values
  ('00000000-0000-0000-0000-00000000000a', '00000000-0000-0000-0000-00000042f009', '00000000-0000-0000-0000-00000042a004')$$,
  '23514', null, 'link to a soft-deleted asset refused');
select throws_ok($$insert into public.coverage_asset (tenant_id, coverage_id, asset_id) values
  ('00000000-0000-0000-0000-00000000000a', '00000000-0000-0000-0000-00000042f009', '00000000-0000-0000-0000-00000042a00b')$$,
  '23514', null, 'link to another tenant''s asset refused');

-- No grant.
select tests.act_as('00000000-0000-0000-0000-0000000000a1', '00000000-0000-0000-0000-00000000000a');
select is((select count(*)::int from public.coverage_view), 0, 'no grant: coverage_view empty');
select is((select count(*)::int from public.asset_coverage(array['00000000-0000-0000-0000-00000042a001'::uuid])), 0,
  'no grant: asset_coverage empty');
select throws_ok($$insert into public.coverage (tenant_id, coverage_type, vendor_id, start_date, end_date) values
  ('00000000-0000-0000-0000-00000000000a', 'amc', '00000000-0000-0000-0000-00000042e002', '2026-01-01', '2026-12-31')$$,
  '42501', null, 'no grant: insert refused');

-- OQ-26: coverage view alone shows only the contract with no assets.
reset role;
select tests.grant('00000000-0000-0000-0000-00000000000a', '00000000-0000-0000-0000-0000000000a1', 'coverage_contract', '{view}');
select tests.act_as('00000000-0000-0000-0000-0000000000a1', '00000000-0000-0000-0000-00000000000a');
select results_eq('select id from public.coverage_view', $$values ('00000000-0000-0000-0000-00000042f009'::uuid)$$,
  'OQ-26: without a visible asset only the contract with no assets shows');
select is((select count(*)::int from public.coverage where id = '00000000-0000-0000-0000-00000042f001'), 0,
  'OQ-26: base table hides it too');

-- With asset view: every contract with a visible asset. k8 covers only a soft-deleted asset.
reset role;
select tests.grant('00000000-0000-0000-0000-00000000000a', '00000000-0000-0000-0000-0000000000a1', 'asset_core', '{view}');
select tests.act_as('00000000-0000-0000-0000-0000000000a1', '00000000-0000-0000-0000-00000000000a');
-- Status: start today active, end today expiring, end yesterday expired, future start, ends at today + 59
-- expiring, today + 60 active (N = 60).
select results_eq('select right(id::text, 2), status from public.coverage_view order by id',
  $$values ('01', 'active'), ('02', 'expiring'), ('03', 'expired'), ('04', 'future'), ('05', 'expiring'),
           ('06', 'active'), ('07', 'expired'), ('09', 'expiring')$$,
  'OQ-26 and status: contracts with a visible asset, each with its status');
select is((select count(*)::int from public.coverage_asset where coverage_id = '00000000-0000-0000-0000-00000042f008'), 0,
  'link to a soft-deleted asset is hidden');
select is((select contract_value from public.coverage_view where id = '00000000-0000-0000-0000-00000042f001'), null,
  'contract value masked without coverage_values.view');
select is((select contract_currency from public.coverage_view where id = '00000000-0000-0000-0000-00000042f001'), null,
  'contract currency masked without coverage_values.view');
select throws_ok('select contract_value from public.coverage', '42501', null, 'base table withholds the value column');
-- Per asset and group: overlapping warranty plus AMC on Lathe; extended warranty counts as warranty and
-- beats an expired warranty on Compressor; Chiller has no row (never covered).
select results_eq($$select right(asset_id::text, 2), coverage_group, status, right(coverage_id::text, 2)
  from public.asset_coverage(array['00000000-0000-0000-0000-00000042a001', '00000000-0000-0000-0000-00000042a002',
                                   '00000000-0000-0000-0000-00000042a003']::uuid[])$$,
  $$values ('01', 'amc', 'expiring', '02'), ('01', 'warranty', 'active', '01'),
           ('02', 'amc', 'future', '04'), ('02', 'other', 'active', '06'), ('02', 'warranty', 'expiring', '05')$$,
  'asset_coverage: best row per asset and group, none for a never covered asset');
select is((select vendor_id from public.asset_coverage(array['00000000-0000-0000-0000-00000042a001'::uuid]) where coverage_group = 'warranty'),
  '00000000-0000-0000-0000-00000042e001'::uuid, 'asset_coverage: responsible vendor of the best row');
select throws_ok($$insert into public.coverage (tenant_id, coverage_type, vendor_id, start_date, end_date) values
  ('00000000-0000-0000-0000-00000000000a', 'amc', '00000000-0000-0000-0000-00000042e002', '2026-01-01', '2026-12-31')$$,
  '42501', null, 'view: insert refused');
select is_empty($$update public.coverage set notes = 'x' where id = '00000000-0000-0000-0000-00000042f001' returning 1$$,
  'view: update touches nothing');
select throws_ok($$insert into public.coverage_asset (tenant_id, coverage_id, asset_id) values
  ('00000000-0000-0000-0000-00000000000a', '00000000-0000-0000-0000-00000042f009', '00000000-0000-0000-0000-00000042a003')$$,
  '42501', null, 'view: cannot link an asset');

-- Create and update (the Planner's grant).
reset role;
select tests.grant('00000000-0000-0000-0000-00000000000a', '00000000-0000-0000-0000-0000000000a1', 'coverage_contract', '{create,update}');
select tests.act_as('00000000-0000-0000-0000-0000000000a1', '00000000-0000-0000-0000-00000000000a');
select lives_ok($$insert into public.coverage (id, tenant_id, coverage_type, vendor_id, reference, start_date, end_date) values
  ('00000000-0000-0000-0000-00000042f010', '00000000-0000-0000-0000-00000000000a', 'warranty', '00000000-0000-0000-0000-00000042e001',
   '  WC-77  ', private.tenant_today(), private.tenant_today() + 10)$$, 'create: insert without a value');
select is((select reference from public.coverage_view where id = '00000000-0000-0000-0000-00000042f010'), 'WC-77', 'reference trimmed');
select throws_ok($$insert into public.coverage (tenant_id, coverage_type, vendor_id, start_date, end_date, contract_value, contract_currency) values
  ('00000000-0000-0000-0000-00000000000a', 'amc', '00000000-0000-0000-0000-00000042e002', '2026-01-01', '2026-12-31', 5, 'INR')$$,
  '42501', 'no permission to change contract value', 'create: value refused without coverage_values.update');
select throws_ok($$update public.coverage set contract_value = 5 where id = '00000000-0000-0000-0000-00000042f001'$$,
  '42501', 'no permission to change contract value', 'update: value change refused without coverage_values.update');
select isnt_empty($$update public.coverage set notes = 'renewal due' where id = '00000000-0000-0000-0000-00000042f001' returning 1$$,
  'update: notes saved, hidden value kept');
select throws_ok($$update public.coverage set vendor_id = '00000000-0000-0000-0000-00000042e003' where id = '00000000-0000-0000-0000-00000042f001'$$,
  '23514', null, 'update: change to an inactive vendor refused');
select lives_ok($$insert into public.coverage_asset (id, tenant_id, coverage_id, asset_id) values
  ('00000000-0000-0000-0000-00000042d010', '00000000-0000-0000-0000-00000000000a', '00000000-0000-0000-0000-00000042f010', '00000000-0000-0000-0000-00000042a003')$$,
  'update: links an asset');
select results_eq($$select coverage_group, status from public.asset_coverage(array['00000000-0000-0000-0000-00000042a003'::uuid])$$,
  $$values ('warranty', 'expiring')$$, 'Chiller is now covered');
select throws_ok($$update public.coverage set deleted_at = now() where id = '00000000-0000-0000-0000-00000042f010'$$,
  '42501', null, 'update: soft delete of a contract needs delete');
select isnt_empty($$update public.coverage_asset set deleted_at = now() where id = '00000000-0000-0000-0000-00000042d010' returning 1$$,
  'update: removes an asset from a contract');
select is((select count(*)::int from public.asset_coverage(array['00000000-0000-0000-0000-00000042a003'::uuid])), 0,
  'removed link: Chiller never covered again');
reset role;
select is((select count(*)::int from public.audit_log where table_name = 'coverage' and record_id = '00000000-0000-0000-0000-00000042f010'),
  1, 'audit row for the new contract');
select is((select count(*)::int from private.outbox_event where aggregate_id = '00000000-0000-0000-0000-00000042d010'),
  2, 'outbox events for the link and its removal');

-- Value domain.
select tests.grant('00000000-0000-0000-0000-00000000000a', '00000000-0000-0000-0000-0000000000a1', 'coverage_values', '{view,update}');
select tests.act_as('00000000-0000-0000-0000-0000000000a1', '00000000-0000-0000-0000-00000000000a');
select is((select contract_value from public.coverage_view where id = '00000000-0000-0000-0000-00000042f001'), 1000::numeric,
  'coverage_values.view: value shown');
select isnt_empty($$update public.coverage set contract_value = 1200 where id = '00000000-0000-0000-0000-00000042f001' returning 1$$,
  'coverage_values.update: value changed');

-- Delete.
reset role;
select tests.grant('00000000-0000-0000-0000-00000000000a', '00000000-0000-0000-0000-0000000000a1', 'coverage_contract', '{delete}');
select tests.act_as('00000000-0000-0000-0000-0000000000a1', '00000000-0000-0000-0000-00000000000a');
select isnt_empty($$update public.coverage set deleted_at = now() where id = '00000000-0000-0000-0000-00000042f010' returning 1$$,
  'delete: soft delete');
select is((select count(*)::int from public.coverage_view where id = '00000000-0000-0000-0000-00000042f010'), 0,
  'view hides a soft-deleted contract');
select throws_ok($$delete from public.coverage where id = '00000000-0000-0000-0000-00000042f001'$$,
  '42501', null, 'hard delete refused');

-- Read-only tenant.
reset role;
select tests.grant('00000000-0000-0000-0000-00000000000b', '00000000-0000-0000-0000-0000000000a1', 'coverage_contract');
select tests.act_as('00000000-0000-0000-0000-0000000000a1', '00000000-0000-0000-0000-00000000000b');
select results_eq('select id from public.coverage_view', $$values ('00000000-0000-0000-0000-00000042f00b'::uuid)$$, 'read_only tenant reads');
select throws_ok($$insert into public.coverage (tenant_id, coverage_type, vendor_id, start_date, end_date) values
  ('00000000-0000-0000-0000-00000000000b', 'amc', '00000000-0000-0000-0000-00000042e00b', '2026-01-01', '2026-12-31')$$,
  '42501', null, 'read_only tenant cannot insert');
select is_empty($$update public.coverage set notes = 'x' returning 1$$, 'read_only tenant cannot update');

-- Time zone boundary: the same moment is a different day in two zones (+14 and -11 are 25 hours apart).
-- A contract ending on Pago Pago's today is still covered there and already over in Kiritimati.
reset role;
insert into public.coverage (id, tenant_id, coverage_type, vendor_id, start_date, end_date) values
  ('00000000-0000-0000-0000-00000042f011', '00000000-0000-0000-0000-00000000000a', 'other', '00000000-0000-0000-0000-00000042e002',
   pg_temp.d(-30), (now() at time zone 'Pacific/Pago_Pago')::date);
update public.tenant set time_zone = 'Pacific/Pago_Pago' where id = '00000000-0000-0000-0000-00000000000a';
select tests.act_as('00000000-0000-0000-0000-0000000000a1', '00000000-0000-0000-0000-00000000000a');
select is((select status from public.coverage_view where id = '00000000-0000-0000-0000-00000042f011'), 'expiring',
  'time zone: last day still covered in the tenant''s zone');
reset role;
update public.tenant set time_zone = 'Pacific/Kiritimati' where id = '00000000-0000-0000-0000-00000000000a';
select tests.act_as('00000000-0000-0000-0000-0000000000a1', '00000000-0000-0000-0000-00000000000a');
select is((select status from public.coverage_view where id = '00000000-0000-0000-0000-00000042f011'), 'expired',
  'time zone: same moment, a day later in another zone');
reset role;
update public.tenant set time_zone = 'Asia/Kolkata' where id = '00000000-0000-0000-0000-00000000000a';

-- Expiring window setting (2.5 function, new last argument; null keeps it).
select tests.grant('00000000-0000-0000-0000-00000000000a', '00000000-0000-0000-0000-0000000000a1', 'tenant_settings', '{view,manage}');
select tests.act_as('00000000-0000-0000-0000-0000000000a1', '00000000-0000-0000-0000-00000000000a');
select throws_ok($$select public.update_tenant_settings('INR', 'en-IN', 'Asia/Kolkata', 'dd-MM-yyyy', 4::smallint, '{}', 400::smallint)$$,
  '23514', null, 'expiring days above 365 refused');
select public.update_tenant_settings('INR', 'en-IN', 'Asia/Kolkata', 'dd-MM-yyyy', 4::smallint, '{}', 30::smallint);
select is((select status from public.coverage_view where id = '00000000-0000-0000-0000-00000042f009'), 'active',
  'N = 30: a contract ending in 30 days is active');
select public.update_tenant_settings('INR', 'en-IN', 'Asia/Kolkata', 'dd-MM-yyyy', 4::smallint, '{}');
reset role;
select is((select coverage_expiring_days from public.tenant where id = '00000000-0000-0000-0000-00000000000a'), 30::smallint,
  'old six-argument call keeps the setting');

-- Merge repoints coverage; the vendor guard counts coverage.
select tests.grant('00000000-0000-0000-0000-00000000000a', '00000000-0000-0000-0000-0000000000a1', 'vendor_core');
select tests.act_as('00000000-0000-0000-0000-0000000000a1', '00000000-0000-0000-0000-00000000000a');
select lives_ok($$select public.merge_vendor('00000000-0000-0000-0000-00000042e004', '00000000-0000-0000-0000-00000042e001')$$,
  'merge: lives');
select lives_ok($$set constraints all immediate$$, 'merge: soft-delete guard passes at commit');
set constraints all deferred;
reset role;
select is((select vendor_id from public.coverage where id = '00000000-0000-0000-0000-00000042f009'),
  '00000000-0000-0000-0000-00000042e001'::uuid, 'merge: coverage repointed');
select is((select new_data ->> 'coverages' from public.audit_log where action = 'merge'
           and record_id = '00000000-0000-0000-0000-00000042e004'), '1', 'merge: coverage count in the audit row');
create function pg_temp.soft_delete(p_id uuid) returns void language plpgsql as $$
begin
  update public.vendor set deleted_at = now() where id = p_id;
  set constraints all immediate;
end;
$$;
select throws_ok($$select pg_temp.soft_delete('00000000-0000-0000-0000-00000042e002')$$,
  '23503', 'vendor is linked to coverage: merge it instead', 'soft delete of a vendor on live coverage refused');
set constraints all deferred;

-- Access path: a list page of 50 ids reads coverage_asset by its asset index, inlined, no per-asset call.
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
create temp table ids as
  select format('select * from public.asset_coverage(%L::uuid[])',
                array(select gen_random_uuid() from generate_series(1, 49)) || '00000000-0000-0000-0000-00000042a001'::uuid) as q;
grant select on ids to authenticated;
analyze public.coverage_asset;
select tests.act_as('00000000-0000-0000-0000-0000000000a1', '00000000-0000-0000-0000-00000000000a');
set local enable_seqscan = off;
select matches(pg_temp.plan((select q from ids)), 'coverage_asset_asset_idx', 'asset_coverage uses the asset index');
select doesnt_match(pg_temp.plan((select q from ids)), 'Function Scan on asset_coverage', 'asset_coverage is inlined');
reset enable_seqscan;

-- Cross-tenant harness: 8 tests each. a1 holds asset_core.view in A (above) and needs it in B for links.
reset role;
select tests.grant('00000000-0000-0000-0000-00000000000b', '00000000-0000-0000-0000-0000000000a1', 'asset_core', '{view}');
select * from tests.cross_tenant('public.coverage', 'coverage_contract',
  '{"coverage_type":"other","vendor_id":"00000000-0000-0000-0000-00000042e001","start_date":"2026-01-01","end_date":"2026-12-31"}',
  '{"vendor_id":"00000000-0000-0000-0000-00000042e00b"}');
select * from tests.cross_tenant('public.coverage_asset', 'coverage_contract',
  '{"coverage_id":"00000000-0000-0000-0000-00000042f009","asset_id":"00000000-0000-0000-0000-00000042a003"}',
  '{"coverage_id":"00000000-0000-0000-0000-00000042f00b","asset_id":"00000000-0000-0000-0000-00000042a00b"}');

select * from finish();
rollback;
