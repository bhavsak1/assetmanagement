-- Story 4.2: coverage (warranty, AMC) and the assets it covers. Design and owner decisions C1 to C10:
-- docs/data-model-goal4.md §18 to §24. 1.4 RLS pattern on the catalog domains coverage_contract and
-- coverage_values (1.2 seed, 1.6 grid): no new domain. Asset-wise scope only (C3), no exclusions (OQ-05).

-- C7: "today" and the expiring window are the tenant's. Default 60 days (the screens' "60 days").
alter table public.tenant add column coverage_expiring_days smallint not null default 60
  check (coverage_expiring_days between 1 and 365);

create function private.tenant_today()
returns date language sql stable security definer set search_path = '' as $$
  select (now() at time zone t.time_zone)::date from public.tenant t where t.id = private.current_tenant_id();
$$;
revoke all on function private.tenant_today() from public, anon;
grant execute on function private.tenant_today() to authenticated;

create table public.coverage (
  id                 uuid primary key default gen_random_uuid(),
  tenant_id          uuid not null references public.tenant (id),
  -- C1: system codes; warranty and extended_warranty form the warranty group (KB §2).
  coverage_type      text not null check (coverage_type in ('warranty', 'extended_warranty', 'amc', 'other')),
  vendor_id          uuid not null,
  reference          text null check (length(reference) between 1 and 100),
  -- Both days are covered.
  start_date         date not null,
  end_date           date not null,
  contract_value     numeric(19, 4) null check (contract_value >= 0),     -- coverage_values
  contract_currency  text null check (contract_currency ~ '^[A-Z]{3}$'),  -- coverage_values
  -- C5: a renewal is a new row pointing at the one it renews.
  renews_coverage_id uuid null,
  notes              text null check (length(notes) <= 2000),
  created_at         timestamptz not null default now(),
  updated_at         timestamptz not null default now(),
  created_by         uuid null references public.user_profile (id),
  updated_by         uuid null references public.user_profile (id),
  deleted_at         timestamptz null,
  unique (tenant_id, id),
  check (end_date >= start_date),
  check (contract_value is null or contract_currency is not null),
  check (renews_coverage_id <> id),
  foreign key (tenant_id, vendor_id) references public.vendor (tenant_id, id),
  foreign key (tenant_id, renews_coverage_id) references public.coverage (tenant_id, id)
);

create index coverage_end_idx on public.coverage (tenant_id, end_date, id) where deleted_at is null;
-- For merge_vendor, the vendor soft-delete guard and vendor counts.
create index coverage_vendor_idx on public.coverage (tenant_id, vendor_id) where deleted_at is null;

-- C2: the vendor is live and active when set or changed. No role or tag rule. Unchanged vendors stay
-- valid after deactivation (as B4). Value changes need coverage_values (as purchase value, 3.3).
create function private.check_coverage()
returns trigger language plpgsql security definer set search_path = '' as $$
begin
  new.reference := nullif(btrim(new.reference), '');

  if (tg_op = 'INSERT' or new.vendor_id is distinct from old.vendor_id)
     and not exists (select 1 from public.vendor v where v.tenant_id = new.tenant_id and v.id = new.vendor_id
                     and v.deleted_at is null and v.is_active) then
    raise exception 'vendor_id: vendor is inactive or not found' using errcode = '23514';
  end if;

  if auth.uid() is not null
     and not (private.has_permission('coverage_values', 'update') and private.has_permission('coverage_values', 'view'))
     and (case when tg_op = 'INSERT' then new.contract_value is not null or new.contract_currency is not null
               else (new.contract_value, new.contract_currency) is distinct from (old.contract_value, old.contract_currency) end) then
    raise exception 'no permission to change contract value' using errcode = '42501';
  end if;
  return new;
end;
$$;
revoke all on function private.check_coverage() from public, anon, authenticated;

create trigger check_coverage before insert or update on public.coverage
  for each row execute function private.check_coverage();
create trigger check_soft_delete before update of deleted_at on public.coverage
  for each row execute function private.check_soft_delete('coverage_contract', 'delete');
create trigger set_updated_at before update on public.coverage
  for each row execute function private.set_updated_at();
create trigger audit after insert or update or delete on public.coverage
  for each row execute function private.audit_row('data');

create table public.coverage_asset (
  id          uuid primary key default gen_random_uuid(),
  tenant_id   uuid not null references public.tenant (id),
  coverage_id uuid not null,
  asset_id    uuid not null,
  created_at  timestamptz not null default now(),
  updated_at  timestamptz not null default now(),
  created_by  uuid null references public.user_profile (id),
  updated_by  uuid null references public.user_profile (id),
  deleted_at  timestamptz null,
  unique (tenant_id, id),
  foreign key (tenant_id, coverage_id) references public.coverage (tenant_id, id),
  foreign key (tenant_id, asset_id) references public.asset (tenant_id, id)
);

