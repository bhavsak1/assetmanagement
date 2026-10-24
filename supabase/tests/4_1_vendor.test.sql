-- Story 4.1: vendor, vendor_contact, vendor_view masking, field pattern, access path.
-- docs/data-model-goal4.md. Uses the seed (tenant A active, B read_only; a1 in A and B, no groups)
-- and supabase/test_harness.sql.
begin;
select plan(66);

-- Fixtures as postgres: no signed-in user, so the user rules do not apply.
insert into public.field_definition (tenant_id, entity, key, label, type, pattern, security_domain_id)
select '00000000-0000-0000-0000-00000000000a', 'vendor', f.key, f.key, f.type, f.pattern,
       (select id from public.security_domain where code = f.domain)
from (values
  ('gstin',  'text',   '^[0-9]{2}[A-Z0-9]{13}$', 'vendor_tax_ids'),
  ('pan',    'text',   null,                     'vendor_tax_ids'),
  ('rating', 'number', null,                     'vendor_core')
) as f (key, type, pattern, domain);

insert into public.vendor (id, tenant_id, name, roles, custom_values) values
  ('00000000-0000-0000-0000-0000000041a1', '00000000-0000-0000-0000-00000000000a', 'Siemens India', '{oem,om}',
   '{"gstin": "27AAACS1234A1Z5", "rating": 4}'),
  ('00000000-0000-0000-0000-0000000041b1', '00000000-0000-0000-0000-00000000000b', 'B vendor', '{supplier}', '{}');
insert into public.vendor_contact (id, tenant_id, vendor_id, name, phone, is_primary) values
  ('00000000-0000-0000-0000-0000000041f1', '00000000-0000-0000-0000-00000000000a', '00000000-0000-0000-0000-0000000041a1',
   'Service desk', '+91 20 0000 0000', true);

-- Shape.
select policies_are('public', 'vendor', array['vendor_select', 'vendor_insert', 'vendor_update']);
select policies_are('public', 'vendor_contact', array['vendor_contact_select', 'vendor_contact_insert', 'vendor_contact_update']);
select ok(not has_table_privilege('authenticated', 'public.vendor', 'delete'), 'no hard delete grant on vendor');
select ok(not has_table_privilege('authenticated', 'public.vendor_contact', 'delete'), 'no hard delete grant on vendor_contact');
select ok(not has_column_privilege('authenticated', 'public.vendor', 'custom_values', 'select'), 'custom_values not readable on the table');
select ok(not has_column_privilege('authenticated', 'public.vendor_contact', 'vendor_id', 'update'), 'a contact cannot move to another vendor');
select has_trigger('public', 'asset', 'validate_field_pattern', 'asset values get the pattern check too');
select throws_ok(
  $$insert into public.field_definition (tenant_id, entity, key, label, type, pattern, security_domain_id)
    values ('00000000-0000-0000-0000-00000000000a', 'vendor', 'bad', 'bad', 'text', '([', (select id from public.security_domain where code = 'vendor_core'))$$,
  '2201B', null, 'a broken pattern is refused on the field');
select throws_ok(
  $$insert into public.field_definition (tenant_id, entity, key, label, type, pattern, security_domain_id)
    values ('00000000-0000-0000-0000-00000000000a', 'vendor', 'num', 'num', 'number', '^1$', (select id from public.security_domain where code = 'vendor_core'))$$,
  '23514', null, 'a pattern only goes on a text field');

-- Default deny.
select tests.act_as('00000000-0000-0000-0000-0000000000a1', '00000000-0000-0000-0000-00000000000a');
select is((select count(*)::int from public.vendor_view), 0, 'no grant, no vendors');
select is((select count(*)::int from public.vendor_contact), 0, 'no grant, no contacts');
select throws_ok($$insert into public.vendor (tenant_id, name) values ('00000000-0000-0000-0000-00000000000a', 'x')$$,
  '42501', null, 'no grant, no insert');

-- vendor_core.view only.
reset role;
select tests.grant('00000000-0000-0000-0000-00000000000a', '00000000-0000-0000-0000-0000000000a1', 'vendor_core', '{view}');
select tests.act_as('00000000-0000-0000-0000-0000000000a1', '00000000-0000-0000-0000-00000000000a');
select results_eq('select name from public.vendor_view', $$values ('Siemens India')$$, 'view reads own tenant vendors');
select is((select custom_values from public.vendor_view), '{"rating": 4}'::jsonb, 'tax ID keys masked without vendor_tax_ids.view');
select throws_ok($$select custom_values from public.vendor$$, '42501', null, 'table refuses custom_values');
select is((select count(*)::int from public.vendor_contact), 1, 'vendor_core.view sees contacts (V4)');
select throws_ok($$insert into public.vendor (tenant_id, name) values ('00000000-0000-0000-0000-00000000000a', 'x')$$,
  '42501', null, 'view cannot insert a vendor');
