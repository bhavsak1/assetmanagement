-- Story 2.1: field_definition on the 1.4 RLS pattern, domain category_config (view, manage),
-- plus the shape rules G3 to G6 (data-model-goal2.md §1.2).
begin;
select plan(32);

select policies_are('public', 'field_definition', array['field_definition_select', 'field_definition_insert', 'field_definition_update']);
select ok(not has_table_privilege('authenticated', 'public.field_definition', 'delete'), 'no hard delete grant');
select ok(not has_column_privilege('authenticated', 'public.field_definition', 'key', 'update'), 'key is immutable');
select ok(not has_column_privilege('authenticated', 'public.field_definition', 'type', 'update'), 'type is immutable');

insert into public.asset_category (id, tenant_id, name) values
  ('00000000-0000-0000-0000-000000002a01', '00000000-0000-0000-0000-00000000000a', 'Pumps'),
  ('00000000-0000-0000-0000-000000002b01', '00000000-0000-0000-0000-00000000000b', 'B pumps');
insert into public.field_definition (id, tenant_id, entity, category_id, key, label, type, security_domain_id) values
  ('00000000-0000-0000-0000-000000002f01', '00000000-0000-0000-0000-00000000000a', 'asset', '00000000-0000-0000-0000-000000002a01',
   'rated_kw', 'Rated power', 'number', (select id from public.security_domain where code = 'asset_core')),
  ('00000000-0000-0000-0000-000000002f02', '00000000-0000-0000-0000-00000000000b', 'asset', null,
   'b_field', 'B field', 'text', (select id from public.security_domain where code = 'asset_core'));

-- Default deny.
select tests.act_as('00000000-0000-0000-0000-0000000000a1', '00000000-0000-0000-0000-00000000000a');
select is((select count(*)::int from public.field_definition), 0, 'no grant, no rows');
select throws_ok(
  $$insert into public.field_definition (tenant_id, entity, key, label, type, security_domain_id) values
    ('00000000-0000-0000-0000-00000000000a', 'asset', 'x', 'x', 'text', (select id from public.security_domain where code = 'asset_core'))$$,
  '42501', null, 'no grant, no insert'
);

-- view only.
reset role;
select tests.grant('00000000-0000-0000-0000-00000000000a', '00000000-0000-0000-0000-0000000000a1', 'category_config', '{view}');
select tests.act_as('00000000-0000-0000-0000-0000000000a1', '00000000-0000-0000-0000-00000000000a');
select results_eq('select key from public.field_definition', $$values ('rated_kw')$$, 'view reads own tenant rows');
select throws_ok(
  $$insert into public.field_definition (tenant_id, entity, key, label, type, security_domain_id) values
    ('00000000-0000-0000-0000-00000000000a', 'asset', 'x', 'x', 'text', (select id from public.security_domain where code = 'asset_core'))$$,
  '42501', null, 'view cannot insert'
);
select is_empty($$update public.field_definition set label = 'x' returning 1$$, 'view cannot update');

