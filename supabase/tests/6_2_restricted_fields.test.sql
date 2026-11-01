-- Story 6.2: restricted fields on every read path, the R1 write rule and the R2 audit_log columns
-- (docs/data-model-goal6.md §13 to §16). Uses the seed (tenant A active, B read_only; a1 in A and B,
-- a2 in B) and supabase/test_harness.sql.
begin;
select plan(52);

-- Fixtures, as postgres. Tenant A: Pune and Mumbai, one asset each, a vendor with a GSTIN, a contract,
-- a service record, all with values. Tenant B: the same shape, for the cross-tenant checks.
insert into public.location (id, tenant_id, name) values
  ('00000000-0000-0000-0000-0000000062e1', '00000000-0000-0000-0000-00000000000a', 'Pune'),
  ('00000000-0000-0000-0000-0000000062e2', '00000000-0000-0000-0000-00000000000a', 'Mumbai');
insert into public.asset_category (id, tenant_id, name) values
  ('00000000-0000-0000-0000-0000000062c1', '00000000-0000-0000-0000-00000000000a', 'S62 Pumps'),
  ('00000000-0000-0000-0000-0000000062cb', '00000000-0000-0000-0000-00000000000b', 'S62 B cat');
insert into public.field_definition (tenant_id, entity, key, label, type, security_domain_id)
select '00000000-0000-0000-0000-00000000000a', f.entity, f.key, f.key, 'text', (select id from public.security_domain where code = f.domain)
from (values ('asset', 'cost_rate', 'asset_financials'), ('vendor', 'gstin', 'vendor_tax_ids')) as f (entity, key, domain);
insert into public.asset (id, tenant_id, name, category_id, location_id, purchase_value, purchase_currency, custom_values) values
  ('00000000-0000-0000-0000-0000000062a1', '00000000-0000-0000-0000-00000000000a', 'Pune pump', '00000000-0000-0000-0000-0000000062c1',
   '00000000-0000-0000-0000-0000000062e1', 5000, 'INR', '{"cost_rate": "12"}'),
  ('00000000-0000-0000-0000-0000000062a2', '00000000-0000-0000-0000-00000000000a', 'Mumbai pump', '00000000-0000-0000-0000-0000000062c1',
   '00000000-0000-0000-0000-0000000062e2', 7000, 'INR', '{}'),
  ('00000000-0000-0000-0000-0000000062ab', '00000000-0000-0000-0000-00000000000b', 'B pump', '00000000-0000-0000-0000-0000000062cb',
   null, 9000, 'INR', '{}');
insert into public.vendor (id, tenant_id, name, custom_values) values
  ('00000000-0000-0000-0000-0000000062b1', '00000000-0000-0000-0000-00000000000a', 'S62 vendor', '{"gstin": "27AAAAA0000A1Z5"}'),
  ('00000000-0000-0000-0000-0000000062bb', '00000000-0000-0000-0000-00000000000b', 'S62 B vendor', '{}');
insert into public.coverage (id, tenant_id, coverage_type, vendor_id, start_date, end_date, contract_value, contract_currency) values
  ('00000000-0000-0000-0000-0000000062f1', '00000000-0000-0000-0000-00000000000a', 'amc', '00000000-0000-0000-0000-0000000062b1',
   current_date - 1, current_date + 300, 1000, 'INR'),
  ('00000000-0000-0000-0000-0000000062fb', '00000000-0000-0000-0000-00000000000b', 'amc', '00000000-0000-0000-0000-0000000062bb',
   current_date - 1, current_date + 300, 3000, 'INR');
insert into public.coverage_asset (tenant_id, coverage_id, asset_id) values
  ('00000000-0000-0000-0000-00000000000a', '00000000-0000-0000-0000-0000000062f1', '00000000-0000-0000-0000-0000000062a1'),
  ('00000000-0000-0000-0000-00000000000b', '00000000-0000-0000-0000-0000000062fb', '00000000-0000-0000-0000-0000000062ab');
insert into public.obligation (id, tenant_id, asset_id, name, obligation_type, interval_count, interval_unit, anchor, first_due_date) values
  ('00000000-0000-0000-0001-0000000062a1', '00000000-0000-0000-0000-00000000000a', '00000000-0000-0000-0000-0000000062a1',
   'Service', 'service', 3, 'month', 'completion', current_date + 30),
  ('00000000-0000-0000-0001-0000000062ab', '00000000-0000-0000-0000-00000000000b', '00000000-0000-0000-0000-0000000062ab',
   'Service', 'service', 3, 'month', 'completion', current_date + 30);
