-- Story 8.3: mapping catalog, save action and templates (docs/data-model-goal8.md §14).
-- Seed: tenant A active, B read_only; a1 in A and B.
begin;
select plan(45);

select policies_are('public', 'import_mapping_template',
  array['import_mapping_template_select', 'import_mapping_template_insert', 'import_mapping_template_update']);
select ok(not has_table_privilege('authenticated', 'public.import_mapping_template', 'delete'), 'template: no delete grant');
select ok(not has_table_privilege('authenticated', 'public.import_batch', 'update'), 'batch: still no update grant');

create function pg_temp.batch(p_id text, p_tenant text, p_status text default 'staged') returns void language sql as $$
  insert into public.import_batch (id, tenant_id, file_name, file_size, file_sha256, sheet_name, sheet_names, header_row, columns, row_count, status)
  values (p_id::uuid, p_tenant::uuid, 'assets.xlsx', 100, repeat('a', 64), 'Sheet1', '{Sheet1}', 1, '{Name,Cat,Cost}', 1, p_status);
$$;
grant execute on function pg_temp.batch(text, text, text) to authenticated;
create function pg_temp.targets() returns text[] language sql as $$
  select array_agg(target order by target) from public.import_target_catalog();
$$;
grant execute on function pg_temp.targets() to authenticated;

select pg_temp.batch('00000000-0000-0000-0000-0000000083a1', '00000000-0000-0000-0000-00000000000a');
select pg_temp.batch('00000000-0000-0000-0000-0000000083b1', '00000000-0000-0000-0000-00000000000b');
-- Two custom fields: one in asset_core, one in the restricted asset_financials domain.
insert into public.field_definition (tenant_id, entity, key, label, type, security_domain_id)
select '00000000-0000-0000-0000-00000000000a', 'asset', k, l, 'text', d.id
from (values ('rated_power', 'Rated power', 'asset_core'), ('book_value', 'Book value', 'asset_financials')) v (k, l, dc)
join public.security_domain d on d.code = v.dc;

-- Default deny.
select tests.act_as('00000000-0000-0000-0000-0000000000a1', '00000000-0000-0000-0000-00000000000a');
select is((select count(*)::int from public.import_target_catalog()), 0, 'no grant: empty catalog');
select throws_ok($$select public.import_save_mapping('00000000-0000-0000-0000-0000000083a1',
  '[{"target":"name","source":"user"},{"target":"category","source":"user"},{"target":"ignore","source":"user"}]')$$,
  '42501', null, 'no grant: cannot save a mapping');

-- review: sees the catalog and templates, cannot save or write templates.
reset role;
select tests.grant('00000000-0000-0000-0000-00000000000a', '00000000-0000-0000-0000-0000000000a1', 'excel_import', '{review}');
insert into public.import_mapping_template (id, tenant_id, name, headers, targets) values
  ('00000000-0000-0000-0000-0000000083c1', '00000000-0000-0000-0000-00000000000a', 'Pune', '{name,cat}', '{"name":"name","cat":"category"}');
select tests.act_as('00000000-0000-0000-0000-0000000000a1', '00000000-0000-0000-0000-00000000000a');
select ok('name' = any (pg_temp.targets()), 'review sees core targets');
select is((select count(*)::int from public.import_mapping_template where id::text like '%83c_'), 1, 'review reads templates');
select throws_ok($$insert into public.import_mapping_template (tenant_id, name, headers, targets)
  values ('00000000-0000-0000-0000-00000000000a', 'X', '{a}', '{}')$$, '42501', null, 'review cannot add a template');
select throws_ok($$select public.import_save_mapping('00000000-0000-0000-0000-0000000083a1',
  '[{"target":"name","source":"user"},{"target":"category","source":"user"},{"target":"ignore","source":"user"}]')$$,
  '42501', null, 'review cannot save a mapping');

-- run: M3, restricted fields are not offered and not accepted.
reset role;
select tests.grant('00000000-0000-0000-0000-00000000000a', '00000000-0000-0000-0000-0000000000a1', 'excel_import', '{run}');
select tests.act_as('00000000-0000-0000-0000-0000000000a1', '00000000-0000-0000-0000-00000000000a');
select ok(not 'purchase_value' = any (pg_temp.targets()), 'no asset_financials: purchase value not offered');
select ok(not 'custom:book_value' = any (pg_temp.targets()), 'no asset_financials: restricted custom field not offered');
select ok(not 'custom:rated_power' = any (pg_temp.targets()), 'no asset_core update: custom field not offered');
select ok(not 'warranty_end' = any (pg_temp.targets()), 'no coverage_contract.create: warranty not offered');
select throws_ok($$select public.import_save_mapping('00000000-0000-0000-0000-0000000083a1',
  '[{"target":"name","source":"user"},{"target":"category","source":"user"},{"target":"purchase_value","source":"user"}]')$$,
  '22023', 'mapping: unknown or not allowed target', 'restricted target refused');

reset role;
select tests.grant('00000000-0000-0000-0000-00000000000a', '00000000-0000-0000-0000-0000000000a1', 'asset_financials', '{view,update}');
select tests.grant('00000000-0000-0000-0000-00000000000a', '00000000-0000-0000-0000-0000000000a1', 'asset_core', '{view,update}');
select tests.grant('00000000-0000-0000-0000-00000000000a', '00000000-0000-0000-0000-0000000000a1', 'coverage_contract', '{create}');
select tests.act_as('00000000-0000-0000-0000-0000000000a1', '00000000-0000-0000-0000-00000000000a');
select ok('purchase_value' = any (pg_temp.targets()), 'asset_financials view and update: purchase value offered');
select ok('custom:book_value' = any (pg_temp.targets()) and 'custom:rated_power' = any (pg_temp.targets()), 'custom fields offered');
select ok('warranty_end' = any (pg_temp.targets()), 'coverage_contract.create: warranty offered');
select is((select count(*)::int from public.import_target_catalog() where required), 2, 'name and category are required');