select is_empty($$update public.vendor set name = 'x' returning 1$$, 'view cannot update a vendor');
select throws_ok(
  $$insert into public.vendor_contact (tenant_id, vendor_id, name) values
    ('00000000-0000-0000-0000-00000000000a', '00000000-0000-0000-0000-0000000041a1', 'x')$$,
  '42501', null, 'view cannot add a contact');

-- create and update, no tax IDs.
reset role;
select tests.grant('00000000-0000-0000-0000-00000000000a', '00000000-0000-0000-0000-0000000000a1', 'vendor_core', '{create,update}');
select tests.act_as('00000000-0000-0000-0000-0000000000a1', '00000000-0000-0000-0000-00000000000a');
select lives_ok(
  $$insert into public.vendor (id, tenant_id, name, code, roles) values
    ('00000000-0000-0000-0000-0000000041a2', '00000000-0000-0000-0000-00000000000a', ' Atlas Services ', ' atl ', '{om,oem,om}')$$,
  'create adds a vendor');
select results_eq(
  $$select name, code, roles from public.vendor_view where id = '00000000-0000-0000-0000-0000000041a2'$$,
  $$values ('Atlas Services', 'ATL', '{oem,om}'::text[])$$,
  'name trimmed, code upper-cased, roles sorted without duplicates');
select throws_ok($$insert into public.vendor (tenant_id, name) values ('00000000-0000-0000-0000-00000000000a', 'atlas services')$$,
  '23505', null, 'live names are unique ignoring case');
select throws_ok($$insert into public.vendor (tenant_id, name, roles) values ('00000000-0000-0000-0000-00000000000a', 'y', '{dealer}')$$,
  '23514', null, 'roles are the fixed system list');
select throws_ok($$insert into public.vendor (tenant_id, name, custom_values) values ('00000000-0000-0000-0000-00000000000a', 'y', '{"nope": 1}')$$,
  '22023', null, 'unknown custom key refused');
select throws_ok($$insert into public.vendor (tenant_id, name, custom_values) values ('00000000-0000-0000-0000-00000000000a', 'y', '{"rating": "x"}')$$,
  '22023', null, 'custom value type checked');
-- The form never saw gstin and sends only what it shows.
select lives_ok($$update public.vendor set custom_values = '{"rating": 5}' where id = '00000000-0000-0000-0000-0000000041a1'$$,
  'save without the hidden tax keys');
select lives_ok($$update public.vendor set is_active = false where id = '00000000-0000-0000-0000-0000000041a2'$$,
  'update deactivates a vendor');
select is((select count(*)::int from public.vendor_view where id = '00000000-0000-0000-0000-0000000041a2' and not is_active), 1,
  'a deactivated vendor stays listed');
select throws_ok($$update public.vendor set deleted_at = now() where id = '00000000-0000-0000-0000-0000000041a2'$$,
  '42501', null, 'update alone cannot soft delete a vendor');
select throws_ok($$delete from public.vendor where id = '00000000-0000-0000-0000-0000000041a2'$$, '42501', null, 'no hard delete');
reset role;
select is((select custom_values from public.vendor where id = '00000000-0000-0000-0000-0000000041a1'),
  '{"gstin": "27AAACS1234A1Z5", "rating": 5}'::jsonb, 'hidden tax key kept as stored');
select tests.act_as('00000000-0000-0000-0000-0000000000a1', '00000000-0000-0000-0000-00000000000a');

-- Contacts need vendor_core.update (V7), one primary per vendor.
select lives_ok(
  $$insert into public.vendor_contact (id, tenant_id, vendor_id, name, email, is_primary) values
    ('00000000-0000-0000-0000-0000000041f2', '00000000-0000-0000-0000-00000000000a', '00000000-0000-0000-0000-0000000041a1',
     'R. Kulkarni', 'r@example.com', true)$$,
  'update adds a contact');
select results_eq(
  $$select id from public.vendor_contact where is_primary and deleted_at is null$$,
  $$values ('00000000-0000-0000-0000-0000000041f2'::uuid)$$,
  'a new primary clears the old one');
select throws_ok(
  $$insert into public.vendor_contact (tenant_id, vendor_id, name, email) values
    ('00000000-0000-0000-0000-00000000000a', '00000000-0000-0000-0000-0000000041a1', 'x', 'not-an-email')$$,
  '23514', null, 'contact email checked');
select lives_ok($$update public.vendor_contact set deleted_at = now() where id = '00000000-0000-0000-0000-0000000041f1'$$,
  'update removes a contact (soft delete)');
select throws_ok($$delete from public.vendor_contact where id = '00000000-0000-0000-0000-0000000041f2'$$, '42501', null, 'no hard delete of a contact');

