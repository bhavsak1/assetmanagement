-- Story 5.2: service records, complete_obligation and undo_completion, the cost masking.
-- docs/data-model-goal5.md §12. Uses the seed (tenant A active in Asia/Kolkata, INR; B read_only; a1 in A and B,
-- no groups; planner.a ...a0003, tech.a ...a0004) and supabase/test_harness.sql.
begin;
select plan(91);

create function pg_temp.d(n int) returns date language sql as $$
  select (now() at time zone 'Asia/Kolkata')::date + n;
$$;
create function pg_temp.ob(p_name text) returns uuid language sql security definer as $$
  select id from public.obligation where tenant_id = '00000000-0000-0000-0000-00000000000a' and name = p_name and deleted_at is null;
$$;
create function pg_temp.next(p_name text) returns date language sql security definer as $$
  select next_due_date from public.obligation where id = pg_temp.ob(p_name);
$$;
create function pg_temp.last(p_name text) returns date language sql security definer as $$
  select last_done_date from public.obligation where id = pg_temp.ob(p_name);
$$;
create function pg_temp.st(p_name text) returns text language sql security definer as $$
  select due_state from public.obligation where id = pg_temp.ob(p_name);
$$;
create function pg_temp.events(p_name text, p_type text) returns bigint language sql security definer as $$
  select count(*) from private.outbox_event e where e.aggregate_id = pg_temp.ob(p_name) and e.event_type = p_type;
$$;
create function pg_temp.done(p_name text, p_on date) returns uuid language sql as $$
  select public.complete_obligation(pg_temp.ob(p_name), p_on);
$$;
create function pg_temp.rec(p_name text, p_on date) returns uuid language sql security definer as $$
  select id from public.service_record where obligation_id = pg_temp.ob(p_name) and done_on = p_on and deleted_at is null;
$$;
create function pg_temp.upd(q text) returns int language plpgsql as $$
declare n int;
begin
  execute q;
  get diagnostics n = row_count;
  return n;
end;
$$;
create function pg_temp.outbox(p_where text) returns bigint language plpgsql security definer as $$
declare n bigint;
begin
  execute 'select count(*) from private.outbox_event where ' || p_where into n;
  return n;
end;
$$;
create function pg_temp.nd(p_first date, p_cur date, p_done date) returns date language sql security definer as $$
  select private.obligation_next_due('fixed', 1, 'month', p_first, null, p_cur, p_done);
$$;
create function pg_temp.bob() returns uuid language sql security definer as $$
  select id from public.obligation where name = 'B ob';
$$;

-- Fixtures, as postgres.
insert into public.asset_category (id, tenant_id, name) values
  ('00000000-0000-0000-0000-00000052c001', '00000000-0000-0000-0000-00000000000a', 'Machines'),
  ('00000000-0000-0000-0000-00000052c00b', '00000000-0000-0000-0000-00000000000b', 'B cat');
insert into public.asset (id, tenant_id, name, category_id) values
  ('00000000-0000-0000-0000-00000052a001', '00000000-0000-0000-0000-00000000000a', 'Lathe', '00000000-0000-0000-0000-00000052c001'),
  ('00000000-0000-0000-0000-00000052a002', '00000000-0000-0000-0000-00000000000a', 'Boiler', '00000000-0000-0000-0000-00000052c001'),
  ('00000000-0000-0000-0000-00000052a003', '00000000-0000-0000-0000-00000000000a', 'Spare', '00000000-0000-0000-0000-00000052c001'),
  ('00000000-0000-0000-0000-00000052a0bb', '00000000-0000-0000-0000-00000000000b', 'B asset', '00000000-0000-0000-0000-00000052c00b');
insert into public.vendor (id, tenant_id, name, roles, is_active) values
  ('00000000-0000-0000-0000-00000052e001', '00000000-0000-0000-0000-00000000000a', 'Atlas', '{om}', true),
  ('00000000-0000-0000-0000-00000052e002', '00000000-0000-0000-0000-00000000000a', 'Old works', '{om}', false),
  ('00000000-0000-0000-0000-00000052e0bb', '00000000-0000-0000-0000-00000000000b', 'B vendor', '{om}', true);