insert into public.service_record (id, tenant_id, obligation_id, asset_id, done_on, advanced, cost_amount, cost_currency) values
  ('00000000-0000-0000-0002-0000000062a1', '00000000-0000-0000-0000-00000000000a', '00000000-0000-0000-0001-0000000062a1',
   '00000000-0000-0000-0000-0000000062a1', current_date - 10, false, 250, 'INR'),
  ('00000000-0000-0000-0002-0000000062ab', '00000000-0000-0000-0000-00000000000b', '00000000-0000-0000-0001-0000000062ab',
   '00000000-0000-0000-0000-0000000062ab', current_date - 10, false, 400, 'INR');

-- 1. Entity grants only (Planner and Technician shape): every restricted field is withheld.
select tests.grant('00000000-0000-0000-0000-00000000000a', '00000000-0000-0000-0000-0000000000a1', 'asset_core', '{view,update}');
select tests.grant('00000000-0000-0000-0000-00000000000a', '00000000-0000-0000-0000-0000000000a1', 'vendor_core', '{view}');
select tests.grant('00000000-0000-0000-0000-00000000000a', '00000000-0000-0000-0000-0000000000a1', 'coverage_contract', '{view,update}');
select tests.grant('00000000-0000-0000-0000-00000000000a', '00000000-0000-0000-0000-0000000000a1', 'service_record', '{view,update}');
select tests.grant('00000000-0000-0000-0000-00000000000a', '00000000-0000-0000-0000-0000000000a1', 'audit_log', '{view}');
select tests.act_as('00000000-0000-0000-0000-0000000000a1', '00000000-0000-0000-0000-00000000000a');

select throws_ok('select purchase_value from public.asset', '42501', null, 'no grant: asset table withholds purchase value');
select throws_ok('select custom_values from public.asset', '42501', null, 'no grant: asset table withholds custom values');
select is((select purchase_value from public.asset_view where id = '00000000-0000-0000-0000-0000000062a1'), null, 'no grant: asset_view masks purchase value');
select is((select purchase_currency from public.asset_view where id = '00000000-0000-0000-0000-0000000062a1'), null, 'no grant: asset_view masks currency');
select ok(not (select custom_values ? 'cost_rate' from public.asset_view where id = '00000000-0000-0000-0000-0000000062a1'),
  'no grant: asset_view drops the restricted custom key');
select is((select count(*) from public.list_assets() where purchase_value is not null), 0::bigint, 'no grant: list_assets masks purchase value');
select is((select count(*) from public.asset_history('00000000-0000-0000-0000-0000000062a1')
           where new_data ->> 'purchase_value' is not null or new_data -> 'custom_values' ? 'cost_rate'), 0::bigint,
  'no grant: asset_history masks money and the restricted key');
select ok((select hidden_fields @> '{purchase_value,custom.cost_rate}' from public.asset_history('00000000-0000-0000-0000-0000000062a1')
           where action = 'insert'), 'no grant: asset_history marks both hidden');
select throws_ok('select custom_values from public.vendor', '42501', null, 'no grant: vendor table withholds custom values (tax IDs)');
select ok(not (select custom_values ? 'gstin' from public.vendor_view where id = '00000000-0000-0000-0000-0000000062b1'),
  'no grant: vendor_view drops the GSTIN');
select throws_ok('select contract_value from public.coverage', '42501', null, 'no grant: coverage table withholds contract value');
select is((select contract_value from public.coverage_view where id = '00000000-0000-0000-0000-0000000062f1'), null, 'no grant: coverage_view masks contract value');
select throws_ok('select cost_amount from public.service_record', '42501', null, 'no grant: service_record table withholds cost');
select is((select cost_amount from public.service_record_view where id = '00000000-0000-0000-0002-0000000062a1'), null, 'no grant: service_record_view masks cost');
select is((select cost_amount from public.service_history('00000000-0000-0000-0000-0000000062a1')), null, 'no grant: service_history masks cost');

-- R2: audit_log.view reads who did what, never the row data.
select throws_ok('select old_data from public.audit_log', '42501', null, 'audit_log: old_data not readable');
select throws_ok('select new_data from public.audit_log', '42501', null, 'audit_log: new_data not readable');
select throws_ok('select * from public.audit_log', '42501', null, 'audit_log: select * refused');
select isnt_empty($$select id, action, table_name, actor_type from public.audit_log where record_id = '00000000-0000-0000-0000-0000000062a1'$$,
  'audit_log: the other columns still read');