-- vendor_tax_ids.view: keys visible, still not writable.
reset role;
select tests.grant('00000000-0000-0000-0000-00000000000a', '00000000-0000-0000-0000-0000000000a1', 'vendor_tax_ids', '{view}');
select tests.act_as('00000000-0000-0000-0000-0000000000a1', '00000000-0000-0000-0000-00000000000a');
select is((select custom_values ->> 'gstin' from public.vendor_view where id = '00000000-0000-0000-0000-0000000041a1'),
  '27AAACS1234A1Z5', 'vendor_tax_ids.view shows the tax keys');
select throws_ok(
  $$update public.vendor set custom_values = '{"gstin": "29AAACS1234A1Z5", "rating": 5}' where id = '00000000-0000-0000-0000-0000000041a1'$$,
  '42501', null, 'tax view alone cannot change a tax key');

-- vendor_tax_ids.update: the configured pattern applies.
reset role;
select tests.grant('00000000-0000-0000-0000-00000000000a', '00000000-0000-0000-0000-0000000000a1', 'vendor_tax_ids', '{update}');
select tests.act_as('00000000-0000-0000-0000-0000000000a1', '00000000-0000-0000-0000-00000000000a');
select throws_ok(
  $$update public.vendor set custom_values = '{"gstin": "bad", "rating": 5}' where id = '00000000-0000-0000-0000-0000000041a1'$$,
  '22023', null, 'value must match the field pattern');
select lives_ok(
  $$update public.vendor set custom_values = '{"gstin": "29AAACS1234A1Z5", "pan": "anything", "rating": 5}' where id = '00000000-0000-0000-0000-0000000041a1'$$,
  'matching value saves; a field with no pattern takes any text');

-- Mandatory vendor field.
reset role;
update public.field_definition set is_required = true where key = 'rating' and entity = 'vendor';
select tests.act_as('00000000-0000-0000-0000-0000000000a1', '00000000-0000-0000-0000-00000000000a');
select throws_ok($$insert into public.vendor (tenant_id, name) values ('00000000-0000-0000-0000-00000000000a', 'z')$$,
  '23502', null, 'required vendor field checked on insert');
select lives_ok($$update public.vendor set is_active = true where id = '00000000-0000-0000-0000-0000000041a2'$$,
  'reactivating is not a save, so mandatory waits');
reset role;
update public.field_definition set is_required = false where key = 'rating' and entity = 'vendor';

-- delete.
select tests.grant('00000000-0000-0000-0000-00000000000a', '00000000-0000-0000-0000-0000000000a1', 'vendor_core', '{delete}');
select tests.act_as('00000000-0000-0000-0000-0000000000a1', '00000000-0000-0000-0000-00000000000a');
select lives_ok($$update public.vendor set deleted_at = now() where id = '00000000-0000-0000-0000-0000000041a2'$$,
  'delete soft-deletes a vendor');
select is((select count(*)::int from public.vendor_view where id = '00000000-0000-0000-0000-0000000041a2'), 0, 'view hides soft-deleted vendors');
select is((select count(*)::int from public.vendor where id = '00000000-0000-0000-0000-0000000041a2'), 1, 'table keeps soft-deleted rows readable');

-- Access path (spike 1.7 F2): the list walks vendor_name_idx with a limit.
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
reset role;
analyze public.vendor;
select tests.act_as('00000000-0000-0000-0000-0000000000a1', '00000000-0000-0000-0000-00000000000a');
set local enable_seqscan = off;
set local enable_sort = off;
set local enable_bitmapscan = off;
select matches(pg_temp.plan('select id, name from public.vendor_view order by name, id limit 50'),
  'Index (Only )?Scan using vendor_name_idx', 'list by name walks vendor_name_idx');
select doesnt_match(pg_temp.plan('select id, name from public.vendor_view order by name, id limit 50'),
  'Sort', 'list by name needs no sort');
reset enable_seqscan;
reset enable_sort;
reset enable_bitmapscan;

-- Read-only tenant B: reads work, writes do not, even with every grant.
reset role;
select tests.grant('00000000-0000-0000-0000-00000000000b', '00000000-0000-0000-0000-0000000000a1', 'vendor_core');
select tests.act_as('00000000-0000-0000-0000-0000000000a1', '00000000-0000-0000-0000-00000000000b');
select results_eq('select name from public.vendor_view', $$values ('B vendor')$$, 'read_only tenant reads');
select throws_ok($$insert into public.vendor (tenant_id, name) values ('00000000-0000-0000-0000-00000000000b', 'x')$$,
  '42501', null, 'read_only tenant cannot insert');
select is_empty($$update public.vendor set name = 'x' returning 1$$, 'read_only tenant cannot update');

-- Cross-tenant harness: 8 tests each.
reset role;
select * from tests.cross_tenant('public.vendor', 'vendor_core', '{"name":"ct-row"}');
select * from tests.cross_tenant('public.vendor_contact', 'vendor_core',
  '{"name":"ct-row","vendor_id":"00000000-0000-0000-0000-0000000041a1"}',
  '{"vendor_id":"00000000-0000-0000-0000-0000000041b1"}');

select * from finish();
rollback;