insert into public.obligation (tenant_id, asset_id, name, obligation_type, interval_count, interval_unit, anchor, first_due_date, last_done_date, is_active)
select '00000000-0000-0000-0000-00000000000a', a, n, 'service', c, u, an, pg_temp.d(f), case when l is not null then pg_temp.d(l) end, act
from (values
  ('00000000-0000-0000-0000-00000052a001'::uuid, 'comp',   'completion', 1, 'month', -10,  null::int, true),
  ('00000000-0000-0000-0000-00000052a001'::uuid, 'late',   'completion', 3, 'month', -30,  null, true),
  ('00000000-0000-0000-0000-00000052a001'::uuid, 'fix-early', 'fixed',   3, 'month',  20,  null, true),
  ('00000000-0000-0000-0000-00000052a001'::uuid, 'fix-on', 'fixed',      3, 'month',   0,  null, true),
  ('00000000-0000-0000-0000-00000052a001'::uuid, 'fix-missed', 'fixed',  1, 'month', -100, null, true),
  ('00000000-0000-0000-0000-00000052a001'::uuid, 'hist',   'completion', 1, 'month', -60,  -50, true),
  ('00000000-0000-0000-0000-00000052a001'::uuid, 'perm',   'completion', 1, 'year',   -5,  null, true),
  ('00000000-0000-0000-0000-00000052a001'::uuid, 'off',    'completion', 1, 'year',   -5,  null, false),
  ('00000000-0000-0000-0000-00000052a001'::uuid, 'gone',   'completion', 1, 'year',   -5,  null, true),
  ('00000000-0000-0000-0000-00000052a002'::uuid, 'boiler', 'fixed',      1, 'year',   -5,  null, true),
  ('00000000-0000-0000-0000-00000052a003'::uuid, 'spare',  'fixed',      1, 'year',   -5,  null, true)) v (a, n, an, c, u, f, l, act);
insert into public.obligation (tenant_id, asset_id, name, obligation_type, interval_count, interval_unit, anchor, first_due_date)
values ('00000000-0000-0000-0000-00000000000b', '00000000-0000-0000-0000-00000052a0bb', 'B ob', 'service', 1, 'year', 'fixed', '2027-01-01');
update public.obligation set deleted_at = now() where name = 'gone';
update public.asset set status = 'disposed', status_reason = 'sold',
  status_id = (select id from public.asset_status where tenant_id = '00000000-0000-0000-0000-00000000000a' and code = 'disposed')
where id = '00000000-0000-0000-0000-00000052a002';
update public.asset set status = 'inactive',
  status_id = (select id from public.asset_status where tenant_id = '00000000-0000-0000-0000-00000000000a' and code = 'inactive')
where id = '00000000-0000-0000-0000-00000052a003';

-- 1. Permission steps, user a1 in tenant A.
select tests.act_as('00000000-0000-0000-0000-0000000000a1', '00000000-0000-0000-0000-00000000000a');
select throws_ok($$select pg_temp.done('perm', pg_temp.d(0))$$, '42501', null, 'no grant: cannot complete');
select throws_ok($$insert into public.service_record (tenant_id, obligation_id, asset_id, done_on, advanced)
  values ('00000000-0000-0000-0000-00000000000a', pg_temp.ob('perm'), '00000000-0000-0000-0000-00000052a001', pg_temp.d(0), true)$$,
  '42501', null, 'no direct insert, even for the table');
reset role;
select tests.grant('00000000-0000-0000-0000-00000000000a', '00000000-0000-0000-0000-0000000000a1', 'obligation', '{view}');
select tests.act_as('00000000-0000-0000-0000-0000000000a1', '00000000-0000-0000-0000-00000000000a');
select throws_ok($$select pg_temp.done('perm', pg_temp.d(0))$$, '42501', null, 'obligation.view only: cannot complete');
reset role;
select tests.grant('00000000-0000-0000-0000-00000000000a', '00000000-0000-0000-0000-0000000000a1', 'obligation', '{complete}');
select tests.act_as('00000000-0000-0000-0000-0000000000a1', '00000000-0000-0000-0000-00000000000a');
select lives_ok($$select pg_temp.done('perm', pg_temp.d(-1))$$, 'obligation.complete: completes (S5)');
select is((select count(*) from public.service_record), 0::bigint, 'without service_record.view: no records seen');
select is((select count(*) from public.service_history('00000000-0000-0000-0000-00000052a001')), 0::bigint, 'without service_record.view: empty history');
select throws_ok($$select public.complete_obligation(pg_temp.ob('perm'), pg_temp.d(0), p_cost => 100)$$,
  '42501', 'no permission to change service cost', 'cost without service_values.update: refused, not dropped');
