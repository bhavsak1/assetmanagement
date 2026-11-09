-- Story 10.8: saved insight widgets (docs/data-model-goal10.md §5.5.1).
-- Seed: tenant A active, B read_only; a1 in A and B; a2 in B only (used here as another owner's row in A).
begin;
select plan(34);

select policies_are('public', 'insight_widget',
  array['insight_widget_select', 'insight_widget_insert', 'insight_widget_update']);
select ok(not has_table_privilege('authenticated', 'public.insight_widget', 'delete'), 'widget: no delete grant');
select ok(not exists (select 1 from information_schema.columns where table_schema = 'public'
  and table_name = 'insight_widget' and column_name in ('sql', 'rows', 'result')), 'widget: no SQL or rows column');

-- Another user's widgets in tenant A: one private, one shared.
insert into public.insight_widget (id, tenant_id, name, query, shared, created_by) values
  ('00000000-0000-0000-0000-0000000108a2', '00000000-0000-0000-0000-00000000000a', 'Theirs', '{"subject":"asset"}', false, '00000000-0000-0000-0000-0000000000a2'),
  ('00000000-0000-0000-0000-0000000108a3', '00000000-0000-0000-0000-00000000000a', 'Shared', '{"subject":"asset"}', true,  '00000000-0000-0000-0000-0000000000a2');

-- Default deny.
select tests.act_as('00000000-0000-0000-0000-0000000000a1', '00000000-0000-0000-0000-00000000000a');
select is((select count(*)::int from public.insight_widget), 0, 'no grant: sees no widgets');
select throws_ok($$insert into public.insight_widget (tenant_id, name, query)
  values ('00000000-0000-0000-0000-00000000000a', 'Mine', '{"subject":"asset"}')$$, '42501', null, 'no grant: cannot save');

-- insights_query.ask only: sees shared widgets, cannot save.
reset role;
select tests.grant('00000000-0000-0000-0000-00000000000a', '00000000-0000-0000-0000-0000000000a1', 'insights_query', '{ask}');
select tests.act_as('00000000-0000-0000-0000-0000000000a1', '00000000-0000-0000-0000-00000000000a');
select is((select array_agg(name) from public.insight_widget where id::text like '%108a_'), '{Shared}', 'ask: sees shared widgets only');
select throws_ok($$insert into public.insight_widget (tenant_id, name, query)
  values ('00000000-0000-0000-0000-00000000000a', 'Mine', '{"subject":"asset"}')$$, '42501', null, 'ask: cannot save');
update public.insight_widget set name = 'Hijack' where id = '00000000-0000-0000-0000-0000000108a3';
select is((select name from public.insight_widget where id = '00000000-0000-0000-0000-0000000108a3'), 'Shared', 'ask: cannot edit a shared widget');

-- save: own widgets, private only.
reset role;
select tests.grant('00000000-0000-0000-0000-00000000000a', '00000000-0000-0000-0000-0000000000a1', 'insights_widget', '{save}');
select tests.act_as('00000000-0000-0000-0000-0000000000a1', '00000000-0000-0000-0000-00000000000a');
select lives_ok($$insert into public.insight_widget (id, tenant_id, name, query)
  values ('00000000-0000-0000-0000-0000000108a1', '00000000-0000-0000-0000-00000000000a', 'Mine', '{"subject":"asset"}')$$, 'save: saves own widget');
select is((select created_by from public.insight_widget where id = '00000000-0000-0000-0000-0000000108a1'),
  '00000000-0000-0000-0000-0000000000a1'::uuid, 'save: owner is the caller');
select is((select count(*)::int from public.insight_widget where name = 'Theirs'), 0, 'save: cannot see another user''s private widget');
select throws_ok($$insert into public.insight_widget (tenant_id, name, query, created_by)
  values ('00000000-0000-0000-0000-00000000000a', 'Forged', '{"subject":"asset"}', '00000000-0000-0000-0000-0000000000a2')$$,
  '42501', null, 'save: cannot save as another user');
select throws_ok($$insert into public.insight_widget (tenant_id, name, query, shared)
  values ('00000000-0000-0000-0000-00000000000a', 'Wide', '{"subject":"asset"}', true)$$, '42501', null, 'save: cannot save shared');
select throws_ok($$update public.insight_widget set shared = true where id = '00000000-0000-0000-0000-0000000108a1'$$,
  '42501', null, 'save: cannot share own widget');
select throws_ok($$insert into public.insight_widget (tenant_id, name, query)
  values ('00000000-0000-0000-0000-00000000000a', ' mine ', '{"subject":"asset"}')$$, '23505', null, 'save: name unique per owner');
select throws_ok($$insert into public.insight_widget (tenant_id, name, query)
  values ('00000000-0000-0000-0000-00000000000a', 'Arr', '[]')$$, '23514', null, 'save: query must be an object');
select throws_ok($$update public.insight_widget set created_by = '00000000-0000-0000-0000-0000000000a2'
  where id = '00000000-0000-0000-0000-0000000108a1'$$, '42501', null, 'save: cannot hand a widget to another user');
select lives_ok($$update public.insight_widget set name = 'Mine 2' where id = '00000000-0000-0000-0000-0000000108a1'$$, 'save: renames own widget');
update public.insight_widget set deleted_at = now() where id = '00000000-0000-0000-0000-0000000108a3';
reset role;
select is((select deleted_at from public.insight_widget where id = '00000000-0000-0000-0000-0000000108a3'), null, 'save: cannot remove another user''s shared widget');

-- W7: 25 live widgets per owner.
select tests.act_as('00000000-0000-0000-0000-0000000000a1', '00000000-0000-0000-0000-00000000000a');
insert into public.insight_widget (tenant_id, name, query)
select '00000000-0000-0000-0000-00000000000a', 'W' || n, '{"subject":"asset"}' from generate_series(2, 25) n;
select throws_ok($$insert into public.insight_widget (tenant_id, name, query)
  values ('00000000-0000-0000-0000-00000000000a', 'W26', '{"subject":"asset"}')$$, '54000', 'widget limit reached', 'limit: 26th widget refused');
update public.insight_widget set deleted_at = now() where name = 'W25';
select lives_ok($$insert into public.insight_widget (tenant_id, name, query)
  values ('00000000-0000-0000-0000-00000000000a', 'W26', '{"subject":"asset"}')$$, 'limit: a removed widget frees a slot');
select throws_ok($$update public.insight_widget set deleted_at = null where name = 'W25'$$, '54000', 'widget limit reached', 'limit: restore over the cap refused');

-- share: shares own widget; removal still works after losing share.
reset role;
select tests.grant('00000000-0000-0000-0000-00000000000a', '00000000-0000-0000-0000-0000000000a1', 'insights_widget', '{share}');
select tests.act_as('00000000-0000-0000-0000-0000000000a1', '00000000-0000-0000-0000-00000000000a');
select lives_ok($$update public.insight_widget set shared = true where id = '00000000-0000-0000-0000-0000000108a1'$$, 'share: shares own widget');
reset role;
delete from public.group_domain_policy p using public.domain_operation o
where o.id = p.domain_operation_id and o.code = 'share' and p.tenant_id = '00000000-0000-0000-0000-00000000000a'
  and p.security_group_id in (select security_group_id from public.user_group_assignment where user_id = '00000000-0000-0000-0000-0000000000a1');
select tests.act_as('00000000-0000-0000-0000-0000000000a1', '00000000-0000-0000-0000-00000000000a');
select throws_ok($$update public.insight_widget set name = 'Renamed' where id = '00000000-0000-0000-0000-0000000108a1'$$,
  '42501', null, 'lost share: cannot edit a shared widget');
select lives_ok($$update public.insight_widget set deleted_at = now() where id = '00000000-0000-0000-0000-0000000108a1'$$,
  'lost share: can still remove it');

-- read_only tenant B: a1 saves nothing.
reset role;
select tests.grant('00000000-0000-0000-0000-00000000000b', '00000000-0000-0000-0000-0000000000a1', 'insights_widget');
select tests.act_as('00000000-0000-0000-0000-0000000000a1', '00000000-0000-0000-0000-00000000000b');
select throws_ok($$insert into public.insight_widget (tenant_id, name, query)
  values ('00000000-0000-0000-0000-00000000000b', 'B', '{"subject":"asset"}')$$, '42501', null, 'read_only tenant: cannot save');

reset role;
select * from tests.cross_tenant('public.insight_widget', 'insights_widget',
  '{"name":"ct-row","query":{"subject":"asset"},"created_by":"00000000-0000-0000-0000-0000000000a1"}');

select * from finish();
rollback;
