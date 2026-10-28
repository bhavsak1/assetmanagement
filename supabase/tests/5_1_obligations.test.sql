-- Story 5.1: obligations, next-due math, stored state with its triggers and job, the due-soon setting and
-- category defaults. docs/data-model-goal5.md. Uses the seed (tenant A active in Asia/Kolkata, B read_only;
-- a1 in A and B, no groups; admin.a ...a0001, plant.a ...a0002, planner.a ...a0003, tech.a ...a0004) and
-- supabase/test_harness.sql.
begin;
select plan(110);

create function pg_temp.d(n int) returns date language sql as $$
  select (now() at time zone 'Asia/Kolkata')::date + n;
$$;
create function pg_temp.nd(p_anchor text, p_count int, p_unit text, p_first date, p_last date,
                           p_cur date default null, p_done date default null) returns date language sql as $$
  select private.obligation_next_due(p_anchor, p_count, p_unit, p_first, p_last, p_cur, p_done);
$$;
create function pg_temp.st(p_name text) returns text language sql as $$
  select due_state from public.obligation where tenant_id = '00000000-0000-0000-0000-00000000000a' and name = p_name and deleted_at is null;
$$;
create function pg_temp.events(p_name text, p_type text) returns bigint language sql as $$
  select count(*) from private.outbox_event e join public.obligation o on o.id = e.aggregate_id
  where o.name = p_name and e.event_type = p_type;
$$;

-- 1. Next-due math (Â§3).
select is(pg_temp.nd('completion', 3, 'month', '2026-03-31', null), '2026-03-31'::date, 'never done: first due');
select is(pg_temp.nd('completion', 3, 'month', '2026-03-31', null, '2026-03-31', '2026-04-15'), '2026-07-15'::date,
  'completion, done late: three months from the done date');
select is(pg_temp.nd('completion', 3, 'month', '2026-03-31', null, '2026-03-31', '2026-03-17'), '2026-06-17'::date,
  'completion, done early: three months from the done date');
select is(pg_temp.nd('completion', 1, 'month', '2026-01-31', '2026-01-31'), '2026-02-28'::date, 'completion: 31 Jan + 1 month = 28 Feb');
select is(pg_temp.nd('completion', 1, 'month', '2028-01-31', '2028-01-31'), '2028-02-29'::date, 'completion: leap year, 29 Feb');
select is(pg_temp.nd('completion', 10, 'day', '2026-01-01', '2026-01-01'), '2026-01-11'::date, 'completion: days');
select is(pg_temp.nd('fixed', 3, 'month', '2026-03-31', null, '2026-03-31', '2026-03-17'), '2026-06-30'::date,
  'fixed, done early: clears this period');
select is(pg_temp.nd('fixed', 3, 'month', '2026-03-31', null, '2026-03-31', '2026-04-15'), '2026-06-30'::date,
  'fixed, done late: stays on the calendar');
select is(pg_temp.nd('fixed', 3, 'month', '2026-03-31', null, '2026-03-31', '2026-09-10'), '2026-09-30'::date,
  'fixed, missed periods: one completion clears the backlog (O5)');
select is(pg_temp.nd('fixed', 1, 'month', '2026-01-31', null, '2026-02-28', '2026-02-28'), '2026-03-31'::date,
  'fixed: month end does not drift (31 Mar, not 28 Mar)');
select is(pg_temp.nd('fixed', 1, 'month', '2026-01-31', '2026-03-05'), '2026-03-31'::date, 'fixed rule edit: first slot after last done');
select is(pg_temp.nd('fixed', 1, 'year', '2028-02-29', null, '2029-02-28', '2029-03-01'), '2030-02-28'::date,
  'fixed yearly from 29 Feb: 28 Feb in a common year');
select is(pg_temp.nd('fixed', 1, 'year', '2028-02-29', null, '2029-02-28', '2031-03-01'), '2032-02-29'::date,
  'fixed yearly from 29 Feb: back to 29 Feb in a leap year');
