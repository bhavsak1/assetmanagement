-- Story 4.1b: category vendor tags, asset OEM and O&M links, the vendor filter, merge_vendor.
-- docs/data-model-goal4.md §10 to §16. Uses the seed (tenant A active, B read_only; a1 in A and B,
-- no groups) and supabase/test_harness.sql.
begin;
select plan(59);

-- Fixtures as postgres, before any act_as (reset role keeps the JWT claim, so later "postgres" writes
-- still run as a1). Kirloskar sorts before Siemens (allowed_vendor_ids orders by name).
insert into public.vendor (id, tenant_id, name, roles, is_active) values
  ('00000000-0000-0000-0000-0000041be001', '00000000-0000-0000-0000-00000000000a', 'Siemens',      '{oem,om}',       true),
  ('00000000-0000-0000-0000-0000041be002', '00000000-0000-0000-0000-00000000000a', 'Atlas',        '{om}',           true),
  ('00000000-0000-0000-0000-0000041be003', '00000000-0000-0000-0000-00000000000a', 'Old works',    '{oem}',          false),
  ('00000000-0000-0000-0000-0000041be004', '00000000-0000-0000-0000-00000000000a', 'Kirloskar',    '{oem}',          true),
  ('00000000-0000-0000-0000-0000041be005', '00000000-0000-0000-0000-00000000000a', 'Bosch',        '{oem}',          true),
  ('00000000-0000-0000-0000-0000041be006', '00000000-0000-0000-0000-00000000000a', 'Siemens Ind.', '{oem,supplier}', true),
  ('00000000-0000-0000-0000-0000041be00b', '00000000-0000-0000-0000-00000000000b', 'B vendor',     '{oem}',          true);
insert into public.vendor_contact (id, tenant_id, vendor_id, name, is_primary) values
  ('00000000-0000-0000-0000-0000041bf001', '00000000-0000-0000-0000-00000000000a', '00000000-0000-0000-0000-0000041be006', 'Dup desk', true),
  ('00000000-0000-0000-0000-0000041bf002', '00000000-0000-0000-0000-00000000000a', '00000000-0000-0000-0000-0000041be006', 'Dup engineer', false),
  ('00000000-0000-0000-0000-0000041bf003', '00000000-0000-0000-0000-00000000000a', '00000000-0000-0000-0000-0000041be001', 'Main desk', true);
-- c1 Electrical (OEM Siemens) > c2 Motors (OEM Kirloskar, O&M Atlas) > c3 Small motors. c4 Furniture
-- is a sibling tree with the duplicate and the original both tagged.
insert into public.asset_category (id, tenant_id, parent_id, name, oem_vendor_ids, om_vendor_ids) values
  ('00000000-0000-0000-0000-0000041bc001', '00000000-0000-0000-0000-00000000000a', null, 'Electrical',
   '{00000000-0000-0000-0000-0000041be001}', '{}'),
  ('00000000-0000-0000-0000-0000041bc004', '00000000-0000-0000-0000-00000000000a', null, 'Furniture',
   '{00000000-0000-0000-0000-0000041be006,00000000-0000-0000-0000-0000041be001}', '{}'),
  ('00000000-0000-0000-0000-0000041bc00b', '00000000-0000-0000-0000-00000000000b', null, 'B cat', '{}', '{}');
insert into public.asset_category (id, tenant_id, parent_id, name, oem_vendor_ids, om_vendor_ids) values
  ('00000000-0000-0000-0000-0000041bc002', '00000000-0000-0000-0000-00000000000a', '00000000-0000-0000-0000-0000041bc001', 'Motors',
   '{00000000-0000-0000-0000-0000041be004}', '{00000000-0000-0000-0000-0000041be002}');
insert into public.asset_category (id, tenant_id, parent_id, name) values
  ('00000000-0000-0000-0000-0000041bc003', '00000000-0000-0000-0000-00000000000a', '00000000-0000-0000-0000-0000041bc002', 'Small motors');
insert into public.field_definition (tenant_id, entity, key, label, type, security_domain_id)
values ('00000000-0000-0000-0000-00000000000a', 'asset', 'cost_rate', 'Cost rate', 'number',
        (select id from public.security_domain where code = 'asset_financials'));

