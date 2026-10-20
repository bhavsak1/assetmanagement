-- Story 2.3: location tree, closure table, tree rules and the 1.4 RLS pattern on location.
-- Uses the seed (tenant A active, B read_only; a1 in A and B) and supabase/test_harness.sql.
begin;
select plan(47);

-- Shape and grants.
select policies_are('public', 'location', array['location_select', 'location_insert', 'location_update']);
select ok(not has_table_privilege('authenticated', 'public.location', 'delete'), 'no hard delete grant');
select ok((select relrowsecurity from pg_class where oid = 'private.location_closure'::regclass), 'closure has RLS on');
select ok(not has_table_privilege('authenticated', 'private.location_closure', 'select')
          and not has_table_privilege('authenticated', 'private.location_closure', 'insert')
          and not has_table_privilege('authenticated', 'private.location_closure', 'update')
          and not has_table_privilege('authenticated', 'private.location_closure', 'delete'),
          'closure is closed to clients');
select results_eq(
  $$select o.code from public.domain_operation o join public.security_domain d on d.id = o.security_domain_id
    where d.code = 'location_hierarchy' order by o.sort_order$$,
  $$values ('view'), ('manage')$$,
  'location_hierarchy domain is in the catalog'
);

-- Tree in tenant A, as postgres: Pune > Plant 1 > Bay 3, Nashik > Plant 2.
insert into public.location (id, tenant_id, parent_id, name) values
  ('00000000-0000-0000-0000-000000000c01', '00000000-0000-0000-0000-00000000000a', null, 'Pune'),
  ('00000000-0000-0000-0000-000000000c02', '00000000-0000-0000-0000-00000000000a', '00000000-0000-0000-0000-000000000c01', 'Plant 1'),
  ('00000000-0000-0000-0000-000000000c03', '00000000-0000-0000-0000-00000000000a', '00000000-0000-0000-0000-000000000c02', 'Bay 3'),
  ('00000000-0000-0000-0000-000000000c04', '00000000-0000-0000-0000-00000000000a', null, 'Nashik'),
  ('00000000-0000-0000-0000-000000000c05', '00000000-0000-0000-0000-00000000000a', '00000000-0000-0000-0000-000000000c04', 'Plant 2');
insert into public.location (id, tenant_id, name) values
  ('00000000-0000-0000-0000-000000000cb1', '00000000-0000-0000-0000-00000000000b', 'b-site');

create temp view closure_names as
  select a.name as ancestor, d.name as descendant, c.depth::int as depth
  from private.location_closure c
  join public.location a on a.id = c.ancestor_id
  join public.location d on d.id = c.descendant_id
  where c.tenant_id = '00000000-0000-0000-0000-00000000000a';

select set_eq('select * from closure_names', $$values
  ('Pune', 'Pune', 0), ('Pune', 'Plant 1', 1), ('Pune', 'Bay 3', 2),
  ('Plant 1', 'Plant 1', 0), ('Plant 1', 'Bay 3', 1), ('Bay 3', 'Bay 3', 0),
  ('Nashik', 'Nashik', 0), ('Nashik', 'Plant 2', 1), ('Plant 2', 'Plant 2', 0)$$,
  'closure is correct after insert');

-- Move Plant 1 (with Bay 3) under Plant 2: the subtree moves with it.
update public.location set parent_id = '00000000-0000-0000-0000-000000000c05' where id = '00000000-0000-0000-0000-000000000c02';
select set_eq('select * from closure_names', $$values
  ('Pune', 'Pune', 0),
  ('Plant 1', 'Plant 1', 0), ('Plant 1', 'Bay 3', 1), ('Bay 3', 'Bay 3', 0),
  ('Nashik', 'Nashik', 0), ('Nashik', 'Plant 2', 1), ('Nashik', 'Plant 1', 2), ('Nashik', 'Bay 3', 3),
  ('Plant 2', 'Plant 2', 0), ('Plant 2', 'Plant 1', 1), ('Plant 2', 'Bay 3', 2)$$,
  'closure is correct after a subtree move');

-- Cycles are refused.
select throws_ok(
  $$update public.location set parent_id = id where id = '00000000-0000-0000-0000-000000000c05'$$,
  '23514', null, 'cannot move under itself');