select is(pg_temp.nd('fixed', 2, 'week', '2026-01-01', '2026-01-20'), '2026-01-29'::date, 'fixed: weeks');
select is(pg_temp.nd('fixed', 1, 'year', '2000-06-30', '2026-07-01'), '2027-06-30'::date, 'fixed: many periods later');
select is(pg_temp.nd('fixed', 3, 'month', '2026-03-31', '2026-01-10'), '2026-03-31'::date, 'fixed: last done before first due');
select is(pg_temp.nd('fixed', 3, 'month', '2026-03-31', '2026-03-31'), '2026-06-30'::date, 'fixed: done on the due day');

-- Fixtures, as postgres. The seed's tenant A assets keep no obligations.
insert into public.asset_category (id, tenant_id, name) values
  ('00000000-0000-0000-0000-00000051c001', '00000000-0000-0000-0000-00000000000a', 'Machines'),
  ('00000000-0000-0000-0000-00000051c00b', '00000000-0000-0000-0000-00000000000b', 'B cat');
insert into public.asset (id, tenant_id, name, category_id) values
  ('00000000-0000-0000-0000-00000051a001', '00000000-0000-0000-0000-00000000000a', 'Lathe', '00000000-0000-0000-0000-00000051c001'),
  ('00000000-0000-0000-0000-00000051a002', '00000000-0000-0000-0000-00000000000a', 'Boiler', '00000000-0000-0000-0000-00000051c001'),
  ('00000000-0000-0000-0000-00000051a003', '00000000-0000-0000-0000-00000000000a', 'Old', '00000000-0000-0000-0000-00000051c001'),
  ('00000000-0000-0000-0000-00000051a0bb', '00000000-0000-0000-0000-00000000000b', 'B asset', '00000000-0000-0000-0000-00000051c00b');
update public.asset set deleted_at = now() where id = '00000000-0000-0000-0000-00000051a003';

-- 2. Writes, as tenant admin.
select tests.act_as('00000000-0000-0000-0000-0000000a0001', '00000000-0000-0000-0000-00000000000a');
select lives_ok($$insert into public.obligation (tenant_id, asset_id, name, obligation_type, interval_count, interval_unit, anchor, first_due_date, last_done_date)
  values ('00000000-0000-0000-0000-00000000000a', '00000000-0000-0000-0000-00000051a001', ' Quarterly service ', 'service', 3, 'month', 'completion', '2026-01-31', '2026-01-31')$$,
  'tenant admin adds an obligation with a last done date');
select is((select next_due_date from public.obligation where name = 'Quarterly service'), '2026-04-30'::date,
  'next due derived: last done + 3 months; name trimmed');
select lives_ok($$update public.obligation set interval_count = 1 where name = 'Quarterly service'$$, 'rule edit');
select is((select next_due_date from public.obligation where name = 'Quarterly service'), '2026-02-28'::date, 'rule edit recomputes next due');
select throws_ok($$update public.obligation set next_due_date = '2030-01-01' where name = 'Quarterly service'$$, '42501', null, 'next due has no grant');
select throws_ok($$update public.obligation set due_state = 'scheduled' where name = 'Quarterly service'$$, '42501', null, 'state has no grant');
select throws_ok($$update public.obligation set last_done_date = '2026-02-01' where name = 'Quarterly service'$$, '42501', null,
  'last done is insert only (5.2 action after that)');
select throws_ok($$insert into public.obligation (tenant_id, asset_id, name, obligation_type, interval_count, interval_unit, anchor, first_due_date)
  values ('00000000-0000-0000-0000-00000000000a', '00000000-0000-0000-0000-00000051a001', 'quarterly SERVICE', 'service', 3, 'month', 'completion', '2026-01-31')$$,
  '23505', null, 'name unique per asset, case-insensitive');
select throws_ok($$insert into public.obligation (tenant_id, asset_id, name, obligation_type, interval_count, interval_unit, anchor, first_due_date)
  values ('00000000-0000-0000-0000-00000000000a', '00000000-0000-0000-0000-00000051a003', 'X', 'service', 3, 'month', 'completion', '2026-01-31')$$,
  '23514', 'asset_id: asset is deleted or not found', 'no obligation on a deleted asset');