insert into public.asset (id, tenant_id, name, category_id, custom_values, oem_vendor_id) values
  ('00000000-0000-0000-0000-0000041ba002', '00000000-0000-0000-0000-00000000000a', 'Motor 2', '00000000-0000-0000-0000-0000041bc003', '{"cost_rate": 12}', null),
  ('00000000-0000-0000-0000-0000041ba003', '00000000-0000-0000-0000-00000000000a', 'Desk', '00000000-0000-0000-0000-0000041bc004', '{}',
   '00000000-0000-0000-0000-0000041be006');

-- Tag check: runs for every writer.
select throws_ok($$update public.asset_category set oem_vendor_ids = '{00000000-0000-0000-0000-0000041be00b}' where id = '00000000-0000-0000-0000-0000041bc004'$$,
  '23514', null, 'tag: another tenant''s vendor refused');
select throws_ok($$update public.asset_category set oem_vendor_ids = '{00000000-0000-0000-0000-0000041be003}' where id = '00000000-0000-0000-0000-0000041bc004'$$,
  '23514', null, 'tag: inactive vendor refused');
select throws_ok($$update public.asset_category set oem_vendor_ids = '{00000000-0000-0000-0000-0000041be002}' where id = '00000000-0000-0000-0000-0000041bc004'$$,
  '23514', null, 'tag: vendor without the role refused');
select throws_ok($$update public.asset_category set om_vendor_ids = '{00000000-0000-0000-0000-0000041be002,00000000-0000-0000-0000-0000041be002}' where id = '00000000-0000-0000-0000-0000041bc004'$$,
  '23514', null, 'tag: duplicate refused');

-- Inheritance: union up the tree.
select is(private.allowed_vendor_ids('00000000-0000-0000-0000-00000000000a', '00000000-0000-0000-0000-0000041bc001', 'oem'),
  '{00000000-0000-0000-0000-0000041be001}'::uuid[], 'own tags');
select is(private.allowed_vendor_ids('00000000-0000-0000-0000-00000000000a', '00000000-0000-0000-0000-0000041bc002', 'oem'),
  '{00000000-0000-0000-0000-0000041be004,00000000-0000-0000-0000-0000041be001}'::uuid[], 'own plus parent');
select is(private.allowed_vendor_ids('00000000-0000-0000-0000-00000000000a', '00000000-0000-0000-0000-0000041bc003', 'oem'),
  '{00000000-0000-0000-0000-0000041be004,00000000-0000-0000-0000-0000041be001}'::uuid[], 'grandchild: parent plus grandparent');
select is(private.allowed_vendor_ids('00000000-0000-0000-0000-00000000000a', '00000000-0000-0000-0000-0000041bc003', 'om'),
  '{00000000-0000-0000-0000-0000041be002}'::uuid[], 'role kept apart');
select is(private.allowed_vendor_ids('00000000-0000-0000-0000-00000000000a', '00000000-0000-0000-0000-0000041bc004', 'om'),
  '{}'::uuid[], 'sibling tree: nothing inherited');

-- Tags, one block per permission step.
select tests.act_as('00000000-0000-0000-0000-0000000000a1', '00000000-0000-0000-0000-00000000000a');
select is((select count(*)::int from public.category_vendors('00000000-0000-0000-0000-0000041bc003', 'oem')), 0,
  'no grant: category_vendors empty');
reset role;
select tests.grant('00000000-0000-0000-0000-00000000000a', '00000000-0000-0000-0000-0000000000a1', 'category_config', '{view}');
select tests.act_as('00000000-0000-0000-0000-0000000000a1', '00000000-0000-0000-0000-00000000000a');
select results_eq($$select * from public.category_vendors('00000000-0000-0000-0000-0000041bc003', 'oem')$$,
  $$values ('00000000-0000-0000-0000-0000041be004'::uuid), ('00000000-0000-0000-0000-0000041be001'::uuid)$$,
  'category_config.view: category_vendors by name');
select is_empty($$update public.asset_category set oem_vendor_ids = '{}' where id = '00000000-0000-0000-0000-0000041bc001' returning 1$$,
  'category_config.view: cannot change tags');
