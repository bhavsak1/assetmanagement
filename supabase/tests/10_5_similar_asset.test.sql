-- Story 10.5: the similar_asset warning in import_validate (docs/data-model-goal10.md §4.3.1, F1-F5).
-- Seed: tenant A active, B read_only; a1 in A and B.
begin;
select plan(19);

update public.tenant set asset_tag_pattern = 'AST-{SEQ:5}' where id = '00000000-0000-0000-0000-00000000000a';
insert into public.asset_category (id, tenant_id, name, code) values
  ('00000000-0000-0000-0000-0000000105c1', '00000000-0000-0000-0000-00000000000a', 'Machines 105', 'C105'),
  ('00000000-0000-0000-0000-0000000105cb', '00000000-0000-0000-0000-00000000000b', 'Machines B 105', 'C105');
insert into public.location (id, tenant_id, parent_id, name) values
  ('00000000-0000-0000-0000-0000000105e1', '00000000-0000-0000-0000-00000000000a', null, 'Line 1 105'),
  ('00000000-0000-0000-0000-0000000105e2', '00000000-0000-0000-0000-00000000000a', null, 'Line 2 105');
insert into public.asset (id, tenant_id, tag, name, category_id, location_id, serial_number, deleted_at) values
  ('00000000-0000-0000-0000-0000000105a1', '00000000-0000-0000-0000-00000000000a', 'AC-105', 'Air Compressor Unit 7',
   '00000000-0000-0000-0000-0000000105c1', '00000000-0000-0000-0000-0000000105e1', 'SN-ABC-1234', null),
  ('00000000-0000-0000-0000-0000000105a2', '00000000-0000-0000-0000-00000000000a', 'DEL-105', 'Hydraulic Press 9',
   '00000000-0000-0000-0000-0000000105c1', '00000000-0000-0000-0000-0000000105e1', null, now()),
  ('00000000-0000-0000-0000-0000000105ab', '00000000-0000-0000-0000-00000000000b', 'B-105', 'Cooling Tower Fan 3',
   '00000000-0000-0000-0000-0000000105cb', null, 'CT-555-XYZ', null);
-- 200 live assets for the timing block (4).
insert into public.asset (tenant_id, tag, name, category_id, location_id)
select '00000000-0000-0000-0000-00000000000a', 'M105-' || n, 'Machine 105 no ' || n,
       '00000000-0000-0000-0000-0000000105c1', '00000000-0000-0000-0000-0000000105e1'
from generate_series(1, 200) n;
insert into public.scope_profile (id, tenant_id, name) values
  ('00000000-0000-0000-0000-0000000105f1', '00000000-0000-0000-0000-00000000000a', 'Line 2 only 105');
insert into public.scope_profile_rule (tenant_id, scope_profile_id, dimension, location_id) values
  ('00000000-0000-0000-0000-00000000000a', '00000000-0000-0000-0000-0000000105f1', 'location', '00000000-0000-0000-0000-0000000105e2');

create function pg_temp.batch(p_id text, p_rows int) returns void language sql as $$
  insert into public.import_batch (id, tenant_id, file_name, file_size, file_sha256, sheet_name, sheet_names, header_row,
                                   columns, row_count, status, mapping)
  values (p_id::uuid, '00000000-0000-0000-0000-00000000000a', 'assets.xlsx', 100, repeat('a', 64), 'Sheet1', '{Sheet1}', 1,
          '{Name,Category,Location,Serial}', p_rows, 'mapped',
          '[{"target":"name","source":"rules"},{"target":"category","source":"rules"},
            {"target":"location","source":"rules"},{"target":"serial_number","source":"rules"}]');