select throws_ok($$insert into public.obligation (tenant_id, asset_id, name, obligation_type, interval_count, interval_unit, anchor, first_due_date)
  values ('00000000-0000-0000-0000-00000000000a', '00000000-0000-0000-0000-00000051a001', 'Y', 'service', 3, 'hour', 'completion', '2026-01-31')$$,
  '23514', null, 'unknown unit refused');
reset role;

-- 3. State (Â§5), N = 30, today in Kolkata. One obligation per case on Lathe and Boiler.
insert into public.obligation (tenant_id, asset_id, name, obligation_type, interval_count, interval_unit, anchor, first_due_date, is_active)
select '00000000-0000-0000-0000-00000000000a', a, n, 'service', 1, 'year', 'fixed', pg_temp.d(k), act
from (values ('00000000-0000-0000-0000-00000051a001'::uuid, 'od', -1, true), ('00000000-0000-0000-0000-00000051a001'::uuid, 'today', 0, true),
             ('00000000-0000-0000-0000-00000051a001'::uuid, 'n', 30, true), ('00000000-0000-0000-0000-00000051a001'::uuid, 'n1', 31, true),
             ('00000000-0000-0000-0000-00000051a001'::uuid, 'off', -5, false), ('00000000-0000-0000-0000-00000051a002'::uuid, 'boiler', -3, true)) v (a, n, k, act);
select is(pg_temp.st('od') || ',' || pg_temp.st('today') || ',' || pg_temp.st('n') || ',' || pg_temp.st('n1') || ',' || pg_temp.st('off'),
  'overdue,due_soon,due_soon,scheduled,paused', 'states: due yesterday, due today, today + N, today + N + 1, inactive');
select is((select due_state_until from public.obligation where name = 'n1'), pg_temp.d(1), 'until: scheduled becomes due soon tomorrow');
select is((select due_state_until from public.obligation where name = 'today'), pg_temp.d(1), 'until: due today is overdue tomorrow');
select ok((select bool_and(due_state_until is null) from public.obligation where name in ('od', 'off')), 'until: overdue and paused have none');
select is(pg_temp.events('od', 'obligation.overdue'), 1::bigint, 'event: entering overdue');
select is(pg_temp.events('n', 'obligation.due_soon'), 1::bigint, 'event: entering due soon');
select is(pg_temp.events('n1', 'obligation.due_soon') + pg_temp.events('off', 'obligation.overdue'), 0::bigint, 'no event for scheduled or paused');
select is((select payload ->> 'to' from private.outbox_event e join public.obligation o on o.id = e.aggregate_id where o.name = 'od' and e.event_type = 'obligation.overdue'), 'overdue', 'payload has the new state');
select is(private.refresh_obligation_state(array(select id from public.obligation where tenant_id = '00000000-0000-0000-0000-00000000000a')), 0,
  'refresh with nothing changed writes nothing');
select is(pg_temp.events('od', 'obligation.overdue'), 1::bigint, 'and writes no second event');

-- Paused by the obligation flag and by the asset (O6); a reopen brings it back.
update public.obligation set is_active = true where name = 'off';
select is(pg_temp.st('off'), 'overdue', 'reactivated: overdue again');
update public.obligation set is_active = false where name = 'off';
select is(pg_temp.st('off'), 'paused', 'deactivated: paused');
update public.asset set status = 'disposed', status_reason = 'sold',
  status_id = (select id from public.asset_status where tenant_id = '00000000-0000-0000-0000-00000000000a' and code = 'disposed')
where id = '00000000-0000-0000-0000-00000051a002';
select is(pg_temp.st('boiler'), 'paused', 'asset retired: paused');
update public.asset set status = 'inactive',
  status_id = (select id from public.asset_status where tenant_id = '00000000-0000-0000-0000-00000000000a' and code = 'inactive')
where id = '00000000-0000-0000-0000-00000051a002';
select is(pg_temp.st('boiler'), 'paused', 'asset inactive: paused');
update public.asset set status = 'in_stock',
  status_id = (select id from public.asset_status where tenant_id = '00000000-0000-0000-0000-00000000000a' and code = 'in_stock')