reset role;
select tests.grant('00000000-0000-0000-0000-00000000000a', '00000000-0000-0000-0000-0000000000a1', 'category_config', '{manage}');
select tests.act_as('00000000-0000-0000-0000-0000000000a1', '00000000-0000-0000-0000-00000000000a');
select isnt_empty($$update public.asset_category set om_vendor_ids = '{00000000-0000-0000-0000-0000041be001}' where id = '00000000-0000-0000-0000-0000041bc001' returning 1$$,
  'category_config.manage: tags a vendor');
reset role;
select tests.grant('00000000-0000-0000-0000-00000000000b', '00000000-0000-0000-0000-0000000000a1', 'category_config');
select tests.act_as('00000000-0000-0000-0000-0000000000a1', '00000000-0000-0000-0000-00000000000b');
select is_empty($$update public.asset_category set oem_vendor_ids = '{00000000-0000-0000-0000-0000041be00b}' where id = '00000000-0000-0000-0000-0000041bc00b' returning 1$$,
  'read_only tenant cannot tag');
select tests.act_as('00000000-0000-0000-0000-0000000000a1', '00000000-0000-0000-0000-00000000000a');
select is((select count(*)::int from public.category_vendors('00000000-0000-0000-0000-0000041bc00b', 'oem')), 0,
  'category_vendors: another tenant''s category gives nothing');

-- Asset rules: data rules, for every writer. Another tenant's vendor is not found by the rule (the
-- composite FK backs it).
reset role;
select throws_ok($$insert into public.asset (tenant_id, name, category_id, oem_vendor_id) values ('00000000-0000-0000-0000-00000000000a', 'x', '00000000-0000-0000-0000-0000041bc003', '00000000-0000-0000-0000-0000041be002')$$,
  '23514', 'oem_vendor_id: vendor is inactive or not an oem vendor', 'insert: wrong role refused');
select throws_ok($$insert into public.asset (tenant_id, name, category_id, oem_vendor_id) values ('00000000-0000-0000-0000-00000000000a', 'x', '00000000-0000-0000-0000-0000041bc003', '00000000-0000-0000-0000-0000041be003')$$,
  '23514', null, 'insert: inactive vendor refused');
select throws_ok($$insert into public.asset (tenant_id, name, category_id, oem_vendor_id) values ('00000000-0000-0000-0000-00000000000a', 'x', '00000000-0000-0000-0000-0000041bc003', '00000000-0000-0000-0000-0000041be005')$$,
  '23514', 'oem_vendor_id: vendor is not tagged to this category', 'insert: untagged vendor refused');
select throws_ok($$insert into public.asset (tenant_id, name, category_id, oem_vendor_id) values ('00000000-0000-0000-0000-00000000000a', 'x', '00000000-0000-0000-0000-0000041bc003', '00000000-0000-0000-0000-0000041be00b')$$,
  '23514', null, 'insert: another tenant''s vendor refused');
select throws_ok($$insert into public.asset (tenant_id, name, category_id, om_vendor_id) values ('00000000-0000-0000-0000-00000000000a', 'x', '00000000-0000-0000-0000-0000041bc003', '00000000-0000-0000-0000-0000041be004')$$,
  '23514', null, 'insert: OEM-only vendor refused in the O&M column');
select lives_ok($$insert into public.asset (id, tenant_id, name, category_id, oem_vendor_id, om_vendor_id) values
  ('00000000-0000-0000-0000-0000041ba001', '00000000-0000-0000-0000-00000000000a', 'Motor 1', '00000000-0000-0000-0000-0000041bc003',
   '00000000-0000-0000-0000-0000041be004', '00000000-0000-0000-0000-0000041be002')$$, 'insert: tagged vendors with the role');

-- Plain updates by a user cannot bypass the rules.
select tests.grant('00000000-0000-0000-0000-00000000000a', '00000000-0000-0000-0000-0000000000a1', 'asset_core', '{view,update}');
select tests.act_as('00000000-0000-0000-0000-0000000000a1', '00000000-0000-0000-0000-00000000000a');
select throws_ok($$update public.asset set om_vendor_id = '00000000-0000-0000-0000-0000041be004' where id = '00000000-0000-0000-0000-0000041ba001'$$,
  '23514', null, 'update: wrong role refused');