$$;
select pg_temp.batch('00000000-0000-0000-0000-0000000105b1', 6);
insert into public.import_row (tenant_id, batch_id, row_number, cells)
select '00000000-0000-0000-0000-00000000000a', '00000000-0000-0000-0000-0000000105b1', n, c::jsonb
from (values
  (2, '["Air Compresor Unit 7","C105","Line 1 105",null]'),            -- typo, same location: warn
  (3, '["Air Compressor Unit 7","C105","Line 2 105",null]'),           -- same name, other location, no serial
  (4, '["Air Compressor Unit-7","C105","Line 2 105","SN-ABC-1235"]'),  -- other location, similar serial: warn
  (5, '["Boiler Feed Pump","C105","Line 1 105",null]'),                -- different name
  (6, '["Hydraulic Press 9","C105","Line 1 105",null]'),               -- matches a deleted asset only
  (7, '["Cooling Tower Fan 3","C105",null,"CT-555-XYZ"]')              -- matches tenant B's asset only
) as x (n, c);

create function pg_temp.codes(p_n int) returns text[] language sql as $$
  select coalesce(array_agg(m ->> 'code' order by m ->> 'code'), '{}')
  from public.import_row r, jsonb_array_elements(coalesce(r.messages, '[]')) m
  where r.batch_id = '00000000-0000-0000-0000-0000000105b1' and r.row_number = p_n;
$$;
create function pg_temp.msg(p_n int) returns jsonb language sql as $$
  select m from public.import_row r, jsonb_array_elements(r.messages) m
  where r.batch_id = '00000000-0000-0000-0000-0000000105b1' and r.row_number = p_n and m ->> 'code' = 'similar_asset';
$$;
create function pg_temp.res(p_n int) returns text language sql as $$
  select result from public.import_row where batch_id = '00000000-0000-0000-0000-0000000105b1' and row_number = p_n;
$$;
create function pg_temp.clear() returns void language sql as $$
  update public.user_group_assignment set deleted_at = now()
  where tenant_id = '00000000-0000-0000-0000-00000000000a' and user_id = '00000000-0000-0000-0000-0000000000a1' and deleted_at is null;
$$;
-- As in 6.1: grant a1 in A through a new group, scoped to p_profile.
create function pg_temp.grant_scoped(p_domain text, p_ops text[], p_profile uuid) returns void language plpgsql as $$
declare
  v_before uuid[] := array(select id from public.user_group_assignment
                           where tenant_id = '00000000-0000-0000-0000-00000000000a' and user_id = '00000000-0000-0000-0000-0000000000a1');
begin
  perform tests.grant('00000000-0000-0000-0000-00000000000a', '00000000-0000-0000-0000-0000000000a1', p_domain, p_ops);
  update public.user_group_assignment set scope_profile_id = p_profile
  where tenant_id = '00000000-0000-0000-0000-00000000000a' and user_id = '00000000-0000-0000-0000-0000000000a1'
    and not (id = any (v_before));
end;
$$;
grant execute on all functions in schema pg_temp to authenticated;

-- 1. No asset_core.view: no warning, so nothing about assets the caller cannot see.
select tests.grant('00000000-0000-0000-0000-00000000000a', '00000000-0000-0000-0000-0000000000a1', 'excel_import', '{run}');
select tests.grant('00000000-0000-0000-0000-00000000000a', '00000000-0000-0000-0000-0000000000a1', 'asset_core', '{create}');
select tests.act_as('00000000-0000-0000-0000-0000000000a1', '00000000-0000-0000-0000-00000000000a');
select lives_ok($$select public.import_validate('00000000-0000-0000-0000-0000000105b1')$$, 'validate without view');
select is(pg_temp.codes(2), '{}', 'no view: no similar_asset');