where id = '00000000-0000-0000-0000-00000051a002';
select is(pg_temp.st('boiler'), 'overdue', 'asset back in stock: overdue again (in stock is not paused)');
select is(pg_temp.events('boiler', 'obligation.overdue'), 2::bigint, 'each entry into overdue writes one event');
update public.asset set deleted_at = now() where id = '00000000-0000-0000-0000-00000051a002';
select is((select due_state from public.obligation where name = 'boiler'), 'paused', 'asset soft-deleted: paused');

-- A refresh is not an edit: updated_at stays, no audit row.
set local session_replication_role = replica;
update public.obligation set updated_at = '2026-01-01' where name = 'n1';
set local session_replication_role = origin;
create temp table audit_before as
  select count(*) as n from public.audit_log where record_id = (select id from public.obligation where name = 'n1');

-- The job. Nothing due today.
select is(private.refresh_due_obligation_states(), 0, 'job: nothing due, nothing written');
select is(private.refresh_due_obligation_states(now() + interval '1 day'), 2, 'job tomorrow: two obligations change');
select is(pg_temp.st('today') || ',' || pg_temp.st('n1'), 'overdue,due_soon', 'job tomorrow: due today is overdue, today + N + 1 is due soon');
select is(pg_temp.events('n1', 'obligation.due_soon') + pg_temp.events('today', 'obligation.overdue'), 2::bigint, 'job writes one event per change');
select is((select updated_at from public.obligation where name = 'n1'), '2026-01-01'::timestamptz, 'refresh does not move updated_at');
select is((select count(*) from public.audit_log where record_id = (select id from public.obligation where name = 'n1')), (select n from audit_before),
  'refresh writes no audit row');
select is(private.refresh_due_obligation_states(now() + interval '1 day'), 0, 'job again: nothing more');
do $$ begin perform private.refresh_obligation_state(array(select id from public.obligation)); end $$;
select is(pg_temp.st('n1'), 'scheduled', 'back to today');

-- Midnight is the tenant's: due 15 Jun; at 20:00 UTC Pago Pago is still on the 15th, Kolkata on the 16th.
update public.obligation set first_due_date = '2026-06-15' where name = 'n';
update public.tenant set time_zone = 'Pacific/Pago_Pago' where id = '00000000-0000-0000-0000-00000000000a';
do $$ begin perform private.refresh_obligation_state(array(select id from public.obligation where name = 'n'), '2026-06-15 20:00+00'); end $$;
select is(pg_temp.st('n'), 'due_soon', 'Pago Pago (UTC-11): due today');
update public.tenant set time_zone = 'Asia/Kolkata' where id = '00000000-0000-0000-0000-00000000000a';
do $$ begin perform private.refresh_obligation_state(array(select id from public.obligation where name = 'n'), '2026-06-15 20:00+00'); end $$;
select is(pg_temp.st('n'), 'overdue', 'Kolkata (UTC+5:30): already overdue');
update public.obligation set first_due_date = pg_temp.d(30) where name = 'n';
select is(pg_temp.st('n'), 'due_soon', 'rule edit refreshes the state');

-- Â§4: the due-soon setting and the time zone queue the tenant; the job walks it in batches.
update public.tenant set obligation_refresh_after = null, coverage_refresh_after = null where id = '00000000-0000-0000-0000-00000000000a';
update public.tenant set obligation_due_soon_days = 60 where id = '00000000-0000-0000-0000-00000000000a';
select isnt((select obligation_refresh_after from public.tenant where id = '00000000-0000-0000-0000-00000000000a'), null, 'N changed: tenant queued');
select is(pg_temp.st('n1'), 'scheduled', 'before the job the old N still applies');
select ok(private.refresh_due_obligation_states(p_batch => 2) > 0, 'job refreshes the queued tenant in batches of 2');
select is((select obligation_refresh_after from public.tenant where id = '00000000-0000-0000-0000-00000000000a'), null, 'queue cleared');
select is(pg_temp.st('n1'), 'due_soon', 'N = 60: due at + 31 is due soon');
update public.tenant set time_zone = 'Europe/London' where id = '00000000-0000-0000-0000-00000000000a';
select isnt((select obligation_refresh_after from public.tenant where id = '00000000-0000-0000-0000-00000000000a'), null, 'time zone changed: tenant queued');
update public.tenant set time_zone = 'Asia/Kolkata', obligation_refresh_after = null where id = '00000000-0000-0000-0000-00000000000a';