select throws_ok($$update public.asset set oem_vendor_id = '00000000-0000-0000-0000-0000041be005' where id = '00000000-0000-0000-0000-0000041ba001'$$,
  '23514', null, 'update: untagged vendor refused');
select throws_ok($$update public.asset set oem_vendor_id = '00000000-0000-0000-0000-0000041be003' where id = '00000000-0000-0000-0000-0000041ba001'$$,
  '23514', null, 'update: inactive vendor refused');
select throws_ok($$update public.asset set oem_vendor_id = '00000000-0000-0000-0000-0000041be00b' where id = '00000000-0000-0000-0000-0000041ba001'$$,
  '23514', null, 'update: another tenant''s vendor refused');
-- Hidden values are kept on a vendor-only save (a1 cannot view asset_financials).
update public.asset set oem_vendor_id = '00000000-0000-0000-0000-0000041be001', custom_values = '{}'
where id = '00000000-0000-0000-0000-0000041ba002';
select is((select oem_vendor_id from public.asset_view where id = '00000000-0000-0000-0000-0000041ba002'),
  '00000000-0000-0000-0000-0000041be001'::uuid, 'update: inherited OEM tag accepted');
reset role;
select is((select custom_values from public.asset where id = '00000000-0000-0000-0000-0000041ba002'), '{"cost_rate": 12}'::jsonb,
  'hidden custom value kept on save');

-- Unchanged links stay valid (B4): untag, deactivate, then a category change.
update public.asset_category set oem_vendor_ids = '{}' where id = '00000000-0000-0000-0000-0000041bc002';
update public.vendor set is_active = false where id = '00000000-0000-0000-0000-0000041be002';
select tests.act_as('00000000-0000-0000-0000-0000000000a1', '00000000-0000-0000-0000-00000000000a');
select lives_ok($$update public.asset set name = 'Motor 1b', oem_vendor_id = '00000000-0000-0000-0000-0000041be004',
  om_vendor_id = '00000000-0000-0000-0000-0000041be002' where id = '00000000-0000-0000-0000-0000041ba001'$$,
  'save with an untagged and an inactive link kept');
select lives_ok($$update public.asset set category_id = '00000000-0000-0000-0000-0000041bc004' where id = '00000000-0000-0000-0000-0000041ba001'$$,
  'category change keeps the links');
select results_eq($$select oem_vendor_id, om_vendor_id from public.asset_view where id = '00000000-0000-0000-0000-0000041ba001'$$,
  $$values ('00000000-0000-0000-0000-0000041be004'::uuid, '00000000-0000-0000-0000-0000041be002'::uuid)$$, 'links unchanged');
select throws_ok($$update public.asset set om_vendor_id = null, oem_vendor_id = '00000000-0000-0000-0000-0000041be005' where id = '00000000-0000-0000-0000-0000041ba001'$$,
  '23514', null, 'a new value must still pass the rules');

-- Vendor filter on the list (B6 b).
select results_eq($$select name from public.list_assets(p_vendor_id => '00000000-0000-0000-0000-0000041be002')$$,
  array['Motor 1b'], 'vendor filter: O&M column');
select results_eq($$select name from public.list_assets(p_vendor_id => '00000000-0000-0000-0000-0000041be006')$$,
  array['Desk'], 'vendor filter: OEM column');
select is(public.count_assets(p_vendor_id => '00000000-0000-0000-0000-0000041be001'), 1, 'vendor filter: count');

-- Soft delete guard: checked at commit (forced here with set constraints).
reset role;
create function pg_temp.soft_delete(p_id uuid) returns void language plpgsql as $$
begin
  update public.vendor set deleted_at = now() where id = p_id;
  set constraints all immediate;
end;
$$;
select throws_ok($$select pg_temp.soft_delete('00000000-0000-0000-0000-0000041be004')$$,
  '23503', 'vendor is linked to assets: merge it instead', 'soft delete of a linked vendor refused');
