-- Story 3.4: asset_history (data-model-goal3.md §15). Tenant and asset_core.view checks, masking of
-- money and hidden custom keys in old and new values, order and keyset paging, actor name (H1).
-- Uses the seed (tenant A active, B read_only; a1 in A and B, no groups) and supabase/test_harness.sql.
begin;
select plan(15);

-- Fixtures as postgres: no signed-in user, so the create row is a system row.
insert into public.asset_category (id, tenant_id, name) values
  ('00000000-0000-0000-0000-0000000034c1', '00000000-0000-0000-0000-00000000000a', 'Pumps');
insert into public.field_definition (tenant_id, entity, key, label, type, security_domain_id)
select '00000000-0000-0000-0000-00000000000a', 'asset', f.key, f.key, 'number',
       (select id from public.security_domain where code = f.domain)
from (values ('head_m', 'asset_core'), ('cost_rate', 'asset_financials')) as f (key, domain);
insert into public.asset (id, tenant_id, name, category_id, purchase_value, purchase_currency, custom_values) values
  ('00000000-0000-0000-0000-0000000034a1', '00000000-0000-0000-0000-00000000000a', 'Pump 01', '00000000-0000-0000-0000-0000000034c1',
   5000, 'INR', '{"head_m": 30, "cost_rate": 12}');

-- No asset_core.view: nothing.
select tests.act_as('00000000-0000-0000-0000-0000000000a1', '00000000-0000-0000-0000-00000000000a');
select is((select count(*) from public.asset_history('00000000-0000-0000-0000-0000000034a1')), 0::bigint,
          'no rows without asset_core.view');

-- Planner shape: asset_core and asset_lifecycle, no asset_financials. Edit once, change status once.
reset role;
select tests.grant('00000000-0000-0000-0000-00000000000a', '00000000-0000-0000-0000-0000000000a1', 'asset_core', '{view,update}');
select tests.grant('00000000-0000-0000-0000-00000000000a', '00000000-0000-0000-0000-0000000000a1', 'asset_lifecycle', '{execute}');
select tests.act_as('00000000-0000-0000-0000-0000000000a1', '00000000-0000-0000-0000-00000000000a');
update public.asset set name = 'Pump 01A', custom_values = '{"head_m": 31}' where id = '00000000-0000-0000-0000-0000000034a1';
select public.change_asset_status('00000000-0000-0000-0000-0000000034a1', 'under_maintenance');

select is(array(select action from public.asset_history('00000000-0000-0000-0000-0000000034a1')),
          '{update,update,insert}'::text[], 'newest first: status, edit, create');
select is((select new_data ->> 'status' from public.asset_history('00000000-0000-0000-0000-0000000034a1') limit 1),
          'under_maintenance', 'status row on top');
select is((select new_data -> 'custom_values' from public.asset_history('00000000-0000-0000-0000-0000000034a1') offset 1 limit 1),
          '{"head_m": 31}'::jsonb, 'edit row: visible key changed, hidden key masked');
select is((select hidden_fields from public.asset_history('00000000-0000-0000-0000-0000000034a1') offset 1 limit 1),
          '{}'::text[], 'edit row: hidden key unchanged, so not listed');
select is((select new_data ?| array['purchase_value', 'purchase_currency'] from public.asset_history('00000000-0000-0000-0000-0000000034a1') offset 2),
          false, 'create row: money masked');
select is((select hidden_fields from public.asset_history('00000000-0000-0000-0000-0000000034a1') offset 2),
          '{purchase_value,purchase_currency,custom.cost_rate}'::text[], 'create row: masked fields named');
select is((select array[actor_type, actor_name] from public.asset_history('00000000-0000-0000-0000-0000000034a1') offset 2),
          '{system,NULL}'::text[], 'create row by the system');
select is((select actor_name from public.asset_history('00000000-0000-0000-0000-0000000034a1') limit 1),
          'Test User', 'actor name of an active member');

-- Keyset paging.
select is((select count(*) from public.asset_history('00000000-0000-0000-0000-0000000034a1', p_limit => 1)), 1::bigint, 'limit');
select is((select array_agg(h.action)
           from public.asset_history('00000000-0000-0000-0000-0000000034a1', p_limit => 2) last_row,
                public.asset_history('00000000-0000-0000-0000-0000000034a1', last_row.occurred_at, last_row.id) h
           where last_row.new_data ? 'name'),
          '{insert}'::text[], 'page after the edit row is the create row');

-- With asset_financials.view: money and the key show.
reset role;
select tests.grant('00000000-0000-0000-0000-00000000000a', '00000000-0000-0000-0000-0000000000a1', 'asset_financials', '{view}');
select tests.act_as('00000000-0000-0000-0000-0000000000a1', '00000000-0000-0000-0000-00000000000a');
select is((select array[new_data ->> 'purchase_value', new_data -> 'custom_values' ->> 'cost_rate']
           from public.asset_history('00000000-0000-0000-0000-0000000034a1') offset 2),
          '{5000.0000,12}'::text[], 'create row unmasked with the domains');
select is((select hidden_fields from public.asset_history('00000000-0000-0000-0000-0000000034a1') offset 2),
          '{}'::text[], 'nothing hidden');

-- Cross tenant: a1 with asset_core.view in tenant B cannot read tenant A's asset.
reset role;
select tests.grant('00000000-0000-0000-0000-00000000000b', '00000000-0000-0000-0000-0000000000a1', 'asset_core', '{view}');
select tests.act_as('00000000-0000-0000-0000-0000000000a1', '00000000-0000-0000-0000-00000000000b');
select is((select count(*) from public.asset_history('00000000-0000-0000-0000-0000000034a1')), 0::bigint,
          'no rows for an asset of another tenant');

-- anon cannot call it.
reset role;
set local role anon;
select throws_ok($$select public.asset_history('00000000-0000-0000-0000-0000000034a1')$$, '42501', null, 'anon refused');

select * from finish();
rollback;
