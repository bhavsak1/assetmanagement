-- Story 1.5: audit_log and outbox_event, written by private.audit_row() in the same transaction.
-- Uses the seed (tenant A active, B read_only; a1 in A and B) and supabase/test_harness.sql.
begin;
select plan(28);

select policies_are('public', 'audit_log', array['audit_log_select']);
select ok(not has_table_privilege('authenticated', 'public.audit_log', 'insert,update,delete,truncate'), 'no write grants on audit_log');
select ok(not has_table_privilege('authenticated', 'private.outbox_event', 'select'), 'users cannot read outbox_event');

-- a1 may create, edit and delete rls_sample rows in A, and read data audit rows.
select tests.grant('00000000-0000-0000-0000-00000000000a', '00000000-0000-0000-0000-0000000000a1', 'rls_sample');
select tests.grant('00000000-0000-0000-0000-00000000000a', '00000000-0000-0000-0000-0000000000a1', 'audit_log');

-- Insert, update and soft delete: one audit row and one outbox row each.
select tests.act_as('00000000-0000-0000-0000-0000000000a1', '00000000-0000-0000-0000-00000000000a');
insert into public.rls_sample (id, tenant_id, name)
values ('00000000-0000-0000-0000-0000000015a1', '00000000-0000-0000-0000-00000000000a', 'audit-me');
update public.rls_sample set name = 'audit-me-2' where id = '00000000-0000-0000-0000-0000000015a1';
update public.rls_sample set deleted_at = now() where id = '00000000-0000-0000-0000-0000000015a1';

reset role;
select results_eq(
  $$select action, category, actor_type, actor_user_id, table_name from public.audit_log
    where record_id = '00000000-0000-0000-0000-0000000015a1' order by occurred_at$$,
  -- occurred_at is the write time since 3.4, so rows of one transaction keep their order.
  $$values ('insert', 'data', 'user', '00000000-0000-0000-0000-0000000000a1'::uuid, 'rls_sample'),
           ('update', 'data', 'user', '00000000-0000-0000-0000-0000000000a1'::uuid, 'rls_sample'),
           ('soft_delete', 'data', 'user', '00000000-0000-0000-0000-0000000000a1'::uuid, 'rls_sample')$$,
  'insert, update and soft delete each write one audit row'
);
select results_eq(
  $$select event_type from private.outbox_event
    where aggregate_id = '00000000-0000-0000-0000-0000000015a1' order by event_type$$,
  $$values ('rls_sample.insert'), ('rls_sample.soft_delete'), ('rls_sample.update')$$,
  'insert, update and soft delete each write one outbox event'
);
select is(
  (select old_data - 'updated_at' from public.audit_log
   where record_id = '00000000-0000-0000-0000-0000000015a1' and action = 'update'),
  '{"name": "audit-me"}'::jsonb, 'update keeps only the changed columns (old)'
);
select is(
  (select new_data ->> 'name' from public.audit_log
   where record_id = '00000000-0000-0000-0000-0000000015a1' and action = 'update'),
  'audit-me-2', 'update keeps only the changed columns (new)'
);
select is(
  (select count(*)::int from public.audit_log a join private.outbox_event e on e.aggregate_id = a.record_id
   where a.record_id = '00000000-0000-0000-0000-0000000015a1' and a.transaction_id <> txid_current()),
  0, 'audit and outbox rows are in the same transaction as the change'
);

-- A change that fails after the row is written leaves neither row.
select tests.act_as('00000000-0000-0000-0000-0000000000a1', '00000000-0000-0000-0000-00000000000a');
select throws_ok(
  $sql$do $x$ begin
      insert into public.rls_sample (id, tenant_id, name)
      values ('00000000-0000-0000-0000-0000000015a2', '00000000-0000-0000-0000-00000000000a', 'rolled-back');
      raise exception 'boom';
    end $x$$sql$,
  'P0001', 'boom', 'a failing change raises'
);
-- A refused change (no permission) leaves neither row.
select throws_ok(
  $$insert into public.rls_sample (id, tenant_id, name)
    values ('00000000-0000-0000-0000-0000000015b1', '00000000-0000-0000-0000-00000000000b', 'refused')$$,
  '42501', null, 'a refused change raises'
);
reset role;
select is((select count(*)::int from public.audit_log
           where record_id in ('00000000-0000-0000-0000-0000000015a2', '00000000-0000-0000-0000-0000000015b1')),
          0, 'failed changes write no audit row');
select is((select count(*)::int from private.outbox_event
           where aggregate_id in ('00000000-0000-0000-0000-0000000015a2', '00000000-0000-0000-0000-0000000015b1')),
          0, 'failed changes write no outbox event');

-- Reads: data rows with audit_log.view, security rows only with users_security.view.
select tests.act_as('00000000-0000-0000-0000-0000000000a1', '00000000-0000-0000-0000-00000000000a');
select is((select count(*)::int from public.audit_log where record_id = '00000000-0000-0000-0000-0000000015a1'),
          3, 'audit_log.view reads data rows');
select is((select count(*)::int from public.audit_log where category = 'security'), 0, 'audit_log.view does not read security rows');

-- Append-only, even for the row's own tenant.
select throws_ok(
  $$update public.audit_log set reason = 'x' where record_id = '00000000-0000-0000-0000-0000000015a1'$$,
  '42501', null, 'user cannot update own tenant audit rows'
);
select throws_ok(
  $$delete from public.audit_log where record_id = '00000000-0000-0000-0000-0000000015a1'$$,
  '42501', null, 'user cannot delete own tenant audit rows'
);
reset role;
select throws_ok($$update public.audit_log set reason = 'x'$$, 'P0001', 'audit_log is append-only', 'owner cannot update audit rows');
select throws_ok($$delete from public.audit_log$$, 'P0001', 'audit_log is append-only', 'owner cannot delete audit rows');
select throws_ok($$truncate public.audit_log$$, 'P0001', 'audit_log is append-only', 'owner cannot truncate audit_log');

-- A security change by a security admin is a security audit row.
select tests.grant('00000000-0000-0000-0000-00000000000a', '00000000-0000-0000-0000-0000000000a1', 'users_security');
select tests.act_as('00000000-0000-0000-0000-0000000000a1', '00000000-0000-0000-0000-00000000000a');
insert into public.user_group_assignment (id, tenant_id, user_id, security_group_id)
select '00000000-0000-0000-0000-0000000015c1', tenant_id, '00000000-0000-0000-0000-0000000000a1', id
from public.security_group limit 1;
select results_eq(
  $$select category, action, actor_user_id from public.audit_log where record_id = '00000000-0000-0000-0000-0000000015c1'$$,
  $$values ('security', 'insert', '00000000-0000-0000-0000-0000000000a1'::uuid)$$,
  'group assignment is audited as security, and users_security.view reads it'
);

-- Cross-tenant harness: 8 tests.
reset role;
select * from tests.cross_tenant('public.audit_log', 'audit_log',
  '{"category":"data","actor_type":"system","action":"insert","table_name":"ct","record_id":"00000000-0000-0000-0000-0000000015d1"}');

select * from finish();
rollback;