select throws_ok(
  $$update public.location set parent_id = '00000000-0000-0000-0000-000000000c03' where id = '00000000-0000-0000-0000-000000000c04'$$,
  '23514', null, 'cannot move under own descendant');
select throws_ok(
  $$update public.location set parent_id = '00000000-0000-0000-0000-000000000c02' where id = '00000000-0000-0000-0000-000000000c05'$$,
  '23514', null, 'cannot move under own child');

-- Move to root.
update public.location set parent_id = null where id = '00000000-0000-0000-0000-000000000c02';
select set_eq('select * from closure_names', $$values
  ('Pune', 'Pune', 0),
  ('Plant 1', 'Plant 1', 0), ('Plant 1', 'Bay 3', 1), ('Bay 3', 'Bay 3', 0),
  ('Nashik', 'Nashik', 0), ('Nashik', 'Plant 2', 1), ('Plant 2', 'Plant 2', 0)$$,
  'closure is correct after a move to root');

-- Two crossing moves in one statement: the second row sees the first row's closure.
select throws_ok(
  $$update public.location set parent_id = case id when '00000000-0000-0000-0000-000000000c01' then '00000000-0000-0000-0000-000000000c02'::uuid
                                                     else '00000000-0000-0000-0000-000000000c01'::uuid end
    where id in ('00000000-0000-0000-0000-000000000c01', '00000000-0000-0000-0000-000000000c02')$$,
  '23514', null, 'crossing moves in one statement are refused');

-- Same-tenant parent only.
select throws_ok(
  $$insert into public.location (tenant_id, parent_id, name) values
    ('00000000-0000-0000-0000-00000000000a', '00000000-0000-0000-0000-000000000cb1', 'x')$$,
  '23503', null, 'parent in another tenant is refused (composite FK)');
select ok(not exists (select 1 from private.location_closure c join public.location l on l.id in (c.ancestor_id, c.descendant_id)
                      where l.tenant_id <> c.tenant_id), 'closure rows never cross tenants');

-- Names are unique among siblings, roots included.
select throws_ok(
  $$insert into public.location (tenant_id, name) values ('00000000-0000-0000-0000-00000000000a', 'Pune')$$,
  '23505', null, 'duplicate root name refused');
select lives_ok(
  $$insert into public.location (id, tenant_id, parent_id, name) values
    ('00000000-0000-0000-0000-000000000c06', '00000000-0000-0000-0000-00000000000a', '00000000-0000-0000-0000-000000000c01', 'Plant 2')$$,
  'same name under another parent is allowed');

-- Deactivate rules (L2).
select throws_ok(
  $$update public.location set active = false where id = '00000000-0000-0000-0000-000000000c04'$$,
  '23514', null, 'cannot deactivate with an active child');
select lives_ok($$update public.location set active = false where id = '00000000-0000-0000-0000-000000000c05'$$, 'deactivate a leaf');
select throws_ok(
  $$insert into public.location (tenant_id, parent_id, name) values
    ('00000000-0000-0000-0000-00000000000a', '00000000-0000-0000-0000-000000000c05', 'x')$$,
  '23514', null, 'no active child under an inactive parent');
select throws_ok(
  $$update public.location set parent_id = '00000000-0000-0000-0000-000000000c05' where id = '00000000-0000-0000-0000-000000000c03'$$,
  '23514', null, 'cannot move an active location under an inactive parent');
select throws_ok(
  $$update public.location set deleted_at = now() where id = '00000000-0000-0000-0000-000000000c04'$$,
  '23514', null, 'cannot soft delete a location with children');
select set_eq($$select descendant from closure_names where ancestor = 'Nashik'$$, $$values ('Nashik'), ('Plant 2')$$,
  'deactivated locations stay in the closure');

-- The scope query uses the closure primary key.
-- A tiny test table would seq scan, so seq scans are switched off to show the index can serve it.
create function pg_temp.plan_of(q text) returns text language plpgsql as $$
declare r text; o text := '';
begin
  for r in execute 'explain ' || q loop o := o || r || ' '; end loop;
  return o;
