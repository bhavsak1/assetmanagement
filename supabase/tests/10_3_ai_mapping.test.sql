-- Story 10.3: import_save_mapping keeps confidence on AI entries (docs/data-model-goal10.md §4.1).
-- Seed: tenant A active; a1 in A.
begin;
select plan(7);

insert into public.import_batch (id, tenant_id, file_name, file_size, file_sha256, sheet_name, sheet_names, header_row, columns, row_count)
values ('00000000-0000-0000-0000-0000000103a1', '00000000-0000-0000-0000-00000000000a', 'messy.xlsx', 100, repeat('a', 64),
        'Sheet1', '{Sheet1}', 1, '{Equip,Grp,Plnt}', 1);
select tests.grant('00000000-0000-0000-0000-00000000000a', '00000000-0000-0000-0000-0000000000a1', 'excel_import', '{run}');
select tests.act_as('00000000-0000-0000-0000-0000000000a1', '00000000-0000-0000-0000-00000000000a');

select throws_ok($$select public.import_save_mapping('00000000-0000-0000-0000-0000000103a1',
  '[{"target":"name","source":"rules","confidence":0.9},{"target":"category","source":"ai","confidence":0.8},{"target":"ignore","source":"rules"}]')$$,
  '22023', 'mapping: confidence is a number from 0 to 1, on AI entries only', 'confidence only on AI entries');
select throws_ok($$select public.import_save_mapping('00000000-0000-0000-0000-0000000103a1',
  '[{"target":"name","source":"ai","confidence":1.5},{"target":"category","source":"ai","confidence":0.8},{"target":"ignore","source":"rules"}]')$$,
  '22023', 'mapping: confidence is a number from 0 to 1, on AI entries only', 'confidence above 1 refused');
select throws_ok($$select public.import_save_mapping('00000000-0000-0000-0000-0000000103a1',
  '[{"target":"name","source":"ai","confidence":"high"},{"target":"category","source":"ai","confidence":0.8},{"target":"ignore","source":"rules"}]')$$,
  '22023', 'mapping: confidence is a number from 0 to 1, on AI entries only', 'confidence must be a number');
select throws_ok($$select public.import_save_mapping('00000000-0000-0000-0000-0000000103a1',
  '[{"target":"name","source":"ai","confidence":0.9},{"target":"category","source":"ai","confidence":0.8},{"target":"asset.secret","source":"ai","confidence":0.99}]')$$,
  '22023', 'mapping: unknown or not allowed target', 'an AI target still has to be in the catalog');
select lives_ok($$select public.import_save_mapping('00000000-0000-0000-0000-0000000103a1',
  '[{"target":"name","source":"ai","confidence":0.92},{"target":"category","source":"user","confidence":null},{"target":"ignore","source":"rules"}]')$$,
  'AI entry with confidence saved');
select is((select mapping from public.import_batch where id = '00000000-0000-0000-0000-0000000103a1'),
  '[{"target":"name","source":"ai","confidence":0.92},{"target":"category","source":"user"},{"target":"ignore","source":"rules"}]'::jsonb,
  'confidence kept on the AI entry, none elsewhere');

-- The 1.5 row trigger audits the batch change with the AI mark in it (§6.4).
reset role;
select ok(exists (select 1 from public.audit_log where tenant_id = '00000000-0000-0000-0000-00000000000a'
  and record_id = '00000000-0000-0000-0000-0000000103a1' and (new_data -> 'mapping' -> 0 ->> 'source') = 'ai'), 'audited with the AI mark');

select * from finish();
rollback;
