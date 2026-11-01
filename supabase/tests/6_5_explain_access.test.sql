-- Story 6.5: the "Why can this user see this?" explainer (docs/data-model-goal6.md §38).
-- Uses the seed: tenant A (...0a, active) with one user per starter group (admin ...a0001, auditor ...a0005 with
-- users_security.view and tenant-wide asset_core.view, plant ...a0002 with no security grant), test.user a1 in
-- A and B with no groups, tenant B (...0b, read_only) with its own starter users (...b000n).
begin;
select plan(29);

-- Fixtures, as postgres. Pune and Mumbai; a Pune pump, a Mumbai pump, an unplaced pump. Profiles Pune and Empty.
insert into public.location (id, tenant_id, parent_id, name) values
  ('00000000-0000-0000-0000-0000000065e1', '00000000-0000-0000-0000-00000000000a', null, 'S65 Pune'),
  ('00000000-0000-0000-0000-0000000065e2', '00000000-0000-0000-0000-00000000000a', '00000000-0000-0000-0000-0000000065e1', 'S65 Pune bay'),
  ('00000000-0000-0000-0000-0000000065e4', '00000000-0000-0000-0000-00000000000a', null, 'S65 Mumbai');
insert into public.asset_category (id, tenant_id, parent_id, name) values
  ('00000000-0000-0000-0000-0000000065c1', '00000000-0000-0000-0000-00000000000a', null, 'S65 Pumps'),
  ('00000000-0000-0000-0000-0000000065c2', '00000000-0000-0000-0000-00000000000a', '00000000-0000-0000-0000-0000000065c1', 'S65 Small pumps');
insert into public.asset (id, tenant_id, tag, name, category_id, location_id) values
  ('00000000-0000-0000-0000-0000000065a1', '00000000-0000-0000-0000-00000000000a', 'S65-P1', 'Pune pump', '00000000-0000-0000-0000-0000000065c1', '00000000-0000-0000-0000-0000000065e2'),
  ('00000000-0000-0000-0000-0000000065a3', '00000000-0000-0000-0000-00000000000a', 'S65-M1', 'Mumbai pump', '00000000-0000-0000-0000-0000000065c1', '00000000-0000-0000-0000-0000000065e4'),
  ('00000000-0000-0000-0000-0000000065a5', '00000000-0000-0000-0000-00000000000a', 'S65-N1', 'Unplaced pump', '00000000-0000-0000-0000-0000000065c1', null);
insert into public.scope_profile (id, tenant_id, name) values
  ('00000000-0000-0000-0000-0000000065f1', '00000000-0000-0000-0000-00000000000a', 'S65 Pune'),
  ('00000000-0000-0000-0000-0000000065f2', '00000000-0000-0000-0000-00000000000a', 'S65 Pune small pumps'),
  ('00000000-0000-0000-0000-0000000065f3', '00000000-0000-0000-0000-00000000000a', 'S65 Empty');
insert into public.scope_profile_rule (tenant_id, scope_profile_id, dimension, location_id, category_id) values
  ('00000000-0000-0000-0000-00000000000a', '00000000-0000-0000-0000-0000000065f1', 'location', '00000000-0000-0000-0000-0000000065e1', null),
  ('00000000-0000-0000-0000-00000000000a', '00000000-0000-0000-0000-0000000065f2', 'location', '00000000-0000-0000-0000-0000000065e1', null),
  ('00000000-0000-0000-0000-00000000000a', '00000000-0000-0000-0000-0000000065f2', 'category', null, '00000000-0000-0000-0000-0000000065c2');
-- Groups for a1: E1 viewer (asset_core.view), E2 updater (asset_core.update), E3 vendors (vendor_core.view).
insert into public.security_group (id, tenant_id, code, name, group_type) values
  ('00000000-0000-0000-0000-0000000065b1', '00000000-0000-0000-0000-00000000000a', 's65_1', 'E1 viewer', 'role'),
  ('00000000-0000-0000-0000-0000000065b2', '00000000-0000-0000-0000-00000000000a', 's65_2', 'E2 updater', 'role'),
  ('00000000-0000-0000-0000-0000000065b3', '00000000-0000-0000-0000-00000000000a', 's65_3', 'E3 vendors', 'role');
