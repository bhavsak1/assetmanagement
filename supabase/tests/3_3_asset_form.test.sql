-- Story 3.3: what the asset form relies on in the database (data-model-goal3.md Â§14.2).
-- Hidden keys and masked columns survive a save by a user who cannot see them, a read-only key
-- cannot be removed, cross-tenant category and location are refused, mandatory missing is refused.
-- Uses the seed (tenant A active, B read_only; a1 in A and B, no groups) and supabase/test_harness.sql.
begin;
select plan(13);

-- Fixtures, as postgres before any act_as: no signed-in user, so the user rules do not apply.
insert into public.asset_category (id, tenant_id, name) values
  ('00000000-0000-0000-0000-0000000033c1', '00000000-0000-0000-0000-00000000000a', 'Pumps'),
  ('00000000-0000-0000-0000-0000000033cb', '00000000-0000-0000-0000-00000000000b', 'B cat');
insert into public.location (id, tenant_id, name) values
  ('00000000-0000-0000-0000-0000000033eb', '00000000-0000-0000-0000-00000000000b', 'B site');
insert into public.field_definition (tenant_id, entity, category_id, key, label, type, is_required, security_domain_id)
select '00000000-0000-0000-0000-00000000000a', 'asset', '00000000-0000-0000-0000-0000000033c1', f.key, f.key, f.type, f.required,
       (select id from public.security_domain where code = f.domain)
from (values ('head_m', 'number', false, 'asset_core'),
             ('cost_rate', 'number', false, 'asset_financials'),
             ('pump_no', 'text', true, 'asset_core')) as f (key, type, required, domain);
insert into public.asset (id, tenant_id, name, category_id, purchase_value, purchase_currency, custom_values) values
  ('00000000-0000-0000-0000-0000000033a1', '00000000-0000-0000-0000-00000000000a', 'Pump 01', '00000000-0000-0000-0000-0000000033c1',
   5000, 'INR', '{"head_m": 30, "cost_rate": 12, "pump_no": "P1"}');

-- Planner shape: asset_core view and update, no asset_financials.
select tests.grant('00000000-0000-0000-0000-00000000000a', '00000000-0000-0000-0000-0000000000a1', 'asset_core', '{view,update}');
select tests.act_as('00000000-0000-0000-0000-0000000000a1', '00000000-0000-0000-0000-00000000000a');

-- What the form sends: the visible keys from asset_view, edited; no money columns.
select lives_ok(
  $$update public.asset set name = 'Pump 01A', custom_values = '{"head_m": 32, "pump_no": "P1"}'
    where id = '00000000-0000-0000-0000-0000000033a1'$$,
  'save without the hidden key and money columns');
select throws_ok(
  $$update public.asset set purchase_value = null, purchase_currency = null where id = '00000000-0000-0000-0000-0000000033a1'$$,
  '42501', 'no permission to change purchase value', 'cannot blank money it cannot see');
reset role;
select is((select purchase_value from public.asset where id = '00000000-0000-0000-0000-0000000033a1'), 5000.0000, 'purchase value unchanged');
select is((select custom_values from public.asset where id = '00000000-0000-0000-0000-0000000033a1'),
          '{"head_m": 32, "cost_rate": 12, "pump_no": "P1"}'::jsonb, 'hidden key kept, visible key changed');

-- update on asset_financials without view: still blind, so still refused (3.3 gap 2).
select tests.grant('00000000-0000-0000-0000-00000000000a', '00000000-0000-0000-0000-0000000000a1', 'asset_financials', '{update}');
select tests.act_as('00000000-0000-0000-0000-0000000000a1', '00000000-0000-0000-0000-00000000000a');
select throws_ok(
  $$update public.asset set purchase_value = 1 where id = '00000000-0000-0000-0000-0000000033a1'$$,
  '42501', 'no permission to change purchase value', 'update without view cannot overwrite money');

-- view on asset_financials, no update: cost_rate is read-only on the form (3.3 gap 1).
reset role;
update public.group_domain_policy set deleted_at = now()
where tenant_id = '00000000-0000-0000-0000-00000000000a' and domain_operation_id = (
  select o.id from public.domain_operation o join public.security_domain d on d.id = o.security_domain_id
  where d.code = 'asset_financials' and o.code = 'update');
select tests.grant('00000000-0000-0000-0000-00000000000a', '00000000-0000-0000-0000-0000000000a1', 'asset_financials', '{view}');
select tests.act_as('00000000-0000-0000-0000-0000000000a1', '00000000-0000-0000-0000-00000000000a');
select lives_ok(
  $$update public.asset set custom_values = '{"head_m": 33, "cost_rate": 12, "pump_no": "P1"}' where id = '00000000-0000-0000-0000-0000000033a1'$$,
  'read-only key sent back unchanged');
select throws_ok(
  $$update public.asset set custom_values = '{"head_m": 33, "pump_no": "P1"}' where id = '00000000-0000-0000-0000-0000000033a1'$$,
  '42501', 'no permission to change custom field cost_rate', 'read-only key cannot be removed');
select lives_ok(
  $$update public.asset set custom_values = '{"cost_rate": 12, "pump_no": "P1"}' where id = '00000000-0000-0000-0000-0000000033a1'$$,
  'a key the user can update can be removed');

-- Create: cross-tenant category and location, mandatory missing.
reset role;
select tests.grant('00000000-0000-0000-0000-00000000000a', '00000000-0000-0000-0000-0000000000a1', 'asset_core', '{create}');
select tests.act_as('00000000-0000-0000-0000-0000000000a1', '00000000-0000-0000-0000-00000000000a');
select throws_ok(
  $$insert into public.asset (tenant_id, name, category_id) values
    ('00000000-0000-0000-0000-00000000000a', 'x', '00000000-0000-0000-0000-0000000033cb')$$,
  '23514', 'category is inactive or deleted', 'category of another tenant refused');
select throws_ok(
  $$insert into public.asset (tenant_id, name, category_id, location_id, custom_values) values
    ('00000000-0000-0000-0000-00000000000a', 'x', '00000000-0000-0000-0000-0000000033c1', '00000000-0000-0000-0000-0000000033eb', '{"pump_no": "P2"}')$$,
  '23514', 'location is inactive or deleted', 'location of another tenant refused');
select throws_ok(
  $$insert into public.asset (tenant_id, name, category_id) values
    ('00000000-0000-0000-0000-00000000000a', 'x', '00000000-0000-0000-0000-0000000033c1')$$,
  '23502', 'missing mandatory fields: pump_no', 'mandatory custom field missing refused');
select throws_ok(
  $$insert into public.asset (tenant_id, name, category_id, custom_values) values
    ('00000000-0000-0000-0000-00000000000a', 'x', '00000000-0000-0000-0000-0000000033c1', '{"pump_no": "P2", "cost_rate": 1}')$$,
  '42501', 'no permission to change custom field cost_rate', 'cannot set a read-only key on create');
select lives_ok(
  $$insert into public.asset (tenant_id, name, category_id, status, custom_values) values
    ('00000000-0000-0000-0000-00000000000a', 'Pump 02', '00000000-0000-0000-0000-0000000033c1', 'in_stock', '{"pump_no": "P2"}')$$,
  'create with the mandatory field, as In Stock');

select * from finish();
rollback;