-- manage. security_domain needs users_security.view, so the domain ids go in a temp table.
reset role;
select tests.grant('00000000-0000-0000-0000-00000000000a', '00000000-0000-0000-0000-0000000000a1', 'category_config', '{manage}');
create temp table d as select code, id from public.security_domain;
grant select on d to authenticated;
select tests.act_as('00000000-0000-0000-0000-0000000000a1', '00000000-0000-0000-0000-00000000000a');
select lives_ok(
  $$insert into public.field_definition (id, tenant_id, entity, category_id, key, label, type, options, security_domain_id) values
    ('00000000-0000-0000-0000-000000002f03', '00000000-0000-0000-0000-00000000000a', 'asset', '00000000-0000-0000-0000-000000002a01',
     'fluid', 'Fluid', 'list', '[{"code":"oil","label":"Oil","is_active":true}]', (select id from d where code = 'asset_core'))$$,
  'manage inserts a list field on a category'
);
select lives_ok(
  $$insert into public.field_definition (tenant_id, entity, key, label, type, security_domain_id) values
    ('00000000-0000-0000-0000-00000000000a', 'asset', 'purchase_rate', 'Rate', 'number', (select id from d where code = 'asset_financials'))$$,
  'an asset field can sit in a restricted asset domain'
);
select lives_ok(
  $$insert into public.field_definition (tenant_id, entity, key, label, type, security_domain_id) values
    ('00000000-0000-0000-0000-00000000000a', 'vendor', 'gstin', 'GSTIN', 'text', (select id from d where code = 'vendor_tax_ids'))$$,
  'a vendor field in a vendor domain'
);
select throws_ok(
  $$insert into public.field_definition (tenant_id, entity, key, label, type, security_domain_id) values
    ('00000000-0000-0000-0000-00000000000a', 'asset', 'x', 'x', 'text', (select id from d where code = 'vendor_tax_ids'))$$,
  '23503', null, 'G6: an asset field cannot use a vendor domain'
);
select throws_ok(
  $$insert into public.field_definition (tenant_id, entity, category_id, key, label, type, security_domain_id) values
    ('00000000-0000-0000-0000-00000000000a', 'vendor', '00000000-0000-0000-0000-000000002a01', 'x', 'x', 'text', (select id from d where code = 'vendor_core'))$$,
  '23514', null, 'only asset fields take a category'
);
select throws_ok(
  $$insert into public.field_definition (tenant_id, entity, category_id, key, label, type, security_domain_id) values
    ('00000000-0000-0000-0000-00000000000a', 'asset', '00000000-0000-0000-0000-000000002b01', 'x', 'x', 'text', (select id from d where code = 'asset_core'))$$,
  '23503', null, 'category in another tenant is refused'
);
select throws_ok(
  $$insert into public.field_definition (tenant_id, entity, key, label, type, security_domain_id) values
    ('00000000-0000-0000-0000-00000000000a', 'asset', 'Rated KW', 'x', 'text', (select id from d where code = 'asset_core'))$$,
  '23514', null, 'key must be lower snake_case'
);
select throws_ok(
  $$insert into public.field_definition (tenant_id, entity, key, label, type, security_domain_id) values
    ('00000000-0000-0000-0000-00000000000a', 'asset', 'x', 'x', 'list', (select id from d where code = 'asset_core'))$$,
  '23514', null, 'a list needs options'
);
select throws_ok(
  $$insert into public.field_definition (tenant_id, entity, key, label, type, options, security_domain_id) values
    ('00000000-0000-0000-0000-00000000000a', 'asset', 'x', 'x', 'text', '[{"code":"a"}]', (select id from d where code = 'asset_core'))$$,
  '23514', null, 'only a list has options'
);
select lives_ok($$update public.field_definition set label = 'Motor power', is_required = true where key = 'rated_kw'$$, 'manage edits label and required');
select throws_ok($$update public.field_definition set key = 'power' where key = 'rated_kw'$$, '42501', null, 'key cannot change');
select lives_ok($$update public.field_definition set deleted_at = now() where key = 'rated_kw'$$, 'manage soft deletes');
select throws_ok(
  $$insert into public.field_definition (tenant_id, entity, key, label, type, security_domain_id) values
    ('00000000-0000-0000-0000-00000000000a', 'asset', 'rated_kw', 'x', 'number', (select id from d where code = 'asset_core'))$$,
  '23505', null, 'G4: a deleted key is never reused'
);

-- Tenant B is read_only.
reset role;
select tests.grant('00000000-0000-0000-0000-00000000000b', '00000000-0000-0000-0000-0000000000a1', 'category_config');
select tests.act_as('00000000-0000-0000-0000-0000000000a1', '00000000-0000-0000-0000-00000000000b');
select results_eq('select key from public.field_definition', $$values ('b_field')$$, 'read_only tenant reads');
select throws_ok(
  $$insert into public.field_definition (tenant_id, entity, key, label, type, security_domain_id) values
    ('00000000-0000-0000-0000-00000000000b', 'asset', 'x', 'x', 'text', (select id from d where code = 'asset_core'))$$,
  '42501', null, 'read_only tenant cannot insert'
);

reset role;
select * from tests.cross_tenant('public.field_definition', 'category_config',
  jsonb_build_object('entity', 'asset', 'key', 'ct_key', 'label', 'ct', 'type', 'text',
                     'security_domain_id', (select id from public.security_domain where code = 'asset_core')));

select * from finish();
rollback;