insert into public.group_domain_policy (tenant_id, security_group_id, domain_operation_id)
select '00000000-0000-0000-0000-00000000000a', g::uuid, o.id
from (values ('00000000-0000-0000-0000-0000000065b1', 'asset_core', 'view'),
             ('00000000-0000-0000-0000-0000000065b2', 'asset_core', 'update'),
             ('00000000-0000-0000-0000-0000000065b3', 'vendor_core', 'view')) v (g, d, op)
join public.security_domain d on d.code = v.d
join public.domain_operation o on o.security_domain_id = d.id and o.code = v.op;
-- E1 scoped Pune; E1 again scoped Empty (a day earlier, so it sorts first); E2 tenant-wide from next week;
-- E3 scoped Empty (scope does not apply to vendors).
insert into public.user_group_assignment (tenant_id, user_id, security_group_id, scope_profile_id, effective_from) values
  ('00000000-0000-0000-0000-00000000000a', '00000000-0000-0000-0000-0000000000a1', '00000000-0000-0000-0000-0000000065b1', '00000000-0000-0000-0000-0000000065f1', now()),
  ('00000000-0000-0000-0000-00000000000a', '00000000-0000-0000-0000-0000000000a1', '00000000-0000-0000-0000-0000000065b1', '00000000-0000-0000-0000-0000000065f3', now() - interval '1 day'),
  ('00000000-0000-0000-0000-00000000000a', '00000000-0000-0000-0000-0000000000a1', '00000000-0000-0000-0000-0000000065b2', null, now() + interval '7 days'),
  ('00000000-0000-0000-0000-00000000000a', '00000000-0000-0000-0000-0000000000a1', '00000000-0000-0000-0000-0000000065b3', '00000000-0000-0000-0000-0000000065f3', now());

-- "<group or *> <outcome>[ <draft>][ <note>]" per row, the summary last.
create function pg_temp.ex(p_domain text, p_op text, p_asset uuid default null, p_user uuid default '00000000-0000-0000-0000-0000000000a1')
returns setof text language sql as $$
  select concat_ws(' ', coalesce(group_name, '*'), outcome, draft, note)
  from public.explain_access(p_user, p_domain, p_op, p_asset);
$$;
create function pg_temp.ops(p_domain text, p_ops text[]) returns uuid[] language sql as $$
  select coalesce(array_agg(o.id), '{}') from public.domain_operation o
  join public.security_domain d on d.id = o.security_domain_id where d.code = p_domain and o.code = any (p_ops);
$$;
grant execute on all functions in schema pg_temp to authenticated;

select ok(not has_function_privilege('anon', 'public.explain_access(uuid, text, text, uuid)', 'execute'), 'anon cannot explain');
select ok(not has_function_privilege('authenticated', 'private.profile_scope(uuid)', 'execute'), 'profile_scope is not callable');

-- profile_scope matches the 6.1 helper for a1's own Pune grant (Empty gives no row in both).
select tests.act_as('00000000-0000-0000-0000-0000000000a1', '00000000-0000-0000-0000-00000000000a');
reset role;
select results_eq(
  $$select array(select unnest(locs) order by 1), cats from private.profile_scope('00000000-0000-0000-0000-0000000065f1')$$,
  $$select array(select unnest(locs) order by 1), cats from private.scope_rules('asset_core', 'view')$$,
  'profile_scope: same expansion as scope_rules');
select is((select array(select unnest(cats) order by 1) from private.profile_scope('00000000-0000-0000-0000-0000000065f2')),
  array['00000000-0000-0000-0000-0000000065c2'::uuid], 'profile_scope: categories expand down the tree');
select is_empty($$select * from private.profile_scope('00000000-0000-0000-0000-0000000065f3')$$, 'profile_scope: empty profile, no row');

-- Who may run it [E1].
select tests.act_as('00000000-0000-0000-0000-0000000a0002', '00000000-0000-0000-0000-00000000000a');
select is_empty($$select pg_temp.ex('asset_core', 'view')$$, 'no users_security.view: no rows');
select tests.act_as('00000000-0000-0000-0000-0000000a0005', '00000000-0000-0000-0000-00000000000a');
select is_empty($$select pg_temp.ex('asset_core', 'view', null, '00000000-0000-0000-0000-0000000b0003')$$,
  'another tenant''s user: no rows');