set constraints all deferred;
select lives_ok($$select pg_temp.soft_delete('00000000-0000-0000-0000-0000041be005')$$, 'soft delete of an unlinked vendor');
set constraints all deferred;

-- Merge, one block per permission step. Desk (a003) misses a mandatory field after this.
update public.tenant set required_asset_fields = '{serial_number}' where id = '00000000-0000-0000-0000-00000000000a';
select tests.act_as('00000000-0000-0000-0000-0000000000a1', '00000000-0000-0000-0000-00000000000a');
select throws_ok($$select public.merge_vendor('00000000-0000-0000-0000-0000041be006', '00000000-0000-0000-0000-0000041be001')$$,
  '42501', null, 'merge: no grant refused');
reset role;
select tests.grant('00000000-0000-0000-0000-00000000000a', '00000000-0000-0000-0000-0000000000a1', 'vendor_core', '{view,create,update}');
select tests.act_as('00000000-0000-0000-0000-0000000000a1', '00000000-0000-0000-0000-00000000000a');
select throws_ok($$select public.merge_vendor('00000000-0000-0000-0000-0000041be006', '00000000-0000-0000-0000-0000041be001')$$,
  '42501', null, 'merge: vendor_core.update is not enough');
reset role;
select tests.grant('00000000-0000-0000-0000-00000000000a', '00000000-0000-0000-0000-0000000000a1', 'vendor_core', '{delete}');
select tests.grant('00000000-0000-0000-0000-00000000000b', '00000000-0000-0000-0000-0000000000a1', 'vendor_core');
select tests.act_as('00000000-0000-0000-0000-0000000000a1', '00000000-0000-0000-0000-00000000000b');
select throws_ok($$select public.merge_vendor('00000000-0000-0000-0000-0000041be00b', '00000000-0000-0000-0000-0000041be00b')$$,
  '42501', null, 'merge: read_only tenant refused');
select tests.act_as('00000000-0000-0000-0000-0000000000a1', '00000000-0000-0000-0000-00000000000a');
select throws_ok($$select public.merge_vendor('00000000-0000-0000-0000-0000041be006', '00000000-0000-0000-0000-0000041be00b')$$,
  'P0002', null, 'merge: another tenant''s vendor refused');
select throws_ok($$select public.merge_vendor('00000000-0000-0000-0000-0000041be006', '00000000-0000-0000-0000-0000041be006')$$,
  '22023', null, 'merge: into itself refused');
select throws_ok($$select public.merge_vendor('00000000-0000-0000-0000-0000041be006', '00000000-0000-0000-0000-0000041be003')$$,
  '22023', 'cannot merge into an inactive vendor', 'merge: into an inactive vendor refused');
select throws_ok($$select public.merge_vendor('00000000-0000-0000-0000-0000041be005', '00000000-0000-0000-0000-0000041be001')$$,
  'P0002', null, 'merge: a soft-deleted source refused');
select lives_ok($$select public.merge_vendor('00000000-0000-0000-0000-0000041be006', '00000000-0000-0000-0000-0000041be001')$$,
  'merge: Siemens Ind. into Siemens');

reset role;
select lives_ok($$set constraints all immediate$$, 'merge: soft-delete guard passes at commit');
select is((select roles from public.vendor where id = '00000000-0000-0000-0000-0000041be001'), '{oem,om,supplier}'::text[],
  'merge: roles are the union');
select isnt((select deleted_at from public.vendor where id = '00000000-0000-0000-0000-0000041be006'), null,
  'merge: source soft-deleted');
select is((select count(*)::int from public.vendor_contact where vendor_id = '00000000-0000-0000-0000-0000041be001'), 3,
  'merge: contacts moved');
select results_eq($$select id from public.vendor_contact where vendor_id = '00000000-0000-0000-0000-0000041be001' and is_primary$$,
  $$values ('00000000-0000-0000-0000-0000041bf003'::uuid)$$, 'merge: into keeps its own primary');
select is((select oem_vendor_ids from public.asset_category where id = '00000000-0000-0000-0000-0000041bc004'),
  '{00000000-0000-0000-0000-0000041be001}'::uuid[], 'merge: tags repointed without duplicates');
