-- TEST HARNESS (story 1.4). Local and CI only: loaded as a seed file after seed.sql by
-- `supabase db reset` (config.toml [db.seed]). Never run on staging. Not a migration on purpose.
-- The only approved way for tests to touch another tenant's data (CLAUDE.md §14).
-- Uses the seed: tenant A (...0a, active), tenant B (...0b, read_only), test.user a1 (A and B),
-- test.user2 a2 (B only). Tests call these as postgres and roll back.

create schema if not exists tests;
grant usage on schema tests to authenticated;

-- Act as a signed-in user in a tenant: the role and JWT claims the API sets. Lasts to the end of
-- the transaction. Go back to postgres with `reset role`.
create or replace function tests.act_as(p_user uuid, p_tenant uuid)
returns void language plpgsql as $$
begin
  perform set_config('request.jwt.claims',
    json_build_object('sub', p_user, 'role', 'authenticated', 'tenant_id', p_tenant)::text, true);
  perform set_config('role', 'authenticated', true);
end;
$$;
grant execute on function tests.act_as(uuid, uuid) to authenticated;

-- Give a member operations on a domain through a new group (null = every operation). Run as postgres.
create or replace function tests.grant(p_tenant uuid, p_user uuid, p_domain text, p_ops text[] default null)
returns void language plpgsql as $$
declare
  v_group uuid;
begin
  insert into public.security_group (tenant_id, code, name)
  values (p_tenant, 'test_' || substr(md5(random()::text), 1, 12), 'Test grant')
  returning id into v_group;

  insert into public.group_domain_policy (tenant_id, security_group_id, domain_operation_id)
  select p_tenant, v_group, o.id
  from public.domain_operation o join public.security_domain d on d.id = o.security_domain_id
  where d.code = p_domain and (p_ops is null or o.code = any (p_ops));

  insert into public.user_group_assignment (tenant_id, user_id, security_group_id)
  values (p_tenant, p_user, v_group);
end;
$$;

-- Insert a row as the current role and return its id. p_row holds the columns to set.
create or replace function tests.insert_row(p_table regclass, p_row jsonb)
returns uuid language plpgsql as $$
declare
  v_cols text := (select string_agg(quote_ident(k), ', ') from jsonb_object_keys(p_row) k);
  v_id   uuid;
begin
  execute format('insert into %1$s (%2$s) select %2$s from jsonb_populate_record(null::%1$s, $1) returning id',
                 p_table, v_cols)
    into v_id using p_row;
  return v_id;
end;
$$;
grant execute on function tests.insert_row(regclass, jsonb) to authenticated;

-- The cross-tenant check for one tenant table. Adds 8 tests to the plan. Run as postgres.
-- p_row: a valid row without tenant_id, for example '{"name":"x"}'. Gives a1 every operation of
-- p_domain in both tenants, so only the tenant check can stop the reads and writes below.
create or replace function tests.cross_tenant(p_table regclass, p_domain text, p_row jsonb)
returns setof text language plpgsql as $$
declare
  a  constant uuid := '00000000-0000-0000-0000-00000000000a';
  b  constant uuid := '00000000-0000-0000-0000-00000000000b';
  a1 constant uuid := '00000000-0000-0000-0000-0000000000a1';
  a2 constant uuid := '00000000-0000-0000-0000-0000000000a2';
  v_own   uuid;
  v_other uuid;
  v_n     int;
  v_before jsonb;
  v_after  jsonb;
  -- Append-only tables (audit_log) have no deleted_at; any column proves the same thing.
  v_set   text := case when exists (select 1 from pg_attribute where attrelid = p_table
                                    and attname = 'deleted_at' and not attisdropped)
                       then 'deleted_at = now()' else 'id = id' end;
begin
  reset role;
  perform tests.grant(a, a1, p_domain);
  perform tests.grant(b, a1, p_domain);
  perform tests.grant(b, a2, p_domain);
  v_own   := tests.insert_row(p_table, p_row || jsonb_build_object('tenant_id', a));
  v_other := tests.insert_row(p_table, p_row || jsonb_build_object('tenant_id', b));
  execute format('select to_jsonb(t) from %s t where id = $1', p_table) into v_before using v_other;

  -- a1 is a member of both tenants, working in A.
  perform tests.act_as(a1, a);
  execute format('select count(*) from %s where id = $1', p_table) into v_n using v_own;
  return next is(v_n, 1, p_table || ': user sees own tenant row');
  execute format('select count(*) from %s where tenant_id <> $1', p_table) into v_n using a;
  return next is(v_n, 0, p_table || ': user sees no other tenant rows');

  return next throws_ok(
    format('select tests.insert_row(%L, %L)', p_table, p_row || jsonb_build_object('tenant_id', b)),
    '42501', null, p_table || ': user cannot insert into another tenant');

  -- Writes on another tenant's row: no row touched, or refused outright (column grants).
  begin
    execute format('update %s set %s where id = $1', p_table, v_set) using v_other;
    get diagnostics v_n = row_count;
  exception when insufficient_privilege then v_n := 0;
  end;
  return next is(v_n, 0, p_table || ': user cannot update another tenant row');

  return next throws_ok(
    format('update %s set tenant_id = %L where id = %L', p_table, b, v_own),
    '42501', null, p_table || ': user cannot move own row to another tenant');

  begin
    execute format('delete from %s where id = $1', p_table) using v_other;
    get diagnostics v_n = row_count;
  exception when insufficient_privilege then v_n := 0;
  end;
  return next is(v_n, 0, p_table || ': user cannot delete another tenant row');

  -- a2 belongs to B only and forges a tenant A claim.
  perform tests.act_as(a2, a);
  execute format('select count(*) from %s', p_table) into v_n;
  return next is(v_n, 0, p_table || ': forged tenant claim sees no rows');

  reset role;
  execute format('select to_jsonb(t) from %s t where id = $1', p_table) into v_after using v_other;
  return next is(v_after, v_before, p_table || ': other tenant row is unchanged');
end;
$$;
