-- Story 6.4: draft, review and activate change sets (docs/data-model-goal6.md §30).
-- Uses the seed: tenant A (...0a, active) with one user per starter group (admin.a ...a0001 is the only one with
-- users_security.manage, auditor.a ...a0005 has view, ...a0002 has no security grant), test.user a1 in A and B
-- with no groups, tenant B (...0b, read_only).
begin;
select plan(68);

-- Fixtures, as postgres. G1 is assigned to a1 with no grants; G2 is unassigned; G3 is deleted later; S is system.
insert into public.security_group (id, tenant_id, code, name, group_type) values
  ('00000000-0000-0000-0000-0000000064b1', '00000000-0000-0000-0000-00000000000a', 's64_1', 'S64 one', 'role'),
  ('00000000-0000-0000-0000-0000000064b2', '00000000-0000-0000-0000-00000000000a', 's64_2', 'S64 two', 'role'),
  ('00000000-0000-0000-0000-0000000064b3', '00000000-0000-0000-0000-00000000000a', 's64_3', 'S64 three', 'role'),
  ('00000000-0000-0000-0000-0000000064b4', '00000000-0000-0000-0000-00000000000a', 's64_sys', 'S64 system', 'system'),
  ('00000000-0000-0000-0000-0000000064bb', '00000000-0000-0000-0000-00000000000b', 's64_b', 'S64 B', 'role');
insert into public.user_group_assignment (tenant_id, user_id, security_group_id) values
  ('00000000-0000-0000-0000-00000000000a', '00000000-0000-0000-0000-0000000000a1', '00000000-0000-0000-0000-0000000064b1');