-- update_tenant_settings takes the new setting; an older call keeps it.
select tests.act_as('00000000-0000-0000-0000-0000000a0001', '00000000-0000-0000-0000-00000000000a');
select lives_ok($$select public.update_tenant_settings('INR', 'en-IN', 'Asia/Kolkata', 'dd-MM-yyyy', 4::smallint, '{}', null, 14::smallint)$$,
  'settings: due-soon days set');
select is((select obligation_due_soon_days from public.tenant where id = '00000000-0000-0000-0000-00000000000a'), 14::smallint, 'settings: saved');
select lives_ok($$select public.update_tenant_settings('INR', 'en-IN', 'Asia/Kolkata', 'dd-MM-yyyy', 4::smallint, '{}')$$, 'settings: old call');
select is((select obligation_due_soon_days from public.tenant where id = '00000000-0000-0000-0000-00000000000a'), 14::smallint, 'settings: old call keeps it');
reset role;
select isnt((select obligation_refresh_after from public.tenant where id = '00000000-0000-0000-0000-00000000000a'), null, 'settings save queued the tenant');
select throws_ok($$update public.tenant set obligation_due_soon_days = 0 where id = '00000000-0000-0000-0000-00000000000a'$$, '23514', null, 'N between 1 and 365');

-- 4. Permission steps on obligation, as a1.
select tests.act_as('00000000-0000-0000-0000-0000000000a1', '00000000-0000-0000-0000-00000000000a');
select is((select count(*) from public.obligation), 0::bigint, 'no grant: sees nothing');
select throws_ok($$insert into public.obligation (tenant_id, asset_id, name, obligation_type, interval_count, interval_unit, anchor, first_due_date)
  values ('00000000-0000-0000-0000-00000000000a', '00000000-0000-0000-0000-00000051a001', 'P1', 'service', 1, 'year', 'fixed', '2027-01-01')$$,
  '42501', null, 'no grant: cannot add');
reset role;
select tests.grant('00000000-0000-0000-0000-00000000000a', '00000000-0000-0000-0000-0000000000a1', 'obligation', '{view}');
select tests.act_as('00000000-0000-0000-0000-0000000000a1', '00000000-0000-0000-0000-00000000000a');
select ok((select count(*) from public.obligation) > 0, 'view: sees obligations');
select throws_ok($$insert into public.obligation (tenant_id, asset_id, name, obligation_type, interval_count, interval_unit, anchor, first_due_date)
  values ('00000000-0000-0000-0000-00000000000a', '00000000-0000-0000-0000-00000051a001', 'P1', 'service', 1, 'year', 'fixed', '2027-01-01')$$,
  '42501', null, 'view: cannot add');
update public.obligation set notes = 'x' where name = 'od';
select is((select notes from public.obligation where name = 'od'), null, 'view: an update touches nothing');
reset role;
select tests.grant('00000000-0000-0000-0000-00000000000a', '00000000-0000-0000-0000-0000000000a1', 'obligation', '{create,update}');
select tests.act_as('00000000-0000-0000-0000-0000000000a1', '00000000-0000-0000-0000-00000000000a');
select lives_ok($$insert into public.obligation (tenant_id, asset_id, name, obligation_type, interval_count, interval_unit, anchor, first_due_date)
  values ('00000000-0000-0000-0000-00000000000a', '00000000-0000-0000-0000-00000051a001', 'P1', 'calibration', 1, 'year', 'fixed', '2027-01-01')$$,
  'create: adds');
select lives_ok($$update public.obligation set notes = 'check belt' where name = 'P1'$$, 'update: edits');
select lives_ok($$update public.obligation set deleted_at = now() where name = 'P1'$$, 'update: removes (O7, soft delete)');
select throws_ok($$delete from public.obligation where name = 'od'$$, '42501', null, 'no hard delete');
reset role;
-- Technician: view and complete only (1.6 grid).
select tests.act_as('00000000-0000-0000-0000-0000000a0004', '00000000-0000-0000-0000-00000000000a');
select ok((select count(*) from public.obligation) > 0, 'technician: sees obligations');
select throws_ok($$insert into public.obligation (tenant_id, asset_id, name, obligation_type, interval_count, interval_unit, anchor, first_due_date)
  values ('00000000-0000-0000-0000-00000000000a', '00000000-0000-0000-0000-00000051a001', 'T1', 'service', 1, 'year', 'fixed', '2027-01-01')$$,
  '42501', null, 'technician: cannot add');