select throws_ok($$select pg_temp.ex('asset_core', 'fly')$$, '22023', 'unknown operation', 'unknown operation raises');

-- Outcomes, as the auditor.
select results_eq($$select pg_temp.ex('asset_core', 'view')$$,
  array['E1 viewer empty_profile', 'E1 viewer grants', 'E2 updater no_policy', 'E3 vendors no_policy', '* grants'],
  'view, no asset: Pune grants, Empty grants nothing');
select results_eq($$select pg_temp.ex('asset_core', 'view', '00000000-0000-0000-0000-0000000065a1')$$,
  array['E1 viewer empty_profile', 'E1 viewer grants', 'E2 updater no_policy', 'E3 vendors no_policy', '* grants'],
  'Pune bay asset: in scope (descendants)');
select results_eq($$select pg_temp.ex('asset_core', 'view', '00000000-0000-0000-0000-0000000065a3')$$,
  array['E1 viewer empty_profile', 'E1 viewer out_of_scope', 'E2 updater no_policy', 'E3 vendors no_policy', '* denied'],
  'Mumbai asset: out of scope, denied');
select results_eq($$select pg_temp.ex('asset_core', 'view', '00000000-0000-0000-0000-0000000065a5')$$,
  array['E1 viewer empty_profile', 'E1 viewer out_of_scope', 'E2 updater no_policy', 'E3 vendors no_policy', '* denied'],
  'unplaced asset: out of scope for a location rule (S5)');
select results_eq($$select pg_temp.ex('asset_core', 'update')$$,
  array['E1 viewer no_policy', 'E1 viewer no_policy', 'E2 updater not_effective', 'E3 vendors no_policy', '* denied'],
  'update: future assignment is not effective');
select results_eq($$select pg_temp.ex('vendor_core', 'view')$$,
  array['E1 viewer no_policy', 'E1 viewer no_policy', 'E2 updater no_policy', 'E3 vendors grants', '* grants'],
  'vendors: an empty profile does not limit an unscoped domain');
select results_eq($$select pg_temp.ex('vendor_core', 'view', '00000000-0000-0000-0000-0000000065a3')$$,
  array['E1 viewer no_policy', 'E1 viewer no_policy', 'E2 updater no_policy', 'E3 vendors grants', '* grants scope_not_applicable'],
  'vendors with an asset: scope does not apply, noted');
select is((select scope_profile_name from public.explain_access('00000000-0000-0000-0000-0000000000a1', 'asset_core', 'view')
           where outcome = 'grants' and group_name is not null), 'S65 Pune', 'row names the scope profile');

-- The verdict matches what a1 really sees.
select tests.act_as('00000000-0000-0000-0000-0000000000a1', '00000000-0000-0000-0000-00000000000a');
select is((select array_agg(tag order by tag) from public.asset_view where tag like 'S65-%'), array['S65-P1'],
  'a1 really sees the Pune asset only');

-- The caller's own limits [E1]: a1, Pune-scoped, with users_security.view, asks about the plant manager.
reset role;
select tests.grant('00000000-0000-0000-0000-00000000000a', '00000000-0000-0000-0000-0000000000a1', 'users_security', '{view}');
select tests.act_as('00000000-0000-0000-0000-0000000000a1', '00000000-0000-0000-0000-00000000000a');
select throws_ok($$select pg_temp.ex('asset_core', 'view', '00000000-0000-0000-0000-0000000065a3', '00000000-0000-0000-0000-0000000a0002')$$,
  'P0002', 'asset not found', 'caller cannot see the asset: not found');
select results_eq($$select outcome from public.explain_access('00000000-0000-0000-0000-0000000a0002', 'asset_core', 'view', '00000000-0000-0000-0000-0000000065a1') where group_name is null$$,
  array['grants'], 'caller sees the asset: the explainer answers');