-- Closed sets for the item cross-tenant check (an open draft would clash with the harness's own insert).
insert into public.policy_change_set (id, tenant_id, status) values
  ('00000000-0000-0000-0000-0000000064ca', '00000000-0000-0000-0000-00000000000a', 'discarded'),
  ('00000000-0000-0000-0000-0000000064cb', '00000000-0000-0000-0000-00000000000b', 'discarded');

create function pg_temp.at_commit(p_sql text) returns void language plpgsql as $$
begin
  execute p_sql;
  set constraints all immediate;
  set constraints all deferred;
end;
$$;
create function pg_temp.ops(p_domain text, p_ops text[]) returns uuid[] language sql as $$
  select coalesce(array_agg(o.id), '{}') from public.domain_operation o
  join public.security_domain d on d.id = o.security_domain_id where d.code = p_domain and o.code = any (p_ops);
$$;
create function pg_temp.live(p_group uuid) returns setof text language sql as $$
  select o.code from public.group_domain_policy p join public.domain_operation o on o.id = p.domain_operation_id
  where p.security_group_id = p_group and p.deleted_at is null order by o.code;
$$;
create function pg_temp.draft() returns uuid language sql as $$
  select id from public.policy_change_set where status = 'draft';
$$;
create function pg_temp.version(p_user uuid) returns int language sql as $$
  select permission_version from public.tenant_membership
  where tenant_id = '00000000-0000-0000-0000-00000000000a' and user_id = p_user;
$$;
create temp table v0 as select pg_temp.version('00000000-0000-0000-0000-0000000000a1') as v;
grant select on v0 to authenticated;

select ok(not has_function_privilege('anon', 'public.activate_change_set(uuid)', 'execute'), 'anon cannot activate');
select ok(not has_function_privilege('authenticated', 'private.check_security_manage()', 'execute'), 'the check helper is not callable');

-- No security grant.
select tests.act_as('00000000-0000-0000-0000-0000000a0002', '00000000-0000-0000-0000-00000000000a');
select throws_ok($$select public.set_group_policies('00000000-0000-0000-0000-0000000064b1', pg_temp.ops('asset_core', '{view}'))$$,
  '42501', 'not allowed', 'draft: refused without manage');

-- Live grants and draft tables are not writable directly [C2].
select tests.act_as('00000000-0000-0000-0000-0000000a0001', '00000000-0000-0000-0000-00000000000a');
select throws_ok($$insert into public.group_domain_policy (tenant_id, security_group_id, domain_operation_id)
    values ('00000000-0000-0000-0000-00000000000a', '00000000-0000-0000-0000-0000000064b1', (pg_temp.ops('asset_core', '{view}'))[1])$$,
  '42501', null, 'live: a manager cannot insert a grant directly');
select is_empty($$update public.group_domain_policy set deleted_at = now() where tenant_id = '00000000-0000-0000-0000-00000000000a' returning 1$$,
  'live: a manager cannot revoke a grant directly');
select throws_ok($$insert into public.policy_change_set (tenant_id) values ('00000000-0000-0000-0000-00000000000a')$$,
  '42501', null, 'draft: no direct insert of a change set');
select throws_ok($$update public.policy_change_set set status = 'activated'$$,
  '42501', null, 'draft: no direct update of a change set');
select throws_ok($$insert into public.policy_change_set_item (tenant_id, policy_change_set_id, security_group_id, operation_ids)
    values ('00000000-0000-0000-0000-00000000000a', '00000000-0000-0000-0000-0000000064ca', '00000000-0000-0000-0000-0000000064b1', '{}')$$,
  '42501', null, 'draft: no direct insert of an item');

-- Drafting.
select lives_ok($$select public.set_group_policies('00000000-0000-0000-0000-0000000064b1', pg_temp.ops('asset_core', '{view,update}'))$$,
  'draft: admin saves G1');
select is((select count(*) from public.policy_change_set where status = 'draft'), 1::bigint, 'draft: one open draft');
select is((select created_by from public.policy_change_set where id = pg_temp.draft()), '00000000-0000-0000-0000-0000000a0001'::uuid,
  'draft: drafter recorded');
select is_empty($$select pg_temp.live('00000000-0000-0000-0000-0000000064b1')$$, 'draft: live grants unchanged');
select ok(not exists (select 1 from public.policy_change_set_item where security_group_id = '00000000-0000-0000-0000-0000000064b1' and before_ids is not null),
  'draft: no before set yet');
select results_eq($$select operation_code || ' ' || change from public.change_set_diff(pg_temp.draft())$$,
  array['view add', 'update add'], 'diff: two adds, in operation order');
select lives_ok($$select public.set_group_policies('00000000-0000-0000-0000-0000000064b2', pg_temp.ops('vendor_core', '{view}'))$$,
  'draft: admin saves G2');
select is((select count(*) from public.policy_change_set where status = 'draft'), 1::bigint, 'draft: still one draft (shared)');
select is((select count(*) from public.policy_change_set_item where policy_change_set_id = pg_temp.draft() and deleted_at is null),
  2::bigint, 'draft: two items');
select lives_ok($$select public.set_group_policies('00000000-0000-0000-0000-0000000064b2', pg_temp.ops('vendor_core', '{view,update}'))$$,
  'draft: G2 saved again');
select is((select count(*) from public.policy_change_set_item where security_group_id = '00000000-0000-0000-0000-0000000064b2' and deleted_at is null),
  1::bigint, 'draft: saving again replaces the item');
select lives_ok($$select public.set_group_policies('00000000-0000-0000-0000-0000000064b2', '{}')$$, 'draft: G2 back to its live set');
select is((select count(*) from public.policy_change_set_item where policy_change_set_id = pg_temp.draft() and deleted_at is null),
  1::bigint, 'draft: saving the live set removes the item (revert)');
select throws_ok($$select public.set_group_policies('00000000-0000-0000-0000-0000000064b4', pg_temp.ops('asset_core', '{view}'))$$,
  '42501', 'system groups cannot be edited', 'draft: system group refused');
select throws_ok($$select public.set_group_policies('00000000-0000-0000-0000-0000000064bb', '{}')$$,
  'P0002', 'group not found', 'draft: another tenant''s group is not found');

-- A group deleted after it was drafted drops out [C6].
select lives_ok($$select public.set_group_policies('00000000-0000-0000-0000-0000000064b3', pg_temp.ops('asset_core', '{view}'))$$,
  'draft: admin saves G3');
update public.security_group set deleted_at = now() where id = '00000000-0000-0000-0000-0000000064b3';
select ok(not exists (select 1 from public.change_set_diff(pg_temp.draft()) where group_name = 'S64 three'),
  'diff: a deleted group is hidden');

reset role;
select is((select count(*) from private.user_effective_permission
           where tenant_id = '00000000-0000-0000-0000-00000000000a' and user_id = '00000000-0000-0000-0000-0000000000a1'),
  0::bigint, 'draft: the member gains nothing yet');
select is(pg_temp.version('00000000-0000-0000-0000-0000000000a1'), (select v from v0), 'draft: permission_version unchanged');

-- View-only and no-grant users.
select tests.act_as('00000000-0000-0000-0000-0000000a0005', '00000000-0000-0000-0000-00000000000a');
select is((select count(*) from public.change_set_diff(pg_temp.draft())), 2::bigint, 'auditor: reads the diff');
select throws_ok($$select public.activate_change_set(pg_temp.draft())$$, '42501', 'not allowed', 'auditor: cannot activate');
select throws_ok($$select public.discard_change_set(pg_temp.draft())$$, '42501', 'not allowed', 'auditor: cannot discard');
select tests.act_as('00000000-0000-0000-0000-0000000a0002', '00000000-0000-0000-0000-00000000000a');
select is_empty($$select * from public.policy_change_set$$, 'no grant: sees no change set');

-- Activate [C3: the drafter may activate].
reset role;
create temp table cs1 as select id from public.policy_change_set where status = 'draft';
grant select on cs1 to authenticated;
select tests.act_as('00000000-0000-0000-0000-0000000a0001', '00000000-0000-0000-0000-00000000000a');
select lives_ok($$select pg_temp.at_commit('select public.activate_change_set((select id from cs1))')$$, 'activate: the drafter activates');
select results_eq($$select pg_temp.live('00000000-0000-0000-0000-0000000064b1')$$, array['update', 'view'], 'activate: G1 grants are live');
select is_empty($$select pg_temp.live('00000000-0000-0000-0000-0000000064b3')$$, 'activate: the deleted group got nothing');
select results_eq($$select status, activated_by from public.policy_change_set where id = (select id from cs1)$$,
  $$values ('activated'::text, '00000000-0000-0000-0000-0000000a0001'::uuid)$$, 'activate: status and activator set');
select is((select before_ids from public.policy_change_set_item where policy_change_set_id = (select id from cs1) and deleted_at is null),
  '{}'::uuid[], 'activate: before set stored');
select is((select count(*) from public.policy_change_set_item where policy_change_set_id = (select id from cs1) and deleted_at is not null
           and security_group_id = '00000000-0000-0000-0000-0000000064b3'), 1::bigint, 'activate: the deleted group''s item is closed');
select results_eq($$select operation_code || ' ' || change from public.change_set_diff((select id from cs1))$$,
  array['view add', 'update add'], 'history: the diff still shows what was applied');
select throws_ok($$select public.activate_change_set((select id from cs1))$$, 'P0002', 'change set is not an open draft',
  'activate: twice is refused');
select ok(pg_temp.draft() is null, 'activate: no open draft left');
reset role;
select is((select count(*) from private.user_effective_permission
           where tenant_id = '00000000-0000-0000-0000-00000000000a' and user_id = '00000000-0000-0000-0000-0000000000a1'),
  2::bigint, 'activate: the member is rebuilt');
select ok(pg_temp.version('00000000-0000-0000-0000-0000000000a1') > (select v from v0), 'activate: permission_version moves');
select ok(exists (select 1 from public.audit_log where table_name = 'policy_change_set' and record_id = (select id from cs1)
                  and category = 'security' and new_data ->> 'status' = 'activated'), 'activate: audited');

-- Discard.
select tests.act_as('00000000-0000-0000-0000-0000000a0001', '00000000-0000-0000-0000-00000000000a');
select lives_ok($$select public.set_group_policies('00000000-0000-0000-0000-0000000064b1', pg_temp.ops('asset_core', '{view}'))$$,
  'discard: a fresh draft opens');
select lives_ok($$select public.discard_change_set(pg_temp.draft())$$, 'discard: admin discards');
select results_eq($$select pg_temp.live('00000000-0000-0000-0000-0000000064b1')$$, array['update', 'view'], 'discard: nothing applied');
select throws_ok($$select public.discard_change_set((select id from public.policy_change_set where status = 'discarded' order by created_at desc limit 1))$$,
  'P0002', 'change set is not an open draft', 'discard: a closed set cannot be discarded');

-- Lock-out at activation: the whole activation rolls back and the draft stays.
create function pg_temp.admin_ops_without_manage() returns uuid[] language sql as $q$
  select array_agg(p.domain_operation_id) from public.group_domain_policy p
  join public.security_group g on g.id = p.security_group_id
  where g.tenant_id = '00000000-0000-0000-0000-00000000000a' and g.code = 'tenant_admin' and p.deleted_at is null
    and p.domain_operation_id <> all (pg_temp.ops('users_security', '{manage}'));
$q$;
select lives_ok($$select public.set_group_policies(id, pg_temp.admin_ops_without_manage())
    from public.security_group where tenant_id = '00000000-0000-0000-0000-00000000000a' and code = 'tenant_admin'$$,
  'lock-out: drafting the revoke is allowed');
select throws_ok($$select pg_temp.at_commit('select public.activate_change_set(pg_temp.draft())')$$,
  '42501', 'last security admin', 'lock-out: activation refused at commit');
select ok(pg_temp.draft() is not null and private.has_permission('users_security', 'manage'),
  'lock-out: the draft stays open and the admin keeps manage');
select lives_ok($$select public.discard_change_set(pg_temp.draft())$$, 'lock-out: the draft can be discarded');

-- Read-only tenant B.
reset role;
select tests.grant('00000000-0000-0000-0000-00000000000b', '00000000-0000-0000-0000-0000000000a1', 'users_security');
select tests.act_as('00000000-0000-0000-0000-0000000000a1', '00000000-0000-0000-0000-00000000000b');
select throws_ok($$select public.set_group_policies('00000000-0000-0000-0000-0000000064bb', '{}')$$,
  '42501', 'not allowed', 'read_only tenant: cannot draft');

reset role;
select * from tests.cross_tenant('public.policy_change_set', 'users_security', '{}');
select * from tests.cross_tenant('public.policy_change_set_item', 'users_security',
  '{"policy_change_set_id":"00000000-0000-0000-0000-0000000064ca","security_group_id":"00000000-0000-0000-0000-0000000064b1","operation_ids":[]}',
  '{"policy_change_set_id":"00000000-0000-0000-0000-0000000064cb","security_group_id":"00000000-0000-0000-0000-0000000064bb"}');

select * from finish();
rollback;