reset role;
select tests.grant('00000000-0000-0000-0000-00000000000a', '00000000-0000-0000-0000-0000000000a1', 'service_record', '{view}');
select tests.act_as('00000000-0000-0000-0000-0000000000a1', '00000000-0000-0000-0000-00000000000a');
select is((select count(*) from public.service_record), 1::bigint, 'service_record.view: sees the record');
select is((select done_by_user_id from public.service_record), '00000000-0000-0000-0000-0000000000a1'::uuid, 'done by defaults to me');
select throws_ok($$select cost_amount from public.service_record$$, '42501', null, 'cost column not readable on the table');
select is((select count(*) from public.service_record r
           where r.id = pg_temp.rec('perm', pg_temp.d(-1)) and r.notes is null), 1::bigint, 'other columns readable');
select is((select count(*) from public.service_record_view), 1::bigint, 'view lists the live record');
select is((select service_history.done_by_name from public.service_history('00000000-0000-0000-0000-00000052a001')),
  (select display_name from public.user_profile where id = '00000000-0000-0000-0000-0000000000a1'), 'history shows who did it');
select is(pg_temp.upd($$update public.service_record set notes = 'x'$$), 0,
  'without service_record.update: correction touches nothing');
select throws_ok($$select public.undo_completion(pg_temp.rec('perm', pg_temp.d(-1)))$$, '42501', null, 'without service_record.update: no undo');
reset role;
select tests.grant('00000000-0000-0000-0000-00000000000a', '00000000-0000-0000-0000-0000000000a1', 'service_record', '{update}');
select tests.act_as('00000000-0000-0000-0000-0000000000a1', '00000000-0000-0000-0000-00000000000a');
select is(pg_temp.upd($$update public.service_record set notes = ' belt changed ', outcome = 'pass'$$), 1,
  'service_record.update: corrects notes and outcome');
select is((select notes from public.service_record), 'belt changed', 'notes trimmed');
select throws_ok($$update public.service_record set done_on = pg_temp.d(-2)$$, '42501', null, 'done date has no grant (undo, then record again)');
select throws_ok($$update public.service_record set deleted_at = now()$$, '42501', null, 'soft delete has no grant (undo is the action)');
select throws_ok($$update public.service_record set cost_amount = 5, cost_currency = 'INR'$$, '42501', 'no permission to change service cost',
  'cost correction needs service_values.update');
select throws_ok($$update public.service_record set vendor_id = '00000000-0000-0000-0000-00000052e002'$$, '23514', null, 'inactive vendor refused');
select throws_ok($$update public.service_record set done_by_user_id = '00000000-0000-0000-0000-0000000b0001'$$, '23514', null,
  'person outside the tenant refused');
reset role;
select tests.grant('00000000-0000-0000-0000-00000000000a', '00000000-0000-0000-0000-0000000000a1', 'service_values', '{view,update}');
select tests.act_as('00000000-0000-0000-0000-0000000000a1', '00000000-0000-0000-0000-00000000000a');
select lives_ok($$select public.complete_obligation(pg_temp.ob('perm'), pg_temp.d(0), p_cost => 1250.5,
  p_vendor_id => '00000000-0000-0000-0000-00000052e001', p_outcome => 'fail')$$, 'service_values.update: completes with a cost and a vendor');
select results_eq($$select cost_amount, cost_currency::text, vendor_name, done_by_user_id from public.service_history('00000000-0000-0000-0000-00000052a001') limit 1$$,
  $$values (1250.5::numeric, 'INR', null::text, null::uuid)$$,
  'cost in the tenant currency; contractor job has no person; vendor name hidden without vendor_core.view');
select is((select pg_temp.next('perm')), (pg_temp.d(0) + interval '1 year')::date, 'a failed outcome still advances (S6)');
select is(pg_temp.outbox($$event_type = 'obligation.completed' and payload ? 'cost_amount'$$), 0::bigint,
  'no cost in any event payload');
reset role;

-- Starter groups: a technician completes but cannot see or enter cost; a planner can.
select tests.act_as('00000000-0000-0000-0000-0000000a0004', '00000000-0000-0000-0000-00000000000a');
select is((select cost_amount from public.service_record_view where done_on = pg_temp.d(0) and obligation_id = pg_temp.ob('perm')), null,
  'technician: cost masked in the view');
select throws_ok($$select public.complete_obligation(pg_temp.ob('perm'), pg_temp.d(0), p_cost => 1)$$, '42501', null, 'technician: no cost entry');
select lives_ok($$select pg_temp.done('perm', pg_temp.d(0))$$, 'technician: completes');
reset role;
select tests.act_as('00000000-0000-0000-0000-0000000a0003', '00000000-0000-0000-0000-00000000000a');
select is((select cost_amount from public.service_record_view where cost_amount is not null), 1250.5::numeric, 'planner: sees the cost');
reset role;

