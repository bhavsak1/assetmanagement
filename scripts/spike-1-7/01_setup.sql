-- Story 1.7 spike, LOCAL ONLY. Never on staging, never in CI, never in seed.sql.
-- Stand-in for the Goal 3 asset table, built with the 1.4 RLS pattern and the 1.5 audit trigger,
-- plus stand-ins for location (2.3, closure table) and scope profiles (6.1, D7 option X).
-- Undo everything with `npm run db:reset`.

create extension if not exists pg_trgm with schema extensions;
create schema spike;
grant usage on schema spike to authenticated;

-- Location tree (2.3 stand-in): site > building > area, with a closure table.
create table spike.location (
  id        uuid primary key default gen_random_uuid(),
  tenant_id uuid not null references public.tenant (id),
  parent_id uuid null,
  level     smallint not null,
  name      text not null,
  unique (tenant_id, id),
  foreign key (tenant_id, parent_id) references spike.location (tenant_id, id)
);
create table spike.location_closure (
  tenant_id     uuid not null,
  ancestor_id   uuid not null,
  descendant_id uuid not null,
  depth         smallint not null,
  primary key (tenant_id, ancestor_id, descendant_id)
);
create table spike.category (id uuid primary key default gen_random_uuid(), tenant_id uuid not null references public.tenant (id), name text not null, unique (tenant_id, id));
create table spike.vendor   (id uuid primary key default gen_random_uuid(), tenant_id uuid not null references public.tenant (id), name text not null, unique (tenant_id, id));

-- Scope profiles (6.1 stand-in, D7 option A): location dimension only.
create table spike.scope_profile (id uuid primary key default gen_random_uuid(), tenant_id uuid not null references public.tenant (id), name text not null, unique (tenant_id, id));
create table spike.scope_profile_rule (
  id               uuid primary key default gen_random_uuid(),
  tenant_id        uuid not null,
  scope_profile_id uuid not null,
  dimension        text not null check (dimension in ('location', 'category', 'vendor', 'criticality')),
  location_id      uuid null,
  foreign key (tenant_id, scope_profile_id) references spike.scope_profile (tenant_id, id),
  foreign key (tenant_id, location_id) references spike.location (tenant_id, id)
);
create index on spike.scope_profile_rule (tenant_id, scope_profile_id, dimension);

-- D7 option X: the column 6.1 adds. Local DB only; db reset removes it.
alter table private.user_effective_permission add column scope_profile_id uuid null;

-- Asset stand-in (Goal 3 shape). Secondary indexes are built after the load, in 02_data.sql.
create table spike.asset (
  id          uuid primary key default gen_random_uuid(),
  tenant_id   uuid not null references public.tenant (id),
  asset_code  text not null,
  name        text not null,
  location_id uuid not null,
  category_id uuid not null,
  vendor_id   uuid null,
  criticality text not null check (criticality in ('A', 'B', 'C')),
  status      text not null default 'active',
  created_at  timestamptz not null default now(),
  updated_at  timestamptz not null default now(),
  created_by  uuid null references public.user_profile (id),
  updated_by  uuid null references public.user_profile (id),
  deleted_at  timestamptz null,
  unique (tenant_id, id),
  foreign key (tenant_id, location_id) references spike.location (tenant_id, id),
  foreign key (tenant_id, category_id) references spike.category (tenant_id, id),
  foreign key (tenant_id, vendor_id)   references spike.vendor (tenant_id, id)
);

create trigger set_updated_at before update on spike.asset
  for each row execute function private.set_updated_at();
create trigger check_soft_delete before update of deleted_at on spike.asset
  for each row execute function private.check_soft_delete('asset_core', 'delete');
create trigger audit after insert or update or delete on spike.asset
  for each row execute function private.audit_row('data');

-- Scope helper, set form (proposed for 6.1): the user's allowed locations for one operation,
-- computed once per statement. Null means tenant-wide: any grant with no location rule wins (additive).
create function spike.scope_location_ids(p_domain text, p_operation text)
returns uuid[] language sql stable security definer set search_path = '' as $$
  select case when bool_or(r.id is null) then null
              else coalesce(array_agg(distinct c.descendant_id), '{}') end
  from private.user_effective_permission uep
  join public.domain_operation o on o.id = uep.domain_operation_id
  join public.security_domain d  on d.id = o.security_domain_id
  left join spike.scope_profile_rule r on r.tenant_id = uep.tenant_id and r.scope_profile_id = uep.scope_profile_id
                                      and r.dimension = 'location'
  left join spike.location_closure c on c.tenant_id = r.tenant_id and c.ancestor_id = r.location_id
  where uep.tenant_id = private.current_tenant_id()
    and uep.user_id   = (select auth.uid())
    and d.code = p_domain and o.code = p_operation
    and uep.effective_from <= now()
    and (uep.effective_to is null or uep.effective_to > now());
