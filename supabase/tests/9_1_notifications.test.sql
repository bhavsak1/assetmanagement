-- Story 9.1: coverage events, the outbox fan-out, the notification inbox and its RLS, the email switch, the
-- daily summary queue, claim and finish, and the jobs role. docs/data-model-goal9.md.
-- Uses the seed: tenant A (...0a, active, Asia/Kolkata), tenant B (...0b, read_only, America/New_York);
-- test.user a1 in A and B with no groups; test.user2 a2 in B only; starter users ...a000n and ...b000n.
begin;
select plan(49);

create function pg_temp.d(n int) returns date language sql as $$
  select (now() at time zone 'Asia/Kolkata')::date + n;
$$;
-- Notifications of a user for one fixture event.
create function pg_temp.n(p_user uuid, p_event uuid) returns bigint language sql as $$
  select count(*) from public.notification where user_id = p_user and event_id = p_event;
$$;
create function pg_temp.back() returns void language sql as $$
  select set_config('role', 'postgres', true), set_config('request.jwt.claims', '', true);
$$;

-- Fixtures, as postgres. Pune (in a1's scope) and Mumbai; asset X in Pune, Y in Mumbai, BB in tenant B.
insert into public.location (id, tenant_id, parent_id, name) values
  ('00000000-0000-0000-0000-0000000091e1', '00000000-0000-0000-0000-00000000000a', null, 'S91 Pune'),
  ('00000000-0000-0000-0000-0000000091e2', '00000000-0000-0000-0000-00000000000a', null, 'S91 Mumbai');
insert into public.asset_category (id, tenant_id, name) values
  ('00000000-0000-0000-0000-0000000091c1', '00000000-0000-0000-0000-00000000000a', 'S91 Pumps'),
  ('00000000-0000-0000-0000-0000000091cb', '00000000-0000-0000-0000-00000000000b', 'S91 B cat');
insert into public.asset (id, tenant_id, tag, name, category_id, location_id) values
  ('00000000-0000-0000-0000-0000000091a1', '00000000-0000-0000-0000-00000000000a', 'S91-X', 'Pump X', '00000000-0000-0000-0000-0000000091c1', '00000000-0000-0000-0000-0000000091e1'),
  ('00000000-0000-0000-0000-0000000091a2', '00000000-0000-0000-0000-00000000000a', 'S91-Y', 'Pump Y', '00000000-0000-0000-0000-0000000091c1', '00000000-0000-0000-0000-0000000091e2'),
  ('00000000-0000-0000-0000-0000000091a3', '00000000-0000-0000-0000-00000000000a', 'S91-Z', 'Pump Z', '00000000-0000-0000-0000-0000000091c1', '00000000-0000-0000-0000-0000000091e1'),
  ('00000000-0000-0000-0000-0000000091ab', '00000000-0000-0000-0000-00000000000b', 'S91-B', 'B pump', '00000000-0000-0000-0000-0000000091cb', null);
insert into public.scope_profile (id, tenant_id, name) values
  ('00000000-0000-0000-0000-0000000091f1', '00000000-0000-0000-0000-00000000000a', 'S91 Pune');
insert into public.scope_profile_rule (tenant_id, scope_profile_id, dimension, location_id, category_id) values
  ('00000000-0000-0000-0000-00000000000a', '00000000-0000-0000-0000-0000000091f1', 'location', '00000000-0000-0000-0000-0000000091e1', null);
-- a1 in A: obligation view and update, scoped to Pune. No coverage grant. a2 in B: obligation, tenant-wide.
insert into public.security_group (id, tenant_id, code, name, group_type) values
  ('00000000-0000-0000-0000-0000000091b1', '00000000-0000-0000-0000-00000000000a', 's91_1', 'S91 planners', 'role');
insert into public.group_domain_policy (tenant_id, security_group_id, domain_operation_id)
select '00000000-0000-0000-0000-00000000000a', '00000000-0000-0000-0000-0000000091b1', o.id
from public.domain_operation o join public.security_domain d on d.id = o.security_domain_id
where d.code = 'obligation' and o.code in ('view', 'update');
insert into public.user_group_assignment (tenant_id, user_id, security_group_id, scope_profile_id) values
  ('00000000-0000-0000-0000-00000000000a', '00000000-0000-0000-0000-0000000000a1', '00000000-0000-0000-0000-0000000091b1', '00000000-0000-0000-0000-0000000091f1');
select tests.grant('00000000-0000-0000-0000-00000000000b', '00000000-0000-0000-0000-0000000000a2', 'obligation', array['view', 'update']);

-- 1. Coverage events (N3). Z: warranty active, then expiring, then out. A new asset already expiring: none.
insert into public.vendor (id, tenant_id, name, roles, is_active) values
  ('00000000-0000-0000-0000-0000000091d1', '00000000-0000-0000-0000-00000000000a', 'S91 OEM', '{oem}', true);
insert into public.coverage (id, tenant_id, coverage_type, vendor_id, start_date, end_date) values
  ('00000000-0000-0000-0000-000000009101', '00000000-0000-0000-0000-00000000000a', 'warranty', '00000000-0000-0000-0000-0000000091d1', pg_temp.d(-10), pg_temp.d(300)),
  ('00000000-0000-0000-0000-000000009102', '00000000-0000-0000-0000-00000000000a', 'warranty', '00000000-0000-0000-0000-0000000091d1', pg_temp.d(-10), pg_temp.d(5));
insert into public.coverage_asset (tenant_id, coverage_id, asset_id) values
  ('00000000-0000-0000-0000-00000000000a', '00000000-0000-0000-0000-000000009101', '00000000-0000-0000-0000-0000000091a3'),
  ('00000000-0000-0000-0000-00000000000a', '00000000-0000-0000-0000-000000009102', '00000000-0000-0000-0000-0000000091a2');
select is((select count(*) from private.outbox_event where event_type like 'coverage.%'
           and aggregate_id in ('00000000-0000-0000-0000-0000000091a2', '00000000-0000-0000-0000-0000000091a3')), 0::bigint,
  'none -> active or none -> expiring: no event (new links, imports)');
update public.coverage set end_date = pg_temp.d(10) where id = '00000000-0000-0000-0000-000000009101';
select is((select count(*) from private.outbox_event where event_type = 'coverage.expiring' and aggregate_id = '00000000-0000-0000-0000-0000000091a3'), 1::bigint,
  'active -> expiring: one coverage.expiring event');
select is((select payload ->> 'end_date' from private.outbox_event where event_type = 'coverage.expiring' and aggregate_id = '00000000-0000-0000-0000-0000000091a3'),
  pg_temp.d(10)::text, 'payload carries the end date');
update public.coverage set end_date = pg_temp.d(-1) where id = '00000000-0000-0000-0000-000000009101';
select is((select count(*) from private.outbox_event where event_type = 'coverage.expired' and aggregate_id = '00000000-0000-0000-0000-0000000091a3'), 1::bigint,
  'expiring -> out: one coverage.expired event');
update public.coverage set end_date = pg_temp.d(-2) where id = '00000000-0000-0000-0000-000000009101';
select is((select count(*) from private.outbox_event where event_type like 'coverage.%' and aggregate_id = '00000000-0000-0000-0000-0000000091a3'), 2::bigint,
  'out -> out: no second event');

-- 2. Fan-out (N1, N2, N3). Clear older events, then fixture events.
update private.outbox_event set published_at = now() where published_at is null;
insert into private.outbox_event (id, tenant_id, event_type, aggregate_type, aggregate_id, payload) values
  ('00000000-0000-0000-0000-0000000091e1', '00000000-0000-0000-0000-00000000000a', 'obligation.overdue', 'obligation', gen_random_uuid(),
   '{"asset_id": "00000000-0000-0000-0000-0000000091a1", "name": "Service", "next_due_date": "2026-11-01"}'),
  ('00000000-0000-0000-0000-0000000091e2', '00000000-0000-0000-0000-00000000000a', 'obligation.overdue', 'obligation', gen_random_uuid(),
   '{"asset_id": "00000000-0000-0000-0000-0000000091a2", "name": "Service"}'),
  ('00000000-0000-0000-0000-0000000091e3', '00000000-0000-0000-0000-00000000000a', 'coverage.expiring', 'asset', '00000000-0000-0000-0000-0000000091a1',
   '{"asset_id": "00000000-0000-0000-0000-0000000091a1", "end_date": "2026-12-01"}'),
  ('00000000-0000-0000-0000-0000000091e4', '00000000-0000-0000-0000-00000000000b', 'obligation.due_soon', 'obligation', gen_random_uuid(),
   '{"asset_id": "00000000-0000-0000-0000-0000000091ab", "name": "B service"}'),
  ('00000000-0000-0000-0000-0000000091e5', '00000000-0000-0000-0000-00000000000a', 'asset.update', 'asset', '00000000-0000-0000-0000-0000000091a1', '{}'),
  ('00000000-0000-0000-0000-0000000091e6', '00000000-0000-0000-0000-00000000000a', 'obligation.overdue', 'obligation', gen_random_uuid(),
   '{"asset_id": "not-a-uuid"}');
select is(private.fan_out_events(), 4, 'fan-out handles the four good alert events');
select is(pg_temp.n('00000000-0000-0000-0000-0000000000a1', '00000000-0000-0000-0000-0000000091e1'), 1::bigint,
  'a1 is told: holds obligation.update, asset in scope');
select is(pg_temp.n('00000000-0000-0000-0000-0000000000a1', '00000000-0000-0000-0000-0000000091e2'), 0::bigint,
  'a1 is not told about an asset out of scope (6.1)');
select is(pg_temp.n('00000000-0000-0000-0000-0000000000a1', '00000000-0000-0000-0000-0000000091e3'), 0::bigint,
  'a1 is not told about coverage: no coverage_contract.update');
select is(pg_temp.n('00000000-0000-0000-0000-0000000000a1', '00000000-0000-0000-0000-0000000091e4'), 0::bigint,
  'a1 is not told about tenant B: no grant there');
select is(pg_temp.n('00000000-0000-0000-0000-0000000000a2', '00000000-0000-0000-0000-0000000091e4'), 1::bigint, 'a2 is told in tenant B');
select is((select count(*) from public.notification where event_id = '00000000-0000-0000-0000-0000000091e4' and tenant_id <> '00000000-0000-0000-0000-00000000000b'),
  0::bigint, 'a tenant B event never lands in another tenant');
select is((select payload ->> 'asset_name' from public.notification where event_id = '00000000-0000-0000-0000-0000000091e1' and user_id = '00000000-0000-0000-0000-0000000000a1'),
  'Pump X', 'payload snapshot adds the asset name');
select isnt((select published_at from private.outbox_event where id = '00000000-0000-0000-0000-0000000091e5'), null,
  'an event with no consumer is marked published');
select results_eq($$select attempts, last_error is not null, published_at is null from private.outbox_event where id = '00000000-0000-0000-0000-0000000091e6'$$,
  $$values (1, true, true)$$, 'a bad event gets attempts and last_error and stays unpublished');
update private.outbox_event set published_at = null where id = '00000000-0000-0000-0000-0000000091e1';
select is(private.fan_out_events(), 1, 'a re-run takes the event again');
select is(pg_temp.n('00000000-0000-0000-0000-0000000000a1', '00000000-0000-0000-0000-0000000091e1'), 1::bigint, 'and never doubles (N2)');
update private.outbox_event set attempts = 5 where id = '00000000-0000-0000-0000-0000000091e6';
select is(private.fan_out_events(), 0, 'after 5 attempts a bad event is skipped');

-- End to end: a real overdue obligation on X, through the 5.1 state trigger.
insert into public.obligation (tenant_id, asset_id, name, obligation_type, interval_count, interval_unit, anchor, first_due_date)
values ('00000000-0000-0000-0000-00000000000a', '00000000-0000-0000-0000-0000000091a1', 'S91 overdue', 'service', 1, 'month', 'fixed', pg_temp.d(-3));
select is(private.fan_out_events(), 1, 'the state job event is fanned out');
select is((select count(*) from public.notification where user_id = '00000000-0000-0000-0000-0000000000a1'
           and event_type = 'obligation.overdue' and payload ->> 'name' = 'S91 overdue'), 1::bigint, 'a1 gets the real overdue alert');

-- 3. Inbox RLS (N4).
select tests.act_as('00000000-0000-0000-0000-0000000000a1', '00000000-0000-0000-0000-00000000000a');
select is((select count(*) from public.notification), 2::bigint, 'a1 in A sees only own rows');
select is((select count(*) from public.notification where user_id <> '00000000-0000-0000-0000-0000000000a1'), 0::bigint, 'no other user''s rows');
with u as (update public.notification set read_at = now() where event_id = '00000000-0000-0000-0000-0000000091e1' returning 1) select is(count(*), 1::bigint, 'a1 marks own alert read') from u;
select throws_ok($$update public.notification set payload = '{}'$$, '42501', null, 'no update right on payload');
select throws_ok($$insert into public.notification (tenant_id, user_id, event_id, event_type, domain, asset_id, payload)
  values ('00000000-0000-0000-0000-00000000000a', '00000000-0000-0000-0000-0000000000a1', gen_random_uuid(), 'x', 'obligation',
          '00000000-0000-0000-0000-0000000091a1', '{}')$$, '42501', null, 'users cannot insert');
select throws_ok($$delete from public.notification$$, '42501', null, 'users cannot delete');
select tests.act_as('00000000-0000-0000-0000-0000000000a1', '00000000-0000-0000-0000-00000000000b');
select is((select count(*) from public.notification), 0::bigint, 'a1 with tenant B active sees none of tenant A');
select tests.act_as('00000000-0000-0000-0000-0000000000a2', '00000000-0000-0000-0000-00000000000b');
select is((select count(*) from public.notification), 1::bigint, 'a2 in B sees own row');
with u as (update public.notification set read_at = now() where tenant_id = '00000000-0000-0000-0000-00000000000a' returning 1) select is(count(*), 0::bigint, 'a2 cannot touch tenant A rows') from u;
with u as (update public.notification set read_at = now() returning 1) select is(count(*), 1::bigint, 'a read-only tenant can still mark read') from u;
select tests.act_as('00000000-0000-0000-0000-0000000000a1', '00000000-0000-0000-0000-00000000000a');
select pg_temp.back();
update public.asset set location_id = '00000000-0000-0000-0000-0000000091e2' where id = '00000000-0000-0000-0000-0000000091a1';
select tests.act_as('00000000-0000-0000-0000-0000000000a1', '00000000-0000-0000-0000-00000000000a');
select is((select count(*) from public.notification), 0::bigint, 'asset moved out of scope: its alerts are hidden');
select pg_temp.back();
update public.asset set location_id = '00000000-0000-0000-0000-0000000091e1' where id = '00000000-0000-0000-0000-0000000091a1';
set local role anon;
select throws_ok($$select 1 from public.notification$$, '42501', null, 'anon has no access');
select pg_temp.back();

-- 4. Email switch (N7).
select tests.act_as('00000000-0000-0000-0000-0000000000a1', '00000000-0000-0000-0000-00000000000a');
select is(public.set_email_digest(false), false, 'a1 turns the summary off');
select pg_temp.back();
select results_eq($$select tenant_id::text, email_digest from public.tenant_membership where user_id = '00000000-0000-0000-0000-0000000000a1' order by tenant_id$$,
  $$values ('00000000-0000-0000-0000-00000000000a', false), ('00000000-0000-0000-0000-00000000000b', true)$$,
  'only the active tenant''s switch changes');

-- 5. Daily summary queue (N6). Kolkata is UTC+5:30.
update public.notification set read_at = null, emailed_on = null;
select is((select count(*) from private.notification_email), 0::bigint, 'no summary rows yet');
select private.queue_email_digests('2026-11-05 03:00Z');
select is((select count(*) from private.notification_email where user_id = '00000000-0000-0000-0000-0000000000a1'), 0::bigint,
  'switch off: no summary for a1');
update public.tenant_membership set email_digest = true where user_id = '00000000-0000-0000-0000-0000000000a1';
select private.queue_email_digests('2026-11-05 01:00Z');
select is((select count(*) from private.notification_email where user_id = '00000000-0000-0000-0000-0000000000a1'), 0::bigint,
  '06:30 in Kolkata: too early');
select private.queue_email_digests('2026-11-05 03:00Z');
select is((select digest_date from private.notification_email where user_id = '00000000-0000-0000-0000-0000000000a1'), '2026-11-05'::date,
  '08:30 in Kolkata: one summary row for the local day');
select is((select count(*) from public.notification where user_id = '00000000-0000-0000-0000-0000000000a1' and emailed_on = '2026-11-05'), 2::bigint,
  'its alerts are stamped');
insert into public.notification (tenant_id, user_id, event_id, event_type, domain, asset_id, payload) values
  ('00000000-0000-0000-0000-00000000000a', '00000000-0000-0000-0000-0000000000a1', gen_random_uuid(), 'obligation.due_soon', 'obligation',
   '00000000-0000-0000-0000-0000000091a1', '{"name": "Late"}');
select private.queue_email_digests('2026-11-05 09:00Z');
select is((select emailed_on from public.notification where user_id = '00000000-0000-0000-0000-0000000000a1' and payload ->> 'name' = 'Late'),
  null, 'a later alert waits for tomorrow''s summary');

-- 6. Claim and finish (N2).
select is((select jsonb_array_length(lines) from private.claim_emails(50) where email = 'test.user@example.com'), 2,
  'claim returns a1''s summary with its two lines');
select is((select count(*) from private.claim_emails(50) where email = 'test.user@example.com'), 0::bigint, 'a claimed row is not claimed twice');
select private.finish_email((select id from private.notification_email where user_id = '00000000-0000-0000-0000-0000000000a1'), null, 'timeout');
select results_eq($$select status, attempts, next_try_at > now() from private.notification_email where user_id = '00000000-0000-0000-0000-0000000000a1'$$,
  $$values ('pending'::text, 1, true)$$, 'a failure goes back to pending with a backoff');
update private.notification_email set next_try_at = now() - interval '1 second';
select count(*) from private.claim_emails(50);
select private.finish_email((select id from private.notification_email where user_id = '00000000-0000-0000-0000-0000000000a1'), 'prov-1', null);
select results_eq($$select status, provider_id from private.notification_email where user_id = '00000000-0000-0000-0000-0000000000a1'$$,
  $$values ('sent'::text, 'prov-1'::text)$$, 'a send is recorded with the provider id');
-- Lines lost on the way (switch off): the row is skipped, not sent.
insert into private.notification_email (tenant_id, user_id, digest_date) values
  ('00000000-0000-0000-0000-00000000000a', '00000000-0000-0000-0000-0000000000a1', '2026-11-06');
update public.notification set emailed_on = '2026-11-06' where user_id = '00000000-0000-0000-0000-0000000000a1' and payload ->> 'name' = 'Late';
update public.tenant_membership set email_digest = false where user_id = '00000000-0000-0000-0000-0000000000a1';
select is((select count(*) from private.claim_emails(50) where email = 'test.user@example.com'), 0::bigint, 'nothing to send');
select is((select status from private.notification_email where user_id = '00000000-0000-0000-0000-0000000000a1' and digest_date = '2026-11-06'),
  'skipped', 'the row is skipped');

-- 7. The jobs role (N10): two functions, nothing else.
select ok(has_function_privilege('assetly_jobs', 'private.claim_emails(integer)', 'execute')
      and has_function_privilege('assetly_jobs', 'private.finish_email(uuid, text, text)', 'execute'), 'assetly_jobs runs claim and finish');
select ok(not has_function_privilege('assetly_jobs', 'private.fan_out_events(integer)', 'execute')
      and not has_table_privilege('assetly_jobs', 'public.asset', 'select')
      and not has_table_privilege('assetly_jobs', 'public.notification', 'select')
      and not has_table_privilege('assetly_jobs', 'private.notification_email', 'select'), 'and nothing else');
select ok(not has_function_privilege('authenticated', 'private.claim_emails(integer)', 'execute')
      and not has_function_privilege('authenticated', 'private.fan_out_events(integer)', 'execute')
      and not has_function_privilege('authenticated', 'private.user_can(uuid, uuid, text, text, uuid)', 'execute'), 'users cannot run the job functions');

select * from finish();
rollback;