-- Read-only tenant B.
select tests.grant('00000000-0000-0000-0000-00000000000b', '00000000-0000-0000-0000-0000000000a1', 'obligation');
select tests.act_as('00000000-0000-0000-0000-0000000000a1', '00000000-0000-0000-0000-00000000000b');
select throws_ok($$select public.complete_obligation(pg_temp.bob(), '2026-10-01')$$,
  '42501', null, 'read-only tenant: cannot complete');
reset role;

-- 2. Refusals, as the tenant admin.
select tests.act_as('00000000-0000-0000-0000-0000000a0001', '00000000-0000-0000-0000-00000000000a');
select throws_ok($$select pg_temp.done('off', pg_temp.d(0))$$, '22023', 'a paused obligation cannot be completed', 'inactive obligation refused');
select throws_ok($$select pg_temp.done('boiler', pg_temp.d(0))$$, '22023', null, 'disposed asset refused');
select throws_ok($$select pg_temp.done('spare', pg_temp.d(0))$$, '22023', null, 'inactive asset refused');
select throws_ok($$select public.complete_obligation((select id from public.obligation where name = 'gone'), pg_temp.d(0))$$,
  'P0002', null, 'deleted obligation: not found');
select throws_ok($$select public.complete_obligation(pg_temp.bob(), pg_temp.d(0))$$,
  'P0002', null, 'another tenant''s obligation: not found');
select throws_ok($$select pg_temp.done('comp', pg_temp.d(1))$$, '22023', null, 'future date refused');
select throws_ok($$select pg_temp.done('comp', pg_temp.d(-367))$$, '22023', null, 'more than 366 days back refused');
select throws_ok($$select pg_temp.done('comp', null)$$, '23502', null, 'date required');
select throws_ok($$select public.complete_obligation(pg_temp.ob('comp'), pg_temp.d(0), p_vendor_id => '00000000-0000-0000-0000-00000052e002')$$,
  '23514', null, 'inactive vendor refused');
select throws_ok($$select public.complete_obligation(pg_temp.ob('comp'), pg_temp.d(0), p_vendor_id => '00000000-0000-0000-0000-00000052e0bb')$$,
  '23514', null, 'another tenant''s vendor refused');
select throws_ok($$select public.complete_obligation(pg_temp.ob('comp'), pg_temp.d(0), p_outcome => 'maybe')$$, '23514', null, 'unknown outcome refused');
select is(pg_temp.events('comp', 'obligation.completed'), 0::bigint, 'refused calls wrote no event');

-- 3. Next due after completion (O5, S2).
select lives_ok($$select pg_temp.done('comp', pg_temp.d(-20))$$, 'completion anchor, done early');
select is(pg_temp.next('comp'), (pg_temp.d(-20) + interval '1 month')::date, 'completion early: done date + step');
select is(pg_temp.st('late'), 'overdue', 'before: overdue');
select lives_ok($$select pg_temp.done('late', pg_temp.d(0))$$, 'completion anchor, done late');
select is(pg_temp.next('late'), (pg_temp.d(0) + interval '3 months')::date, 'completion late: done date + step');
select is(pg_temp.st('late'), 'scheduled', 'state refreshed in the same call, no cron');
select is(pg_temp.events('late', 'obligation.completed'), 1::bigint, 'one obligation.completed event');
select is(pg_temp.outbox(format($$aggregate_id = %L and event_type like 'service_record.%%'$$, pg_temp.rec('late', pg_temp.d(0)))), 1::bigint, 'the record''s audit event, once');
select lives_ok($$select pg_temp.done('fix-early', pg_temp.d(0))$$, 'fixed, done early');
select is(pg_temp.next('fix-early'), (pg_temp.d(20) + interval '3 months')::date, 'fixed early: clears this period');
select lives_ok($$select pg_temp.done('fix-on', pg_temp.d(0))$$, 'fixed, on time');
select is(pg_temp.next('fix-on'), (pg_temp.d(0) + interval '3 months')::date, 'fixed on time: next slot');
select lives_ok($$select pg_temp.done('fix-missed', pg_temp.d(0))$$, 'fixed, missed several');
select is(pg_temp.next('fix-missed'),
  pg_temp.nd(pg_temp.d(-100), pg_temp.d(-100), pg_temp.d(0)),
  'fixed missed: first slot after today (one completion clears the backlog)');
