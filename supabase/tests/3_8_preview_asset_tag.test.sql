-- Story 3.8: preview_asset_tag() gives the tag a real insert would get, and never moves the counter.
-- Uses the seed (tenant A active, B read_only; a1 in A and B, no groups) and supabase/test_harness.sql.
begin;
select plan(14);

-- Fixtures as postgres: CNC has no code and inherits MC; Bay 3 inherits PNE.
insert into public.asset_category (id, tenant_id, parent_id, name, code, is_active) values
  ('00000000-0000-0000-0000-0000000038c1', '00000000-0000-0000-0000-00000000000a', null, 'Machines', 'mc', true),
  ('00000000-0000-0000-0000-0000000038c2', '00000000-0000-0000-0000-00000000000a', '00000000-0000-0000-0000-0000000038c1', 'CNC', null, true),
  ('00000000-0000-0000-0000-0000000038c3', '00000000-0000-0000-0000-00000000000a', null, 'Plain', null, true),
  ('00000000-0000-0000-0000-0000000038cb', '00000000-0000-0000-0000-00000000000b', null, 'B cat', 'BC', true);
insert into public.location (id, tenant_id, parent_id, name, code) values
  ('00000000-0000-0000-0000-0000000038e1', '00000000-0000-0000-0000-00000000000a', null, 'Pune', 'PNE'),
  ('00000000-0000-0000-0000-0000000038e2', '00000000-0000-0000-0000-00000000000a', '00000000-0000-0000-0000-0000000038e1', 'Bay 3', null),
  ('00000000-0000-0000-0000-0000000038eb', '00000000-0000-0000-0000-00000000000b', null, 'B loc', 'BL');
-- A counter already in use, and a typed tag holding the next number.
insert into private.asset_tag_counter (tenant_id, prefix, last_value) values ('00000000-0000-0000-0000-00000000000a', 'MC-', 6);
insert into public.asset (tenant_id, name, category_id, tag) values
  ('00000000-0000-0000-0000-00000000000a', 'typed', '00000000-0000-0000-0000-0000000038c1', 'MC-0007');
update public.tenant set asset_tag_pattern = '{CAT}-{SEQ:4}' where id = '00000000-0000-0000-0000-00000000000a';

select ok(not has_function_privilege('anon', 'public.preview_asset_tag(text, uuid, uuid)', 'execute'), 'anon cannot call');

-- No grant.
select tests.act_as('00000000-0000-0000-0000-0000000000a1', '00000000-0000-0000-0000-00000000000a');
select throws_ok($$select public.preview_asset_tag('AST-{SEQ:5}')$$, '42501', null, 'needs tenant_settings.view');

-- view only: settings, and no category or location view yet.
reset role;
select tests.grant('00000000-0000-0000-0000-00000000000a', '00000000-0000-0000-0000-0000000000a1', 'tenant_settings', '{view}');
select tests.act_as('00000000-0000-0000-0000-0000000000a1', '00000000-0000-0000-0000-00000000000a');
select is(public.preview_asset_tag('ast-{SEQ:5}'), 'AST-00001', 'default style pattern, upper case, first number');
select throws_ok($$select public.preview_asset_tag('{SEQ:4}-X')$$, '23514', null, 'pattern must end with {SEQ:n}');
select throws_ok($$select public.preview_asset_tag('A{FOO}-{SEQ:4}')$$, '23514', null, 'unknown part refused');
select throws_ok($$select public.preview_asset_tag('{CAT}-{SEQ:4}', null, '00000000-0000-0000-0000-0000000038c2')$$,
  '42501', null, 'sample category needs category_config.view');

reset role;
select tests.grant('00000000-0000-0000-0000-00000000000a', '00000000-0000-0000-0000-0000000000a1', 'category_config', '{view}');
select tests.grant('00000000-0000-0000-0000-00000000000a', '00000000-0000-0000-0000-0000000000a1', 'location_hierarchy', '{view}');
select tests.act_as('00000000-0000-0000-0000-0000000000a1', '00000000-0000-0000-0000-00000000000a');
select throws_ok($$select public.preview_asset_tag('{CAT}-{SEQ:4}', null, '00000000-0000-0000-0000-0000000038cb')$$,
  '42501', null, 'category of another tenant refused');
select throws_ok($$select public.preview_asset_tag('{LOC}-{SEQ:4}', '00000000-0000-0000-0000-0000000038eb')$$,
  '42501', null, 'location of another tenant refused');
select throws_ok($$select public.preview_asset_tag('{CAT}-{SEQ:4}', null, '00000000-0000-0000-0000-0000000038c3')$$,
  '22023', null, 'category with no code on its line refused, as an insert is');
select throws_ok($$select public.preview_asset_tag('{LOC}-{SEQ:4}')$$, '22023', null, '{LOC} with no sample location refused');
select is(public.preview_asset_tag('{CAT}-{SEQ:4}', null, '00000000-0000-0000-0000-0000000038c2'), 'MC-0008',
  'inherited code, counter + 1, typed tag skipped');
select set_config('t.preview', public.preview_asset_tag('{LOC}-{CAT}-{DATE:yyyymm}-{SEQ:3}',
  '00000000-0000-0000-0000-0000000038e2', '00000000-0000-0000-0000-0000000038c2'), true);

-- The real insert, as postgres, with the tenant pattern.
reset role;
select is((select last_value from private.asset_tag_counter
           where tenant_id = '00000000-0000-0000-0000-00000000000a' and prefix = 'MC-'), 6::bigint, 'preview left the counter alone');
insert into public.asset (id, tenant_id, name, category_id) values
  ('00000000-0000-0000-0000-0000000038a1', '00000000-0000-0000-0000-00000000000a', 'x', '00000000-0000-0000-0000-0000000038c2');
select is((select tag from public.asset where id = '00000000-0000-0000-0000-0000000038a1'), 'MC-0008', 'insert gets the previewed tag');
update public.tenant set asset_tag_pattern = '{LOC}-{CAT}-{DATE:yyyymm}-{SEQ:3}' where id = '00000000-0000-0000-0000-00000000000a';
insert into public.asset (id, tenant_id, name, category_id, location_id) values
  ('00000000-0000-0000-0000-0000000038a2', '00000000-0000-0000-0000-00000000000a', 'y', '00000000-0000-0000-0000-0000000038c2',
   '00000000-0000-0000-0000-0000000038e2');
select is((select tag from public.asset where id = '00000000-0000-0000-0000-0000000038a2'), current_setting('t.preview'),
  'every part: preview equals the real insert');

select * from finish();
rollback;