reset role;
-- Read-only tenant B.
select tests.grant('00000000-0000-0000-0000-00000000000b', '00000000-0000-0000-0000-0000000000a1', 'obligation');
select tests.act_as('00000000-0000-0000-0000-0000000000a1', '00000000-0000-0000-0000-00000000000b');
select throws_ok($$insert into public.obligation (tenant_id, asset_id, name, obligation_type, interval_count, interval_unit, anchor, first_due_date)
  values ('00000000-0000-0000-0000-00000000000b', '00000000-0000-0000-0000-00000051a0bb', 'B1', 'service', 1, 'year', 'fixed', '2027-01-01')$$,
  '42501', null, 'read-only tenant: cannot add');
reset role;

select * from tests.cross_tenant('public.obligation', 'obligation',
  '{"asset_id":"00000000-0000-0000-0000-00000051a001","name":"ct-row","obligation_type":"service","interval_count":1,"interval_unit":"year","anchor":"fixed","first_due_date":"2027-01-01"}',
  '{"asset_id":"00000000-0000-0000-0000-00000051a0bb"}');

-- 5. Category defaults (Â§2).
select throws_ok($$update public.asset_category set default_obligations = '{}' where id = '00000000-0000-0000-0000-00000051c001'$$,
  '23514', null, 'defaults: must be a list');
select throws_ok($$update public.asset_category set default_obligations = '[{"name":"S","obligation_type":"service","interval_count":3,"interval_unit":"month","anchor":"fixed","x":1}]' where id = '00000000-0000-0000-0000-00000051c001'$$,
  '23514', null, 'defaults: unknown key');
select throws_ok($$update public.asset_category set default_obligations = '[{"name":"S","obligation_type":"service","interval_count":1.5,"interval_unit":"month","anchor":"fixed"}]' where id = '00000000-0000-0000-0000-00000051c001'$$,
  '23514', null, 'defaults: whole interval count');
select throws_ok($$update public.asset_category set default_obligations = '[{"name":"S","obligation_type":"service","interval_count":"3","interval_unit":"month","anchor":"fixed"}]' where id = '00000000-0000-0000-0000-00000051c001'$$,
  '23514', null, 'defaults: count is a number');
select throws_ok($$update public.asset_category set default_obligations = '[{"name":"S","obligation_type":"repair","interval_count":3,"interval_unit":"month","anchor":"fixed"}]' where id = '00000000-0000-0000-0000-00000051c001'$$,
  '23514', null, 'defaults: unknown type');
select throws_ok($$update public.asset_category set default_obligations = '[{"name":"S","obligation_type":"service","interval_count":3,"interval_unit":"month","anchor":"fixed"},{"name":" s ","obligation_type":"service","interval_count":6,"interval_unit":"month","anchor":"fixed"}]' where id = '00000000-0000-0000-0000-00000051c001'$$,
  '23514', 'default_obligations: names must be unique', 'defaults: duplicate names');
select throws_ok($$update public.asset_category set default_warranty_months = 7 where id = '00000000-0000-0000-0000-00000051c001'$$,
  '23514', null, 'warranty default: a 4.5 term only');

-- Tree: Rotating (warranty 12, quarterly service) > Pumps (inherits) > Small pumps (inherits);
-- Rotating > Fans (own empty list, inherits the warranty).
insert into public.asset_category (id, tenant_id, parent_id, name, default_obligations, default_warranty_months) values
  ('00000000-0000-0000-0000-00000051c010', '00000000-0000-0000-0000-00000000000a', null, 'Rotating',
   '[{"name":"Quarterly service","obligation_type":"service","interval_count":3,"interval_unit":"month","anchor":"completion"},
     {"name":"Annual inspection","obligation_type":"inspection","interval_count":1,"interval_unit":"year","anchor":"fixed"}]', 12);