-- R1: without view, a right guess, a wrong guess and a blank all pass and change nothing (no oracle).
select lives_ok($$update public.asset set purchase_value = 5000, purchase_currency = 'INR' where id = '00000000-0000-0000-0000-0000000062a1'$$,
  'asset: right guess passes');
select lives_ok($$update public.asset set purchase_value = 1 where id = '00000000-0000-0000-0000-0000000062a1'$$, 'asset: wrong guess passes too');
select lives_ok($$update public.asset set purchase_value = null, purchase_currency = null where id = '00000000-0000-0000-0000-0000000062a1'$$,
  'asset: blank passes too');
select lives_ok($$update public.coverage set contract_value = 1000 where id = '00000000-0000-0000-0000-0000000062f1'$$, 'coverage: right guess passes');
select lives_ok($$update public.coverage set contract_value = 2 where id = '00000000-0000-0000-0000-0000000062f1'$$, 'coverage: wrong guess passes too');
select lives_ok($$update public.service_record set cost_amount = 250 where id = '00000000-0000-0000-0002-0000000062a1'$$, 'service: right guess passes');
select lives_ok($$update public.service_record set cost_amount = 3, cost_currency = 'USD' where id = '00000000-0000-0000-0002-0000000062a1'$$,
  'service: wrong guess passes too');
reset role;
select results_eq($$select purchase_value, purchase_currency::text from public.asset where id = '00000000-0000-0000-0000-0000000062a1'$$,
  $$values (5000::numeric, 'INR'::text)$$, 'asset: stored value unchanged');
select is((select contract_value from public.coverage where id = '00000000-0000-0000-0000-0000000062f1'), 1000::numeric, 'coverage: stored value unchanged');
select results_eq($$select cost_amount, cost_currency::text from public.service_record where id = '00000000-0000-0000-0002-0000000062a1'$$,
  $$values (250::numeric, 'INR'::text)$$, 'service: stored value unchanged');

-- 2. Field view grants: every value shows on every reader; the tables still withhold the columns.
select tests.grant('00000000-0000-0000-0000-00000000000a', '00000000-0000-0000-0000-0000000000a1', 'asset_financials', '{view}');
select tests.grant('00000000-0000-0000-0000-00000000000a', '00000000-0000-0000-0000-0000000000a1', 'vendor_tax_ids', '{view}');
select tests.grant('00000000-0000-0000-0000-00000000000a', '00000000-0000-0000-0000-0000000000a1', 'coverage_values', '{view}');
select tests.grant('00000000-0000-0000-0000-00000000000a', '00000000-0000-0000-0000-0000000000a1', 'service_values', '{view}');
select tests.act_as('00000000-0000-0000-0000-0000000000a1', '00000000-0000-0000-0000-00000000000a');

select results_eq($$select purchase_value, purchase_currency::text from public.asset_view where id = '00000000-0000-0000-0000-0000000062a1'$$,
  $$values (5000::numeric, 'INR'::text)$$, 'grant: asset_view shows purchase value');
select is((select custom_values ->> 'cost_rate' from public.asset_view where id = '00000000-0000-0000-0000-0000000062a1'), '12',
  'grant: asset_view shows the restricted custom key');
select is((select purchase_value from public.list_assets() where id = '00000000-0000-0000-0000-0000000062a1'), 5000::numeric,
  'grant: list_assets shows purchase value');
select is((select count(*) from public.asset_history('00000000-0000-0000-0000-0000000062a1')
           where action = 'insert' and (new_data ->> 'purchase_value')::numeric = 5000 and new_data -> 'custom_values' ? 'cost_rate'),
  1::bigint, 'grant: asset_history shows money and the key');
select is((select custom_values ->> 'gstin' from public.vendor_view where id = '00000000-0000-0000-0000-0000000062b1'), '27AAAAA0000A1Z5',
  'grant: vendor_view shows the GSTIN');
select is((select contract_value from public.coverage_view where id = '00000000-0000-0000-0000-0000000062f1'), 1000::numeric,
  'grant: coverage_view shows contract value');
select is((select cost_amount from public.service_record_view where id = '00000000-0000-0000-0002-0000000062a1'), 250::numeric,
  'grant: service_record_view shows cost');