create unique index coverage_asset_uq on public.coverage_asset (tenant_id, coverage_id, asset_id) where deleted_at is null;
-- The per-asset lookup (asset_coverage, the 4.4 list column).
create index coverage_asset_asset_idx on public.coverage_asset (tenant_id, asset_id) where deleted_at is null;

-- Links are made to live assets of live contracts, by every writer.
create function private.check_coverage_asset()
returns trigger language plpgsql security definer set search_path = '' as $$
begin
  if not exists (select 1 from public.asset a where a.tenant_id = new.tenant_id and a.id = new.asset_id and a.deleted_at is null)
     or not exists (select 1 from public.coverage c where c.tenant_id = new.tenant_id and c.id = new.coverage_id and c.deleted_at is null) then
    raise exception 'asset or coverage is deleted or not found' using errcode = '23514';
  end if;
  return new;
end;
$$;
revoke all on function private.check_coverage_asset() from public, anon, authenticated;

create trigger check_coverage_asset before insert on public.coverage_asset
  for each row execute function private.check_coverage_asset();
-- Removing an asset from a contract edits the contract (as V7 contacts).
create trigger check_soft_delete before update of deleted_at on public.coverage_asset
  for each row execute function private.check_soft_delete('coverage_contract', 'update');
create trigger set_updated_at before update on public.coverage_asset
  for each row execute function private.set_updated_at();
create trigger audit after insert or update or delete on public.coverage_asset
  for each row execute function private.audit_row('data');

-- OQ-26 (C4): a contract is visible when one of its live assets is in asset_view for this user, or it has
-- no live assets yet. Through asset_view, so 6.1's scope clause there reaches coverage too. Definer: the
-- "no assets" half must count links the user cannot see. Callers check coverage_contract.view.
-- shortcut: called per row (one or two index probes), fine for thousands of contracts; inline it in
-- coverage_view if the Coverage page counts get slow (6.1 measures with the spike data).
create function private.coverage_visible(p_coverage_id uuid)
returns boolean language sql stable security definer set search_path = '' as $$
  select exists (select 1 from public.coverage_asset ca join public.asset_view av on av.id = ca.asset_id
                 where ca.tenant_id = (select private.current_tenant_id()) and ca.coverage_id = p_coverage_id
                   and ca.deleted_at is null)
      or not exists (select 1 from public.coverage_asset ca
                     where ca.tenant_id = (select private.current_tenant_id()) and ca.coverage_id = p_coverage_id
                       and ca.deleted_at is null);
$$;
revoke all on function private.coverage_visible(uuid) from public, anon;
grant execute on function private.coverage_visible(uuid) to authenticated;

-- RLS, 1.4 pattern. No delete policy: removal is a soft delete.
alter table public.coverage enable row level security;
alter table public.coverage_asset enable row level security;

create policy coverage_select on public.coverage
  for select to authenticated
  using (tenant_id = (select private.current_tenant_id())
         and (select private.has_permission('coverage_contract', 'view'))
         and private.coverage_visible(id));
create policy coverage_insert on public.coverage
  for insert to authenticated
  with check (tenant_id = (select private.current_tenant_id())
              and (select private.has_permission('coverage_contract', 'create'))
              and (select private.tenant_can_write()));
create policy coverage_update on public.coverage
  for update to authenticated
  using (tenant_id = (select private.current_tenant_id())
         and (select private.has_permission('coverage_contract', 'update'))
         and (select private.tenant_can_write())
         and private.coverage_visible(id))
  with check (tenant_id = (select private.current_tenant_id())
              and (select private.has_permission('coverage_contract', 'update'))
              and (select private.tenant_can_write()));

-- FK checks ignore RLS, so the writer must see the asset and the contract.
create policy coverage_asset_select on public.coverage_asset
  for select to authenticated
  using (tenant_id = (select private.current_tenant_id())
         and (select private.has_permission('coverage_contract', 'view'))
         and exists (select 1 from public.asset_view av where av.id = asset_id));
create policy coverage_asset_insert on public.coverage_asset
  for insert to authenticated
  with check (tenant_id = (select private.current_tenant_id())
              and (select private.has_permission('coverage_contract', 'update'))
              and (select private.tenant_can_write())
              and exists (select 1 from public.asset_view av where av.id = asset_id)
              and private.coverage_visible(coverage_id));
create policy coverage_asset_update on public.coverage_asset
  for update to authenticated
  using (tenant_id = (select private.current_tenant_id())
         and (select private.has_permission('coverage_contract', 'update'))
         and (select private.tenant_can_write())
         and exists (select 1 from public.asset_view av where av.id = asset_id))
  with check (tenant_id = (select private.current_tenant_id())
              and (select private.has_permission('coverage_contract', 'update'))
              and (select private.tenant_can_write()));

-- RLS cannot hide columns: the contract value is read through coverage_view only.
revoke all on public.coverage from anon, authenticated;
grant select (id, tenant_id, coverage_type, vendor_id, reference, start_date, end_date, renews_coverage_id, notes,
              created_at, updated_at, created_by, updated_by, deleted_at)
  on public.coverage to authenticated;