insert into public.asset_category (id, tenant_id, parent_id, name, default_obligations, default_warranty_months) values
  ('00000000-0000-0000-0000-00000051c011', '00000000-0000-0000-0000-00000000000a', '00000000-0000-0000-0000-00000051c010', 'Pumps', null, null),
  ('00000000-0000-0000-0000-00000051c013', '00000000-0000-0000-0000-00000000000a', '00000000-0000-0000-0000-00000051c010', 'Fans', '[]', null);
insert into public.asset_category (id, tenant_id, parent_id, name) values
  ('00000000-0000-0000-0000-00000051c012', '00000000-0000-0000-0000-00000000000a', '00000000-0000-0000-0000-00000051c011', 'Small pumps');
select is((select jsonb_array_length(default_obligations) || ',' || default_warranty_months || ',' || obligations_from || ',' || warranty_from
           from private.category_defaults('00000000-0000-0000-0000-00000000000a', '00000000-0000-0000-0000-00000051c012')),
  '2,12,00000000-0000-0000-0000-00000051c010,00000000-0000-0000-0000-00000051c010', 'grandchild inherits both from the grandparent');
select is((select default_obligations::text || ',' || default_warranty_months || ',' || obligations_from
           from private.category_defaults('00000000-0000-0000-0000-00000000000a', '00000000-0000-0000-0000-00000051c013')),
  '[],12,00000000-0000-0000-0000-00000051c013', 'own empty list stops obligations; the warranty is still inherited');
select ok((select default_obligations is null and default_warranty_months is null
           from private.category_defaults('00000000-0000-0000-0000-00000000000a', '00000000-0000-0000-0000-00000051c001')),
  'nothing up the tree: no defaults');

-- The app read: needs asset_core.create or category_config.view.
select tests.act_as('00000000-0000-0000-0000-0000000000a1', '00000000-0000-0000-0000-00000000000a');
select is((select count(*) from public.category_defaults('00000000-0000-0000-0000-00000051c011')), 0::bigint, 'app read: no grant, nothing');
reset role;
select tests.grant('00000000-0000-0000-0000-00000000000a', '00000000-0000-0000-0000-0000000000a1', 'asset_core', '{view,create}');
select tests.act_as('00000000-0000-0000-0000-0000000000a1', '00000000-0000-0000-0000-00000000000a');
select is((select default_warranty_months from public.category_defaults('00000000-0000-0000-0000-00000051c011')), 12::smallint,
  'app read: asset_core.create gets the warranty default (4.5 Term prefill)');

-- O3: copy on insert, by a user who may create assets but holds no obligation grant (a1's obligation
-- test groups are removed first).
reset role;
delete from public.user_group_assignment ga using public.security_group g
where g.id = ga.security_group_id and ga.user_id = '00000000-0000-0000-0000-0000000000a1'
  and ga.tenant_id = '00000000-0000-0000-0000-00000000000a'
  and exists (select 1 from public.group_domain_policy p join public.domain_operation o on o.id = p.domain_operation_id
              join public.security_domain d on d.id = o.security_domain_id
              where p.security_group_id = g.id and d.code = 'obligation');
select tests.act_as('00000000-0000-0000-0000-0000000000a1', '00000000-0000-0000-0000-00000000000a');
select ok(not private.has_permission('obligation', 'create'), 'fixture: a1 has no obligation.create');
select lives_ok($$insert into public.asset (id, tenant_id, name, category_id) values
  ('00000000-0000-0000-0000-00000051a010', '00000000-0000-0000-0000-00000000000a', 'Pump 1', '00000000-0000-0000-0000-00000051c012')$$,
  'asset created in Small pumps');
reset role;
select is((select string_agg(name || ':' || anchor || ':' || first_due_date, ',' order by name) from public.obligation
           where asset_id = '00000000-0000-0000-0000-00000051a010'),
  'Annual inspection:fixed:' || (pg_temp.d(0) + interval '1 year')::date || ',Quarterly service:completion:' || (pg_temp.d(0) + interval '3 months')::date,
  'new asset copies the inherited defaults; no dates: first due is today + interval');