select is((select cost_amount from public.service_history('00000000-0000-0000-0000-0000000062a1')), 250::numeric, 'grant: service_history shows cost');
select throws_ok('select purchase_value from public.asset', '42501', null, 'grant: the asset table still withholds the column');
select throws_ok('select old_data from public.audit_log', '42501', null, 'grant: audit_log data still not readable');

-- R1: view but no update: a change still raises (they can see it, nothing to probe).
select throws_ok($$update public.asset set purchase_value = 1 where id = '00000000-0000-0000-0000-0000000062a1'$$,
  '42501', 'no permission to change purchase value', 'view, no update: asset change refused');
select throws_ok($$update public.coverage set contract_value = 2 where id = '00000000-0000-0000-0000-0000000062f1'$$,
  '42501', 'no permission to change contract value', 'view, no update: coverage change refused');
select throws_ok($$update public.service_record set cost_amount = 3 where id = '00000000-0000-0000-0002-0000000062a1'$$,
  '42501', 'no permission to change service cost', 'view, no update: service change refused');

-- View and update: the change saves.
reset role;
select tests.grant('00000000-0000-0000-0000-00000000000a', '00000000-0000-0000-0000-0000000000a1', 'asset_financials', '{update}');
select tests.act_as('00000000-0000-0000-0000-0000000000a1', '00000000-0000-0000-0000-00000000000a');
select lives_ok($$update public.asset set purchase_value = 6000 where id = '00000000-0000-0000-0000-0000000062a1'$$, 'view and update: change saves');
select is((select purchase_value from public.asset_view where id = '00000000-0000-0000-0000-0000000062a1'), 6000::numeric, 'view and update: new value shows');

-- 3. Cross-tenant: with every grant held in A, no tenant B row shows on any masked view.
select is((select count(*) from public.asset_view where tenant_id = '00000000-0000-0000-0000-00000000000b'), 0::bigint, 'cross-tenant: asset_view');
select is((select count(*) from public.vendor_view where tenant_id = '00000000-0000-0000-0000-00000000000b'), 0::bigint, 'cross-tenant: vendor_view');
select is((select count(*) from public.coverage_view where tenant_id = '00000000-0000-0000-0000-00000000000b'), 0::bigint, 'cross-tenant: coverage_view');
select is((select count(*) from public.service_record_view where tenant_id = '00000000-0000-0000-0000-00000000000b'), 0::bigint,
  'cross-tenant: service_record_view');
select is((select count(*) from public.asset_history('00000000-0000-0000-0000-0000000062ab')), 0::bigint, 'cross-tenant: asset_history');

-- 4. 6.1 scope: a2, scoped to Pune for asset_core.view and holding asset_financials.view, sees the value
-- on the Pune asset and does not see the Mumbai asset at all.
reset role;
insert into public.tenant_membership (tenant_id, user_id) values ('00000000-0000-0000-0000-00000000000a', '00000000-0000-0000-0000-0000000000a2');
insert into public.scope_profile (id, tenant_id, name) values
  ('00000000-0000-0000-0000-0000000062d0', '00000000-0000-0000-0000-00000000000a', 'S62 Pune');
insert into public.scope_profile_rule (tenant_id, scope_profile_id, dimension, location_id) values
  ('00000000-0000-0000-0000-00000000000a', '00000000-0000-0000-0000-0000000062d0', 'location', '00000000-0000-0000-0000-0000000062e1');
select tests.grant('00000000-0000-0000-0000-00000000000a', '00000000-0000-0000-0000-0000000000a2', 'asset_core', '{view}');
update public.user_group_assignment set scope_profile_id = '00000000-0000-0000-0000-0000000062d0'
where tenant_id = '00000000-0000-0000-0000-00000000000a' and user_id = '00000000-0000-0000-0000-0000000000a2';
select tests.grant('00000000-0000-0000-0000-00000000000a', '00000000-0000-0000-0000-0000000000a2', 'asset_financials', '{view}');
select tests.act_as('00000000-0000-0000-0000-0000000000a2', '00000000-0000-0000-0000-00000000000a');
select is((select purchase_value from public.asset_view where id = '00000000-0000-0000-0000-0000000062a1'), 6000::numeric,
  'scope: value shows on the in-scope asset');
select is((select count(*) from public.asset_view where id = '00000000-0000-0000-0000-0000000062a2'), 0::bigint,
  'scope: out-of-scope asset hidden, value with it');
select is((select count(*) from public.list_assets() where purchase_value is not null), 1::bigint, 'scope: list_assets shows one value');

select * from finish();
rollback;