-- Save checks (M4).
select throws_ok($$select public.import_save_mapping('00000000-0000-0000-0000-0000000083a1',
  '[{"target":"name","source":"user"},{"target":"category","source":"user"}]')$$,
  '22023', 'mapping: one entry per column', 'one entry per column');
select throws_ok($$select public.import_save_mapping('00000000-0000-0000-0000-0000000083a1',
  '[{"target":"name","source":"user"},{"target":"name","source":"user"},{"target":"category","source":"user"}]')$$,
  '22023', 'mapping: a target is used twice', 'a target once');
select throws_ok($$select public.import_save_mapping('00000000-0000-0000-0000-0000000083a1',
  '[{"target":"name","source":"user"},{"target":"ignore","source":"user"},{"target":"tag","source":"user"}]')$$,
  '22023', 'mapping: name and category are required', 'name and category required');
select throws_ok($$select public.import_save_mapping('00000000-0000-0000-0000-0000000083a1',
  '[{"target":"name","source":"user"},{"target":"category","source":"user"},{"target":"asset.secret","source":"user"}]')$$,
  '22023', 'mapping: unknown or not allowed target', 'unknown target refused');
select throws_ok($$select public.import_save_mapping('00000000-0000-0000-0000-0000000083a1',
  '[{"target":"name","source":"x"},{"target":"category","source":"user"},{"target":"ignore","source":"user"}]')$$,
  '22023', null, 'unknown source refused');
select throws_ok($$select public.import_save_mapping('00000000-0000-0000-0000-0000000083b1',
  '[{"target":"name","source":"user"},{"target":"category","source":"user"},{"target":"ignore","source":"user"}]')$$,
  'P0002', null, 'another tenant batch is not found');
select lives_ok($$select public.import_save_mapping('00000000-0000-0000-0000-0000000083a1',
  '[{"target":"name","source":"rules","extra":1},{"target":"category","source":"template"},{"target":"purchase_value","source":"user"}]',
  '00000000-0000-0000-0000-0000000083c1')$$, 'run saves a mapping');
select is((select status from public.import_batch where id = '00000000-0000-0000-0000-0000000083a1'), 'mapped', 'batch is mapped');
select is((select mapping from public.import_batch where id = '00000000-0000-0000-0000-0000000083a1'),
  '[{"target":"name","source":"rules"},{"target":"category","source":"template"},{"target":"purchase_value","source":"user"}]'::jsonb,
  'mapping stored without extra keys');
select is((select updated_by from public.import_batch where id = '00000000-0000-0000-0000-0000000083a1'),
  '00000000-0000-0000-0000-0000000000a1'::uuid, 'updated_by is the saver');
select throws_ok($$select pg_temp.batch('00000000-0000-0000-0000-0000000083a2', '00000000-0000-0000-0000-00000000000a', 'mapped')$$,
  '42501', null, 'a direct insert cannot skip the save');
select throws_ok($$update public.import_batch set status = 'mapped'$$, '42501', null, 'no direct update');

-- Templates: run adds, renames and removes (soft delete).
select lives_ok($$insert into public.import_mapping_template (id, tenant_id, name, headers, targets)
  values ('00000000-0000-0000-0000-0000000083c2', '00000000-0000-0000-0000-00000000000a', 'Nashik', '{name}', '{"name":"name"}')$$,
  'run adds a template');
select throws_ok($$insert into public.import_mapping_template (tenant_id, name, headers, targets)
  values ('00000000-0000-0000-0000-00000000000a', ' nashik ', '{name}', '{}')$$, '23505', null, 'template names are unique');
select lives_ok($$update public.import_mapping_template set deleted_at = now() where id = '00000000-0000-0000-0000-0000000083c2'$$,
  'run removes a template');
select throws_ok($$delete from public.import_mapping_template$$, '42501', null, 'no hard delete');

-- read_only tenant B: reads, no writes.
reset role;
select tests.grant('00000000-0000-0000-0000-00000000000b', '00000000-0000-0000-0000-0000000000a1', 'excel_import');
select tests.act_as('00000000-0000-0000-0000-0000000000a1', '00000000-0000-0000-0000-00000000000b');
select throws_ok($$select public.import_save_mapping('00000000-0000-0000-0000-0000000083b1',
  '[{"target":"name","source":"user"},{"target":"category","source":"user"},{"target":"ignore","source":"user"}]')$$,
  '42501', null, 'read_only tenant cannot save a mapping');
select throws_ok($$insert into public.import_mapping_template (tenant_id, name, headers, targets)
  values ('00000000-0000-0000-0000-00000000000b', 'B', '{a}', '{}')$$, '42501', null, 'read_only tenant cannot add a template');

-- Purge covers mapped batches.
reset role;
update public.import_batch set expires_at = now() - interval '1 minute' where id = '00000000-0000-0000-0000-0000000083a1';
select private.purge_expired_imports();
select is((select status from public.import_batch where id = '00000000-0000-0000-0000-0000000083a1'), 'expired', 'mapped batch expires');

select * from tests.cross_tenant('public.import_mapping_template', 'excel_import',
  '{"name": "ct-row", "headers": ["a"], "targets": {}}');

select * from finish();
rollback;