select is((select oem_vendor_id from public.asset where id = '00000000-0000-0000-0000-0000041ba003'),
  '00000000-0000-0000-0000-0000041be001'::uuid, 'merge: asset repointed (mandatory field missing does not block)');
select is((select count(*)::int from public.asset where '00000000-0000-0000-0000-0000041be006' in (oem_vendor_id, om_vendor_id)), 0,
  'merge: no asset left on the source');
select results_eq($$select actor_user_id, new_data from public.audit_log where action = 'merge' and record_id = '00000000-0000-0000-0000-0000041be006'$$,
  $$values ('00000000-0000-0000-0000-0000000000a1'::uuid,
            '{"into_id": "00000000-0000-0000-0000-0000041be001", "contacts": 2, "categories": 1, "assets": 1, "coverages": 0}'::jsonb)$$,
  'merge: one merge audit entry');
select is((select count(*)::int from private.outbox_event where event_type = 'vendor.merged'
           and aggregate_id = '00000000-0000-0000-0000-0000041be006'), 1, 'merge: outbox event');

-- A stale tag (the source dropped the role, B4) is removed, not repointed to a vendor without it.
-- Kirloskar now supplies only; its old OEM tag and a soft-deleted asset's link are set with triggers off.
update public.vendor set roles = '{supplier}' where id = '00000000-0000-0000-0000-0000041be004';
insert into public.vendor (id, tenant_id, name, roles) values
  ('00000000-0000-0000-0000-0000041be007', '00000000-0000-0000-0000-00000000000a', 'Supplier only', '{supplier}');
set local session_replication_role = replica;
insert into public.asset_category (id, tenant_id, name, oem_vendor_ids) values
  ('00000000-0000-0000-0000-0000041bc005', '00000000-0000-0000-0000-00000000000a', 'Pumps', '{00000000-0000-0000-0000-0000041be004}');
update public.asset set deleted_at = now() where id = '00000000-0000-0000-0000-0000041ba001';
set local session_replication_role = origin;
select tests.act_as('00000000-0000-0000-0000-0000000000a1', '00000000-0000-0000-0000-00000000000a');
select lives_ok($$select public.merge_vendor('00000000-0000-0000-0000-0000041be004', '00000000-0000-0000-0000-0000041be007')$$,
  'merge with a stale tag');
reset role;
select is((select oem_vendor_ids from public.asset_category where id = '00000000-0000-0000-0000-0000041bc005'), '{}'::uuid[],
  'stale tag removed');
select is((select oem_vendor_id from public.asset where id = '00000000-0000-0000-0000-0000041ba001'),
  '00000000-0000-0000-0000-0000041be007'::uuid, 'soft-deleted asset repointed too');

-- Access path: the vendor columns did not change the list plan (3.2). Bulk rows skip the triggers.
set local session_replication_role = replica;
insert into public.asset (tenant_id, tag, name, category_id, status_id)
select '00000000-0000-0000-0000-00000000000a', 'BLK-' || lpad(n::text, 6, '0'), 'Bulk ' || n, '00000000-0000-0000-0000-0000041bc004',
       (select id from public.asset_status where tenant_id = '00000000-0000-0000-0000-00000000000a' and code = 'active')
from generate_series(1, 30000) n;
set local session_replication_role = origin;
analyze public.asset;
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
select tests.act_as('00000000-0000-0000-0000-0000000000a1', '00000000-0000-0000-0000-00000000000a');
select matches(pg_temp.plan(private.asset_list_sql(null, null, null, null, 'name', 'Bulk 100', '00000000-0000-0000-0000-000000000000', 51)),
  'Index Scan using asset_name_idx[^\n]*\n[^\n]*Index Cond: [^\n]*ROW\(name, id\) >', 'name page still starts at the cursor in asset_name_idx');
select matches(pg_temp.plan(private.asset_list_sql(null, null, null, null, 'name', null, null, 51, null, '00000000-0000-0000-0000-0000041be001')),
  'asset_(oem|om)_vendor_idx|asset_name_idx', 'vendor filter uses an index');

select * from finish();
rollback;
