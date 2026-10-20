-- Story 2.1: asset_category on the 1.4 RLS pattern, domain category_config (view, manage).
-- Uses the seed (tenant A active, B read_only; a1 in A and B) and supabase/test_harness.sql.
begin;
select plan(29);

select policies_are('public', 'asset_category', array['asset_category_select', 'asset_category_insert', 'asset_category_update']);
select ok(not has_table_privilege('authenticated', 'public.asset_category', 'delete'), 'no hard delete grant');

insert into public.asset_category (id, tenant_id, parent_id, name) values
  ('00000000-0000-0000-0000-000000002a01', '00000000-0000-0000-0000-00000000000a', null, 'Pumps'),
  ('00000000-0000-0000-0000-000000002a02', '00000000-0000-0000-0000-00000000000a', '00000000-0000-0000-0000-000000002a01', 'Centrifugal'),
  ('00000000-0000-0000-0000-000000002b01', '00000000-0000-0000-0000-00000000000b', null, 'B pumps');

-- Default deny.
select tests.act_as('00000000-0000-0000-0000-0000000000a1', '00000000-0000-0000-0000-00000000000a');
select is((select count(*)::int from public.asset_category), 0, 'no grant, no rows');
select throws_ok(
  $$insert into public.asset_category (tenant_id, name) values ('00000000-0000-0000-0000-00000000000a', 'x')$$,
  '42501', null, 'no grant, no insert'
);

-- view only.
reset role;
select tests.grant('00000000-0000-0000-0000-00000000000a', '00000000-0000-0000-0000-0000000000a1', 'category_config', '{view}');
select tests.act_as('00000000-0000-0000-0000-0000000000a1', '00000000-0000-0000-0000-00000000000a');
select results_eq('select name from public.asset_category order by name', $$values ('Centrifugal'), ('Pumps')$$, 'view reads own tenant rows');
select throws_ok(
  $$insert into public.asset_category (tenant_id, name) values ('00000000-0000-0000-0000-00000000000a', 'x')$$,
  '42501', null, 'view cannot insert'
);
select is_empty($$update public.asset_category set name = 'x' returning 1$$, 'view cannot update');
select is_empty($$update public.asset_category set deleted_at = now() returning 1$$, 'view cannot soft delete');

-- manage.
reset role;
select tests.grant('00000000-0000-0000-0000-00000000000a', '00000000-0000-0000-0000-0000000000a1', 'category_config', '{manage}');
select tests.act_as('00000000-0000-0000-0000-0000000000a1', '00000000-0000-0000-0000-00000000000a');
select lives_ok(
  $$insert into public.asset_category (id, tenant_id, parent_id, name) values
    ('00000000-0000-0000-0000-000000002a03', '00000000-0000-0000-0000-00000000000a', '00000000-0000-0000-0000-000000002a02', 'End suction')$$,
  'manage inserts a child category'
);
select throws_ok(
  $$insert into public.asset_category (tenant_id, parent_id, name) values
    ('00000000-0000-0000-0000-00000000000a', '00000000-0000-0000-0000-000000002b01', 'x')$$,
  '23503', null, 'parent in another tenant is refused'
);
select throws_ok(
  $$insert into public.asset_category (tenant_id, name) values ('00000000-0000-0000-0000-00000000000a', 'PUMPS')$$,
  '23505', null, 'name is unique per tenant, ignoring case'
);
select lives_ok($$update public.asset_category set description = 'All pumps' where id = '00000000-0000-0000-0000-000000002a01'$$, 'manage updates');
select throws_ok(
  $$update public.asset_category set parent_id = '00000000-0000-0000-0000-000000002a03' where id = '00000000-0000-0000-0000-000000002a01'$$,
  '23514', null, 'a grandchild cannot become the parent (cycle)'
);
select throws_ok(
  $$update public.asset_category set parent_id = id where id = '00000000-0000-0000-0000-000000002a01'$$,
  '23514', null, 'a category cannot be its own parent'
);
select lives_ok(
  $$update public.asset_category set parent_id = null where id = '00000000-0000-0000-0000-000000002a03'$$,
  'a child can move to top level'
);
select lives_ok($$update public.asset_category set is_active = false where id = '00000000-0000-0000-0000-000000002a03'$$, 'manage deactivates');
select lives_ok($$update public.asset_category set deleted_at = now() where id = '00000000-0000-0000-0000-000000002a03'$$, 'manage soft deletes');
select throws_ok($$delete from public.asset_category where id = '00000000-0000-0000-0000-000000002a03'$$, '42501', null, 'no hard delete');

-- Tenant B is read_only.
reset role;
select tests.grant('00000000-0000-0000-0000-00000000000b', '00000000-0000-0000-0000-0000000000a1', 'category_config');
select tests.act_as('00000000-0000-0000-0000-0000000000a1', '00000000-0000-0000-0000-00000000000b');
select results_eq('select name from public.asset_category', $$values ('B pumps')$$, 'read_only tenant reads');
select throws_ok(
  $$insert into public.asset_category (tenant_id, name) values ('00000000-0000-0000-0000-00000000000b', 'x')$$,
  '42501', null, 'read_only tenant cannot insert'
);
select is_empty($$update public.asset_category set name = 'x' returning 1$$, 'read_only tenant cannot update');

reset role;
select * from tests.cross_tenant('public.asset_category', 'category_config', '{"name":"ct-row"}');

select * from finish();
rollback;
