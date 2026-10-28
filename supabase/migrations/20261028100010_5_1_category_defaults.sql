-- Story 5.1: category defaults for obligations and the warranty term, one mechanism (owner decision 2,
-- 27 Oct 2026), and the copy onto new assets. docs/data-model-goal5.md §2, owner decisions O2 to O4
-- (28 Oct 2026). Same shape as 3.7 status_ids: null = inherit from the nearest parent. Written by the
-- existing category update (category_config.manage) and audited by the category audit trigger.
-- Owner review item: the definer copy trigger.

alter table public.asset_category
  -- Null = inherit, [] = none. Each entry: {name, obligation_type, interval_count, interval_unit, anchor}.
  add column default_obligations jsonb null,
  -- Null = inherit, 0 = none, else a 4.5 Term (W2) so the Term select can show it.
  add column default_warranty_months smallint null
    check (default_warranty_months in (0, 3, 6, 12, 18, 24, 36, 48, 60));

-- The same checks as the obligation columns, names unique in the list, at most 20 entries.
create function private.check_category_defaults()
returns trigger language plpgsql set search_path = '' as $$
begin
  if new.default_obligations is null then
    return new;
  end if;
  if jsonb_typeof(new.default_obligations) <> 'array' or jsonb_array_length(new.default_obligations) > 20 then
    raise exception 'default_obligations: a list of at most 20 entries' using errcode = '23514';
  end if;
  if exists (
    select 1 from jsonb_array_elements(new.default_obligations) e
    where case when jsonb_typeof(e) <> 'object' then true
               else e - '{name,obligation_type,interval_count,interval_unit,anchor}'::text[] <> '{}'::jsonb
                    or jsonb_typeof(e -> 'name') is distinct from 'string'
                    or length(btrim(e ->> 'name')) not between 1 and 80
                    or coalesce(e ->> 'obligation_type', '') not in ('service', 'calibration', 'inspection', 'certificate')
                    or coalesce(e ->> 'interval_unit', '') not in ('day', 'week', 'month', 'year')
                    or coalesce(e ->> 'anchor', '') not in ('completion', 'fixed')
                    or case when jsonb_typeof(e -> 'interval_count') = 'number'
                            then not ((e ->> 'interval_count')::numeric between 1 and 999
                                      and (e ->> 'interval_count')::numeric % 1 = 0)
                            else true end
          end) then
    raise exception 'default_obligations: each entry needs name, obligation_type, interval_count (1 to 999), interval_unit and anchor'
      using errcode = '23514';
  end if;
  if (select count(distinct lower(btrim(e ->> 'name'))) from jsonb_array_elements(new.default_obligations) e)
     <> jsonb_array_length(new.default_obligations) then
    raise exception 'default_obligations: names must be unique' using errcode = '23514';
  end if;
  return new;
end;
$$;
revoke all on function private.check_category_defaults() from public, anon, authenticated;
create trigger check_category_defaults before insert or update of default_obligations on public.asset_category
  for each row execute function private.check_category_defaults();

-- Each default from the nearest category up the tree that sets it, separately: one category can hold the
-- warranty term and a child its own obligations. The _from ids name the category it came from.
create function private.category_defaults(p_tenant_id uuid, p_category_id uuid)
returns table (default_obligations jsonb, default_warranty_months smallint, obligations_from uuid, warranty_from uuid)
language sql stable security definer set search_path = '' as $$
  with recursive up as (
    select c.id, c.parent_id, c.default_obligations, c.default_warranty_months, 0 as depth
    from public.asset_category c
    where c.tenant_id = p_tenant_id and c.id = p_category_id
    union all
    select c.id, c.parent_id, c.default_obligations, c.default_warranty_months, up.depth + 1
    from public.asset_category c
    join up on c.tenant_id = p_tenant_id and c.id = up.parent_id
  ), o as (
    select up.default_obligations, up.id from up where up.default_obligations is not null order by depth limit 1
  ), w as (
    select up.default_warranty_months, up.id from up where up.default_warranty_months is not null order by depth limit 1
  )
  select (select o.default_obligations from o), (select w.default_warranty_months from w),
         (select o.id from o), (select w.id from w);
$$;
revoke all on function private.category_defaults(uuid, uuid) from public, anon, authenticated;

-- For the app: Add asset (the warranty Term prefill) and the 5.1b category form.
create function public.category_defaults(p_category_id uuid)
returns table (default_obligations jsonb, default_warranty_months smallint, obligations_from uuid, warranty_from uuid)
language sql stable security definer set search_path = '' as $$
  select d.* from private.category_defaults(private.current_tenant_id(), p_category_id) d
  where private.current_tenant_id() is not null
    and (private.has_permission('asset_core', 'create') or private.has_permission('category_config', 'view'));
$$;
revoke all on function public.category_defaults(uuid) from public, anon;
grant execute on function public.category_defaults(uuid) to authenticated;

-- O3: a new asset copies its category's default obligations, from every writer (form, 4.5 RPC, imports).
-- The asset owns the rows after that. Definer: the category decided them, so a user without
-- obligation.create still gets them. O4: first due is the first base + k × interval (k >= 1) on or after
-- the tenant's today, base = in-service date, else purchase date, else today, so an old asset is not
-- overdue on day one.
create function private.copy_category_obligations()
returns trigger language plpgsql security definer set search_path = '' as $$
declare
  v_today date := (select (now() at time zone t.time_zone)::date from public.tenant t where t.id = new.tenant_id);
  v_base  date := coalesce(new.in_service_date, new.purchase_date, v_today);
begin
  insert into public.obligation (tenant_id, asset_id, name, obligation_type, interval_count, interval_unit, anchor, first_due_date)
  select new.tenant_id, new.id, d.name, d.obligation_type, d.interval_count, d.interval_unit, d.anchor,
         private.obligation_next_due('fixed', d.interval_count, d.interval_unit,
                                     (v_base + private.obligation_step(d.interval_count, d.interval_unit))::date, v_today - 1)
  from private.category_defaults(new.tenant_id, new.category_id) c
  cross join jsonb_to_recordset(c.default_obligations)
    as d (name text, obligation_type text, interval_count smallint, interval_unit text, anchor text);
  return null;
end;
$$;
revoke all on function private.copy_category_obligations() from public, anon, authenticated;
create trigger copy_category_obligations after insert on public.asset
  for each row execute function private.copy_category_obligations();