end;
$$;
set local enable_seqscan = off;
select matches(
  pg_temp.plan_of($$select descendant_id from private.location_closure
    where tenant_id = '00000000-0000-0000-0000-00000000000a' and ancestor_id = '00000000-0000-0000-0000-000000000c04'$$),
  'location_closure_pkey', 'descendants query uses the closure index');
reset enable_seqscan;

-- Permission steps, as a1 in tenant A. Default deny.
select tests.act_as('00000000-0000-0000-0000-0000000000a1', '00000000-0000-0000-0000-00000000000a');
select is((select count(*)::int from public.location), 0, 'no grant, no rows');
select throws_ok(
  $$insert into public.location (tenant_id, name) values ('00000000-0000-0000-0000-00000000000a', 'x')$$,
  '42501', null, 'no grant, no insert');

-- view only.
reset role;
select tests.grant('00000000-0000-0000-0000-00000000000a', '00000000-0000-0000-0000-0000000000a1', 'location_hierarchy', '{view}');
select tests.act_as('00000000-0000-0000-0000-0000000000a1', '00000000-0000-0000-0000-00000000000a');
select is((select count(*)::int from public.location), 6, 'view reads own tenant rows');
select throws_ok(
  $$insert into public.location (tenant_id, name) values ('00000000-0000-0000-0000-00000000000a', 'x')$$,
  '42501', null, 'view cannot insert');
select is_empty($$update public.location set name = 'x' returning 1$$, 'view cannot update');
select throws_ok('select count(*) from private.location_closure', '42501', null, 'user cannot read the closure');

-- manage: insert, edit, move, soft delete.
reset role;
select tests.grant('00000000-0000-0000-0000-00000000000a', '00000000-0000-0000-0000-0000000000a1', 'location_hierarchy', '{manage}');
select tests.act_as('00000000-0000-0000-0000-0000000000a1', '00000000-0000-0000-0000-00000000000a');
select lives_ok(
  $$insert into public.location (id, tenant_id, parent_id, name, code, location_type) values
    ('00000000-0000-0000-0000-000000000c07', '00000000-0000-0000-0000-00000000000a', '00000000-0000-0000-0000-000000000c01', 'Warehouse', 'PNQ-WH', 'Warehouse')$$,
  'manage inserts a location');
select lives_ok($$update public.location set name = 'Pune city' where id = '00000000-0000-0000-0000-000000000c01'$$, 'manage edits a location');
select lives_ok(
  $$update public.location set parent_id = '00000000-0000-0000-0000-000000000c07' where id = '00000000-0000-0000-0000-000000000c02'$$,
  'manage moves a location');
select lives_ok($$update public.location set deleted_at = now() where id = '00000000-0000-0000-0000-000000000c06'$$, 'manage soft deletes a leaf');
select throws_ok($$delete from public.location where id = '00000000-0000-0000-0000-000000000c06'$$, '42501', null, 'no hard delete');
reset role;
select set_eq($$select descendant from closure_names where ancestor = 'Pune city'$$,
  $$values ('Pune city'), ('Warehouse'), ('Plant 2'), ('Plant 1'), ('Bay 3')$$,
  'user move updated the closure (security definer trigger)');
select is((select count(*)::int from public.audit_log where table_name = 'location' and record_id = '00000000-0000-0000-0000-000000000c02'
           and action = 'update' and actor_user_id = '00000000-0000-0000-0000-0000000000a1' and new_data ? 'parent_id'), 1, 'move is audited');

-- Tenant B is read_only: reads work, writes do not, even with every grant.
select tests.grant('00000000-0000-0000-0000-00000000000b', '00000000-0000-0000-0000-0000000000a1', 'location_hierarchy');
select tests.act_as('00000000-0000-0000-0000-0000000000a1', '00000000-0000-0000-0000-00000000000b');
select results_eq('select name from public.location', $$values ('b-site')$$, 'read_only tenant reads');
select throws_ok(
  $$insert into public.location (tenant_id, name) values ('00000000-0000-0000-0000-00000000000b', 'x')$$,
  '42501', null, 'read_only tenant cannot insert');
select is_empty($$update public.location set name = 'x' returning 1$$, 'read_only tenant cannot update');

-- Cross-tenant harness: 8 tests.
reset role;
select * from tests.cross_tenant('public.location', 'location_hierarchy', '{"name":"ct-row"}');

select * from finish();
rollback;