-- Drafts [E4]: the admin drafts E1 without view and E2 with view; verdicts stay live.
select tests.act_as('00000000-0000-0000-0000-0000000a0001', '00000000-0000-0000-0000-00000000000a');
select public.set_group_policies('00000000-0000-0000-0000-0000000065b1', '{}');
select public.set_group_policies('00000000-0000-0000-0000-0000000065b2', pg_temp.ops('asset_core', '{view,update}'));
select tests.act_as('00000000-0000-0000-0000-0000000a0005', '00000000-0000-0000-0000-00000000000a');
select results_eq($$select pg_temp.ex('asset_core', 'view') limit 4$$,
  array['E1 viewer empty_profile remove', 'E1 viewer grants remove', 'E2 updater no_policy add', 'E3 vendors no_policy'],
  'draft: remove and add marked per group');
select results_eq($$select pg_temp.ex('asset_core', 'view') offset 5$$, array['* grants'], 'draft: verdict stays live');
select results_eq($$select pg_temp.ex('asset_core', 'update') offset 2 limit 1$$, array['E2 updater not_effective'],
  'draft: unchanged operation has no mark');

-- Union: a tenant-wide view assignment makes the Mumbai asset visible.
reset role;
insert into public.user_group_assignment (tenant_id, user_id, security_group_id, effective_from) values
  ('00000000-0000-0000-0000-00000000000a', '00000000-0000-0000-0000-0000000000a1', '00000000-0000-0000-0000-0000000065b1', now() - interval '1 minute');
select tests.act_as('00000000-0000-0000-0000-0000000a0005', '00000000-0000-0000-0000-00000000000a');
select results_eq($$select pg_temp.ex('asset_core', 'view', '00000000-0000-0000-0000-0000000065a3') offset 1 limit 1$$,
  array['E1 viewer grants remove'], 'union: the tenant-wide row grants');
select results_eq($$select pg_temp.ex('asset_core', 'view', '00000000-0000-0000-0000-0000000065a3') offset 6$$,
  array['* grants'], 'union: summary grants');

-- E2: a rebuild out of step with the graph shows as a mismatch, never a false yes.
reset role;
delete from private.user_effective_permission
where tenant_id = '00000000-0000-0000-0000-00000000000a' and user_id = '00000000-0000-0000-0000-0000000000a1';
select tests.act_as('00000000-0000-0000-0000-0000000a0005', '00000000-0000-0000-0000-00000000000a');
select results_eq($$select pg_temp.ex('asset_core', 'view') offset 6$$, array['* denied rebuild_mismatch'],
  'mismatch: derived rows missing, denied with a note');
reset role;
select private.rebuild_effective_permission('00000000-0000-0000-0000-00000000000a', '00000000-0000-0000-0000-0000000000a1');

-- Inactive member.
update public.tenant_membership set status = 'disabled'
where tenant_id = '00000000-0000-0000-0000-00000000000a' and user_id = '00000000-0000-0000-0000-0000000000a1';
select tests.act_as('00000000-0000-0000-0000-0000000a0005', '00000000-0000-0000-0000-00000000000a');
select results_eq($$select x from (select distinct pg_temp.ex('vendor_core', 'view') x) s order by 1$$,
  array['* denied', 'E1 viewer member_inactive', 'E2 updater member_inactive', 'E3 vendors member_inactive', 'Test grant member_inactive'],
  'disabled member: every assignment inactive, denied');
reset role;
update public.tenant_membership set status = 'active'
where tenant_id = '00000000-0000-0000-0000-00000000000a' and user_id = '00000000-0000-0000-0000-0000000000a1';

-- Read-only tenant B: a write grant is noted.
select tests.act_as('00000000-0000-0000-0000-0000000b0001', '00000000-0000-0000-0000-00000000000b');
select results_eq($$select concat_ws(' ', outcome, note) from public.explain_access('00000000-0000-0000-0000-0000000b0003', 'asset_core', 'update') where group_name is null$$,
  array['grants tenant_read_only'], 'read-only tenant: write noted');
select results_eq($$select concat_ws(' ', outcome, note) from public.explain_access('00000000-0000-0000-0000-0000000b0003', 'asset_core', 'view') where group_name is null$$,
  array['grants'], 'read-only tenant: view not noted');
select throws_ok($$select pg_temp.ex('asset_core', 'view', '00000000-0000-0000-0000-0000000065a1', '00000000-0000-0000-0000-0000000b0003')$$,
  'P0002', 'asset not found', 'another tenant''s asset: not found');

select * from finish();
rollback;