grant insert (id, tenant_id, coverage_type, vendor_id, reference, start_date, end_date, contract_value,
              contract_currency, renews_coverage_id, notes, created_by, updated_by)
  on public.coverage to authenticated;
grant update (coverage_type, vendor_id, reference, start_date, end_date, contract_value, contract_currency,
              renews_coverage_id, notes, updated_by, deleted_at)
  on public.coverage to authenticated;

-- A link is only added or soft-deleted; asset and contract never change on a row.
revoke all on public.coverage_asset from anon, authenticated;
grant select on public.coverage_asset to authenticated;
grant insert (id, tenant_id, coverage_id, asset_id, created_by, updated_by) on public.coverage_asset to authenticated;
grant update (updated_by, deleted_at) on public.coverage_asset to authenticated;

-- The app reads contracts only here. Same shape and reasons as asset_view (3.1 A6): owner-run so it can
-- read the value, the where clause repeats the base select policy, live rows only, not security_barrier.
-- status (C7) is live in the tenant's time zone: start today is active, end today still covered,
-- expiring when it ends within coverage_expiring_days. Owner review item.
create view public.coverage_view as
  select c.id, c.tenant_id, c.coverage_type, c.vendor_id, c.reference, c.start_date, c.end_date,
         case when (select private.has_permission('coverage_values', 'view')) then c.contract_value end as contract_value,
         case when (select private.has_permission('coverage_values', 'view')) then c.contract_currency end as contract_currency,
         c.renews_coverage_id, c.notes,
         case when c.start_date > (select private.tenant_today()) then 'future'
              when c.end_date < (select private.tenant_today()) then 'expired'
              when c.end_date < (select private.tenant_today())
                                + (select t.coverage_expiring_days from public.tenant t
                                   where t.id = (select private.current_tenant_id())) then 'expiring'
              else 'active' end as status,
         c.created_at, c.updated_at, c.created_by, c.updated_by
  from public.coverage c
  where c.tenant_id = (select private.current_tenant_id())
    and (select private.has_permission('coverage_contract', 'view'))
    and c.deleted_at is null
    and private.coverage_visible(c.id);
revoke all on public.coverage_view from public, anon, authenticated;
grant select on public.coverage_view to authenticated;

-- The 2.5 settings function with one more setting, last and optional (null keeps it): old calls still work.
drop function public.update_tenant_settings(text, text, text, text, smallint, text[]);
create function public.update_tenant_settings(
  p_currency_code           text,
  p_locale                  text,
  p_time_zone               text,
  p_date_format             text,
  p_fiscal_year_start_month smallint,
  p_required_asset_fields   text[],
  p_coverage_expiring_days  smallint default null
)
returns void language plpgsql security definer set search_path = '' as $$
declare
  v_tenant_id uuid := private.current_tenant_id();
  v_old       jsonb;
  v_new       jsonb;
begin
  if v_tenant_id is null
     or not private.has_permission('tenant_settings', 'manage')
     or not private.tenant_can_write() then
    raise exception 'not allowed to change tenant settings' using errcode = '42501';
  end if;

  if not exists (select 1 from pg_catalog.pg_timezone_names where name = p_time_zone) then
    raise exception 'unknown time zone: %', p_time_zone using errcode = '22023';
  end if;

  select to_jsonb(t) into v_old from public.tenant t where t.id = v_tenant_id;

  update public.tenant set
    currency_code           = p_currency_code,
    locale                  = p_locale,
    time_zone               = p_time_zone,
    date_format             = p_date_format,
    fiscal_year_start_month = p_fiscal_year_start_month,
    required_asset_fields   = coalesce(p_required_asset_fields, '{}'),
    coverage_expiring_days  = coalesce(p_coverage_expiring_days, coverage_expiring_days),
    updated_by              = auth.uid()
  where id = v_tenant_id
  returning to_jsonb(tenant.*) into v_new;

  -- Changed columns only, as audit_row() does (data-model-goal1.md §2.12).
  select jsonb_object_agg(o.key, o.value), jsonb_object_agg(o.key, v_new -> o.key)
    into v_old, v_new
  from jsonb_each(v_old) o
  where o.value is distinct from v_new -> o.key and o.key not in ('updated_at', 'updated_by');

  if v_old is null then
    return;  -- nothing changed, nothing to audit
  end if;

  insert into public.audit_log (tenant_id, category, actor_type, actor_user_id, action, table_name, record_id, old_data, new_data)
  values (v_tenant_id, 'data', 'user', auth.uid(), 'update', 'tenant', v_tenant_id, v_old, v_new);
  insert into private.outbox_event (tenant_id, event_type, aggregate_type, aggregate_id, payload)
  values (v_tenant_id, 'tenant.update', 'tenant', v_tenant_id, jsonb_build_object('old', v_old, 'new', v_new));
end;
$$;
revoke all on function public.update_tenant_settings(text, text, text, text, smallint, text[], smallint) from public, anon;
grant execute on function public.update_tenant_settings(text, text, text, text, smallint, text[], smallint) to authenticated;