select ok(pg_temp.next('fix-missed') > pg_temp.d(0) and pg_temp.next('fix-missed') <= (pg_temp.d(0) + interval '1 month')::date,
  'fixed missed: within one step of today');
select lives_ok($$select pg_temp.done('comp', pg_temp.d(-40))$$, 'back-dated before the latest');
select is(pg_temp.last('comp'), pg_temp.d(-20), 'back-dated: last done stays');
select is(pg_temp.next('comp'), (pg_temp.d(-20) + interval '1 month')::date, 'back-dated: next due stays');
select is((select advanced from public.service_record where id = pg_temp.rec('comp', pg_temp.d(-40))), false, 'back-dated: history only');
select is(pg_temp.events('comp', 'obligation.completed'), 2::bigint, 'still one event per completion');
select lives_ok($$select pg_temp.done('comp', pg_temp.d(-20))$$, 'same day twice: allowed');
select is(pg_temp.last('comp'), pg_temp.d(-20), 'same day: last done unchanged');

-- 4. Undo (S4).
select lives_ok($$select public.undo_completion(pg_temp.rec('comp', pg_temp.d(-40)))$$, 'undo an older record');
select is(pg_temp.last('comp'), pg_temp.d(-20), 'undo older: dates stay');
select lives_ok($$select public.undo_completion((select id from public.service_record where obligation_id = pg_temp.ob('comp')
  and deleted_at is null order by created_at desc limit 1))$$, 'undo one of two on the same day');
select is(pg_temp.last('comp'), pg_temp.d(-20), 'the other one still holds the date');
select lives_ok($$select public.undo_completion(pg_temp.rec('comp', pg_temp.d(-20)))$$, 'undo the last one');
select is(pg_temp.last('comp'), null, 'no records left, no baseline: last done null');
select is(pg_temp.next('comp'), pg_temp.d(-10), 'next due back to the first due');
select is(pg_temp.st('comp'), 'overdue', 'state follows the undo');
select is(pg_temp.events('comp', 'obligation.completion_undone'), 3::bigint, 'one undo event per undo');
select throws_ok($$select public.undo_completion((select id from public.service_record where obligation_id = pg_temp.ob('comp') limit 1))$$,
  'P0002', null, 'an undone record cannot be undone again');
select is((select count(*) from public.service_record where obligation_id = pg_temp.ob('comp')), 3::bigint, 'undone records stay as history');
select is((select count(*) from public.service_history('00000000-0000-0000-0000-00000052a001', pg_temp.ob('comp'))), 0::bigint,
  'history hides undone records');
select lives_ok($$select pg_temp.done('hist', pg_temp.d(-5))$$, 'completion over an imported last done');
select lives_ok($$update public.obligation set interval_count = 2 where id = pg_temp.ob('hist')$$, 'rule edit after the completion');
select lives_ok($$select public.undo_completion(pg_temp.rec('hist', pg_temp.d(-5)))$$, 'undo it');
select is(pg_temp.last('hist'), pg_temp.d(-50), 'undo restores the imported last done (baseline)');
select is(pg_temp.next('hist'), (pg_temp.d(-50) + interval '2 months')::date, 'undo recomputes with the edited rule');
reset role;

select * from tests.cross_tenant('public.service_record', 'service_record',
  format('{"obligation_id":"%s","asset_id":"00000000-0000-0000-0000-00000052a001","done_on":"2026-10-01","advanced":true}', pg_temp.ob('perm'))::jsonb,
  format('{"obligation_id":"%s","asset_id":"00000000-0000-0000-0000-00000052a0bb"}',
         pg_temp.bob())::jsonb);

-- 5. The history read walks service_record_asset_idx.
set local session_replication_role = replica;
insert into public.service_record (tenant_id, obligation_id, asset_id, done_on, advanced)
select '00000000-0000-0000-0000-00000000000a', gen_random_uuid(), gen_random_uuid(), pg_temp.d(-(n % 300)), true
from generate_series(1, 20000) n;
set local session_replication_role = origin;
analyze public.service_record;
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
select matches(pg_temp.plan($$select * from public.service_record_view r
  where r.asset_id = '00000000-0000-0000-0000-00000052a001' order by r.done_on desc, r.id$$),
  'Index Scan using service_record_asset_idx', 'history: walks service_record_asset_idx');
reset role;

select * from finish();
rollback;