$$;

-- Scope helper, row form (the obvious first draft): called once per row. Measured to compare.
create function spike.in_scope_row(p_domain text, p_operation text, p_location_id uuid)
returns boolean language sql stable security definer set search_path = '' as $$
  select exists (
    select 1
    from private.user_effective_permission uep
    join public.domain_operation o on o.id = uep.domain_operation_id
    join public.security_domain d  on d.id = o.security_domain_id
    left join spike.scope_profile_rule r on r.tenant_id = uep.tenant_id and r.scope_profile_id = uep.scope_profile_id
                                        and r.dimension = 'location'
    where uep.tenant_id = private.current_tenant_id()
      and uep.user_id   = (select auth.uid())
      and d.code = p_domain and o.code = p_operation
      and uep.effective_from <= now()
      and (uep.effective_to is null or uep.effective_to > now())
      and (r.id is null or exists (select 1 from spike.location_closure c
                                   where c.tenant_id = r.tenant_id and c.ancestor_id = r.location_id
                                     and c.descendant_id = p_location_id)));
$$;
grant execute on function spike.scope_location_ids(text, text), spike.in_scope_row(text, text, uuid) to authenticated;

-- 1.4 pattern policies plus the set-form scope check.
alter table spike.asset enable row level security;
create policy asset_select on spike.asset
  for select to authenticated
  using (tenant_id = (select private.current_tenant_id())
         and (select private.has_permission('asset_core', 'view'))
         and ((select spike.scope_location_ids('asset_core', 'view')) is null
              -- The cast makes "any" take the array, not the subquery's rows.
              or location_id = any ((select spike.scope_location_ids('asset_core', 'view'))::uuid[])));
create policy asset_insert on spike.asset
  for insert to authenticated
  with check (tenant_id = (select private.current_tenant_id())
              and (select private.has_permission('asset_core', 'create'))
              and (select private.tenant_can_write()));
create policy asset_update on spike.asset
  for update to authenticated
  using (tenant_id = (select private.current_tenant_id())
         and (select private.has_permission('asset_core', 'update'))
         and (select private.tenant_can_write()))
  with check (tenant_id = (select private.current_tenant_id())
              and (select private.has_permission('asset_core', 'update'))
              and (select private.tenant_can_write()));
grant select, insert, update on spike.asset to authenticated;
revoke delete, truncate on spike.asset from anon, authenticated;

-- Bench: run p_sql p_n times as the user (or as postgres when p_user is null), each run rolled back.
-- Times are wall clock inside Postgres (plan + execute), not network or JSON. Run 0 is a warm-up.
create table spike.result (
  label text primary key, n int, p50_ms numeric, p95_ms numeric, max_ms numeric, plan_rows text, plan text
);
create table spike.bench_user (label text primary key, user_id uuid not null, tenant_id uuid not null);

create function spike.bench(p_label text, p_who text, p_sql text, p_n int default 30)
returns void language plpgsql as $$
declare
  v_user   uuid;
  v_tenant uuid;
  v_t0     timestamptz;
  v_times  numeric[] := '{}';
  v_plan   text := '';
  v_line   text;
begin
  if p_who is not null then
    select user_id, tenant_id into strict v_user, v_tenant from spike.bench_user where label = p_who;
  end if;
  for i in 0 .. p_n loop
    begin
      if v_user is not null then perform tests.act_as(v_user, v_tenant); end if;
      v_t0 := clock_timestamp();
      execute p_sql;
      if i > 0 then v_times := v_times || (extract(epoch from clock_timestamp() - v_t0) * 1000)::numeric; end if;
      raise exception using errcode = 'SP001';
    exception when sqlstate 'SP001' then null;
    end;
  end loop;
  begin
    if v_user is not null then perform tests.act_as(v_user, v_tenant); end if;
    for v_line in execute 'explain (analyze, buffers, costs off, summary off) ' || p_sql loop
      v_plan := v_plan || v_line || E'\n';
    end loop;
    raise exception using errcode = 'SP001';
  exception when sqlstate 'SP001' then null;
  end;
  insert into spike.result (label, n, p50_ms, p95_ms, max_ms, plan_rows, plan)
  select p_label, p_n,
         round((percentile_cont(0.5)  within group (order by t))::numeric, 2),
         round((percentile_cont(0.95) within group (order by t))::numeric, 2),
         round(max(t), 2),
         substring(v_plan from 'rows=(\d+)'), v_plan
  from unnest(v_times) t
  on conflict (label) do update set n = excluded.n, p50_ms = excluded.p50_ms, p95_ms = excluded.p95_ms,
    max_ms = excluded.max_ms, plan_rows = excluded.plan_rows, plan = excluded.plan;
end;
$$;