select is((select count(*) from public.obligation where asset_id = '00000000-0000-0000-0000-00000051a010' and due_state = 'scheduled'), 2::bigint,
  'copied rows get their state');
-- O4: an old asset is not overdue on day one.
insert into public.asset (id, tenant_id, name, category_id, in_service_date) values
  ('00000000-0000-0000-0000-00000051a011', '00000000-0000-0000-0000-00000000000a', 'Pump old', '00000000-0000-0000-0000-00000051c011', '2020-01-15');
select is((select first_due_date from public.obligation where asset_id = '00000000-0000-0000-0000-00000051a011' and name = 'Annual inspection'),
  (select case when pg_temp.d(0) <= make_date(extract(year from pg_temp.d(0))::int, 1, 15)
               then make_date(extract(year from pg_temp.d(0))::int, 1, 15)
               else make_date(extract(year from pg_temp.d(0))::int + 1, 1, 15) end),
  'old asset: first 15 Jan on or after today, on the in-service calendar');
select ok((select bool_and(due_state <> 'overdue') from public.obligation where asset_id = '00000000-0000-0000-0000-00000051a011'),
  'old asset: nothing overdue');
insert into public.asset (id, tenant_id, name, category_id) values
  ('00000000-0000-0000-0000-00000051a012', '00000000-0000-0000-0000-00000000000a', 'Fan 1', '00000000-0000-0000-0000-00000051c013');
select is((select count(*) from public.obligation where asset_id = '00000000-0000-0000-0000-00000051a012'), 0::bigint, 'empty own list: nothing copied');
-- The asset owns its rows: a category change or a default change later touches nothing.
update public.asset set category_id = '00000000-0000-0000-0000-00000051c013' where id = '00000000-0000-0000-0000-00000051a010';
select is((select count(*) from public.obligation where asset_id = '00000000-0000-0000-0000-00000051a010' and deleted_at is null), 2::bigint,
  'category change keeps the obligations');
update public.asset_category set default_obligations = '[]' where id = '00000000-0000-0000-0000-00000051c010';
select is((select count(*) from public.obligation where asset_id = '00000000-0000-0000-0000-00000051a011' and deleted_at is null), 2::bigint,
  'category default changed later: existing assets untouched');

-- 6. Plans on a larger tenant: the Maintenance tab and the job walk the state indexes.
set local session_replication_role = replica;
insert into public.obligation (tenant_id, asset_id, name, obligation_type, interval_count, interval_unit, anchor, first_due_date,
                               next_due_date, due_state, due_state_until)
select '00000000-0000-0000-0000-00000000000a', '00000000-0000-0000-0000-00000051a001', 'Bulk ' || n, 'service', 1, 'year', 'fixed',
       pg_temp.d(n % 700 - 100), pg_temp.d(n % 700 - 100), (array['scheduled', 'due_soon', 'overdue', 'paused'])[n % 4 + 1],
       case when n % 4 < 2 then pg_temp.d(n % 700) end
from generate_series(1, 30000) n;
set local session_replication_role = origin;
analyze public.obligation;
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
grant execute on function pg_temp.plan(text) to authenticated;
select tests.act_as('00000000-0000-0000-0000-0000000a0003', '00000000-0000-0000-0000-00000000000a');
select matches(pg_temp.plan($$select * from public.obligation where tenant_id = '00000000-0000-0000-0000-00000000000a' and due_state = 'overdue'
  and deleted_at is null order by next_due_date, id limit 50$$),
  'Index Scan using obligation_state_idx', 'Maintenance tab: walks obligation_state_idx in due order');
reset role;
select matches(pg_temp.plan(format($$select o.id from public.obligation o where o.tenant_id = '00000000-0000-0000-0000-00000000000a'
  and o.deleted_at is null and o.due_state_until <= %L limit 10000$$, pg_temp.d(0))),
  'Index (Only )?Scan using obligation_until_idx', 'job: probes obligation_until_idx');
set local session_replication_role = replica;
delete from public.obligation where name like 'Bulk %';
set local session_replication_role = origin;
analyze public.obligation;

select * from finish();
rollback;
