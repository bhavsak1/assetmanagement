-- Story 9.5a: who can read a deleted asset (the /v1 tombstone and 410) (docs/data-model-goal9.md §19 M1).
-- No new policy: asset_select (6.1) applies tenant, asset_core.view and scope, and keeps deleted rows readable.
-- Seed: tenant A (...0a) and B (...0b); test.user a1 is in both with no groups.
begin;
select plan(8);

insert into public.location (id, tenant_id, name) values
  ('00000000-0000-0000-0000-0000000095e1', '00000000-0000-0000-0000-00000000000a', 'S95 Pune'),
  ('00000000-0000-0000-0000-0000000095e2', '00000000-0000-0000-0000-00000000000a', 'S95 Mumbai');
insert into public.asset_category (id, tenant_id, name) values
  ('00000000-0000-0000-0000-0000000095c1', '00000000-0000-0000-0000-00000000000a', 'S95 Pumps');
insert into public.asset (id, tenant_id, tag, name, category_id, location_id) values
  ('00000000-0000-0000-0000-0000000095a1', '00000000-0000-0000-0000-00000000000a', 'S95-GONE', 'Gone pump',
   '00000000-0000-0000-0000-0000000095c1', '00000000-0000-0000-0000-0000000095e1');
update public.asset set deleted_at = now() where id = '00000000-0000-0000-0000-0000000095a1';
insert into public.scope_profile (id, tenant_id, name) values
  ('00000000-0000-0000-0000-0000000095f1', '00000000-0000-0000-0000-00000000000a', 'S95 Mumbai only');
insert into public.scope_profile_rule (tenant_id, scope_profile_id, dimension, location_id) values
  ('00000000-0000-0000-0000-00000000000a', '00000000-0000-0000-0000-0000000095f1', 'location', '00000000-0000-0000-0000-0000000095e2');

create function pg_temp.sees_tombstone() returns boolean language sql as $$
  select exists (select 1 from public.asset where id = '00000000-0000-0000-0000-0000000095a1' and deleted_at is not null);
$$;
create function pg_temp.in_view() returns boolean language sql as $$
  select exists (select 1 from public.asset_view where id = '00000000-0000-0000-0000-0000000095a1');
$$;
grant execute on all functions in schema pg_temp to authenticated;

select has_index('public', 'asset', 'asset_deleted_idx', 'the tombstone index exists');

-- 1. No grant: nothing.
select tests.act_as('00000000-0000-0000-0000-0000000000a1', '00000000-0000-0000-0000-00000000000a');
select ok(not pg_temp.sees_tombstone(), 'no asset_core.view: the deleted asset is not readable');
reset role;

-- 2. asset_core.view tenant-wide: the deleted row reads from public.asset, never from asset_view.
select tests.grant('00000000-0000-0000-0000-00000000000a', '00000000-0000-0000-0000-0000000000a1', 'asset_core', '{view}');
select tests.act_as('00000000-0000-0000-0000-0000000000a1', '00000000-0000-0000-0000-00000000000a');
select ok(pg_temp.sees_tombstone(), 'asset_core.view: the deleted asset is readable as a tombstone');
select ok(not pg_temp.in_view(), 'asset_view never shows a deleted asset');
select is((select tag from public.asset where id = '00000000-0000-0000-0000-0000000095a1'), 'S95-GONE', 'the tombstone carries its tag');
reset role;

-- 3. The same view, scoped to a site the deleted asset is not in: nothing.
update public.user_group_assignment set deleted_at = now()
where tenant_id = '00000000-0000-0000-0000-00000000000a' and user_id = '00000000-0000-0000-0000-0000000000a1' and deleted_at is null;
select tests.grant('00000000-0000-0000-0000-00000000000a', '00000000-0000-0000-0000-0000000000a1', 'asset_core', '{view}');
update public.user_group_assignment set scope_profile_id = '00000000-0000-0000-0000-0000000095f1'
where tenant_id = '00000000-0000-0000-0000-00000000000a' and user_id = '00000000-0000-0000-0000-0000000000a1' and deleted_at is null;
select tests.act_as('00000000-0000-0000-0000-0000000000a1', '00000000-0000-0000-0000-00000000000a');
select ok(not pg_temp.sees_tombstone(), 'out of scope: the deleted asset is not readable');
reset role;

-- 4. Another tenant, with asset_core.view there: nothing.
select tests.grant('00000000-0000-0000-0000-00000000000b', '00000000-0000-0000-0000-0000000000a1', 'asset_core', '{view}');
select tests.act_as('00000000-0000-0000-0000-0000000000a1', '00000000-0000-0000-0000-00000000000b');
select ok(not pg_temp.sees_tombstone(), 'tenant B: tenant A''s deleted asset is not readable');
select is((select count(*)::int from public.asset where tenant_id = '00000000-0000-0000-0000-00000000000a'), 0, 'tenant B sees no tenant A asset at all');
reset role;

select * from finish();
rollback;