-- 2. Tenant-wide view: the rule (F1) and what it reveals (F3).
reset role;
select tests.grant('00000000-0000-0000-0000-00000000000a', '00000000-0000-0000-0000-0000000000a1', 'asset_core', '{view}');
select tests.act_as('00000000-0000-0000-0000-0000000000a1', '00000000-0000-0000-0000-00000000000a');
select lives_ok($$select public.import_validate('00000000-0000-0000-0000-0000000105b1')$$, 'validate with view');
select is(pg_temp.codes(2), '{similar_asset}', 'row 2: similar name, same location');
select is(pg_temp.msg(2), '{"col":0,"code":"similar_asset","params":{"tag":"AC-105"}}', 'row 2: the name column and the tag');
select is(pg_temp.res(2), 'warning', 'row 2: a warning, the row still commits');
select is(pg_temp.codes(3), '{}', 'row 3: same name at another location, no serial');
select is(pg_temp.codes(4), '{similar_asset}', 'row 4: another location but a similar serial');
select is(pg_temp.codes(5), '{}', 'row 5: a different name');
select is(pg_temp.codes(6), '{}', 'row 6: a deleted asset is not a match');
select is(pg_temp.codes(7), '{}', 'row 7: tenant B''s asset is never a match');
select is((select (summary -> 'codes' ->> 'similar_asset')::int from public.import_batch
           where id = '00000000-0000-0000-0000-0000000105b1'), 2, 'summary counts 2 similar_asset');
select is((select (summary ->> 'error')::int from public.import_batch
           where id = '00000000-0000-0000-0000-0000000105b1'), 0, 'no row is an error');

-- 3. View scoped to Line 2: the Line 1 asset is out of view, so no warning names it.
reset role;
select pg_temp.clear();
select tests.grant('00000000-0000-0000-0000-00000000000a', '00000000-0000-0000-0000-0000000000a1', 'excel_import', '{run}');
select tests.grant('00000000-0000-0000-0000-00000000000a', '00000000-0000-0000-0000-0000000000a1', 'asset_core', '{create}');
select pg_temp.grant_scoped('asset_core', '{view}', '00000000-0000-0000-0000-0000000105f1');
select tests.act_as('00000000-0000-0000-0000-0000000000a1', '00000000-0000-0000-0000-00000000000a');
select is((select count(*)::int from public.asset_view where tag = 'AC-105'), 0, 'scoped: AC-105 is out of view');
select lives_ok($$select public.import_validate('00000000-0000-0000-0000-0000000105b1')$$, 'validate with scoped view');
select is(pg_temp.codes(2), '{}', 'scoped: no warning about an asset out of view');
select is(pg_temp.codes(4), '{}', 'scoped: none by serial either');

-- 4. 20,000 rows, 200 of them like a live asset, inside the 8 s web statement timeout (8.4 V1).
reset role;
select pg_temp.clear();
select tests.grant('00000000-0000-0000-0000-00000000000a', '00000000-0000-0000-0000-0000000000a1', 'excel_import', '{run}');
select tests.grant('00000000-0000-0000-0000-00000000000a', '00000000-0000-0000-0000-0000000000a1', 'asset_core', '{view,create}');
select pg_temp.batch('00000000-0000-0000-0000-0000000105b3', 20000);
insert into public.import_row (tenant_id, batch_id, row_number, cells)
select '00000000-0000-0000-0000-00000000000a', '00000000-0000-0000-0000-0000000105b3', n + 1,
       jsonb_build_array(case when n <= 200 then 'Machine 105 no ' || n || 'x' else 'Pump ' || n end, 'C105',
                         'Line 1 105', 'SN-' || n)
from generate_series(1, 20000) n;
create temp table t0 as select clock_timestamp() as t;
grant select on t0 to authenticated;
select tests.act_as('00000000-0000-0000-0000-0000000000a1', '00000000-0000-0000-0000-00000000000a');
select is((public.import_validate('00000000-0000-0000-0000-0000000105b3') -> 'codes' ->> 'similar_asset')::int, 200,
  '20,000 rows: the 200 near matches are found');
select cmp_ok(extract(epoch from clock_timestamp() - (select t from t0)), '<', 8::numeric,
  '20,000 rows with the similar_asset step inside the 8 s web statement timeout');

select * from finish();
rollback;
