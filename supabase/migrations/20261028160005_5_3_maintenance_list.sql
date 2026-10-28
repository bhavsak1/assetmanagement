-- Story 5.3: the Maintenance screen reads. docs/data-model-goal5.md §13 (M1 a, M3 a, M4 a).
-- Invoker functions, built like 3.2 list_assets (plpgsql, execute, literals via format). Every check comes from
-- what they read: obligation under its RLS (tenant, obligation.view), asset_view (tenant, asset_core.view, live
-- asset, purchase value mask, 6.1 scope later), service_record_view (tenant, service_record.view, cost mask).
-- Asset filters reuse private.asset_list_where on alias v, as it is.

-- The asset filters plus the obligation type, on aliases v (asset_view) and o (obligation). Unlike the Assets
-- list, these pages walk the obligation or record index, not an asset index, so the planner must know how
-- selective an asset filter is: the subtree and search ids are resolved here and written in as literals.
-- Measured at 200k assets: one small location took 1.7 s in set form, 5 ms as a literal (§13.7). The
-- helpers check tenant and asset_core.view themselves and return nothing without them.
create function private.maintenance_where(p_term text, p_category_id uuid, p_location_id uuid, p_type text,
                                          p_vendor_id uuid, p_coverage text)
returns text language plpgsql stable set search_path = '' as $$
declare
  v_ids uuid[];
  v_sql text := private.asset_list_where(null, null, null, null, null, p_vendor_id, p_coverage);
begin
  if btrim(p_term) <> '' then
    v_ids := array(select private.search_asset_ids(btrim(p_term)) limit 1001);
    -- shortcut: a term matching over 1,000 assets keeps the set form (planner guesses); fine while broad terms fill a page fast.
    v_sql := v_sql || case when cardinality(v_ids) <= 1000 then format(' and v.id = any (%L::uuid[])', v_ids)
                           else ' and ' || private.asset_list_where(btrim(p_term), null, null, null) end;
  end if;
  if p_category_id is not null then
    v_sql := v_sql || format(' and v.category_id = any (%L::uuid[])', coalesce(private.category_subtree_ids(p_category_id), '{}'));
  end if;
  if p_location_id is not null then
    v_sql := v_sql || format(' and v.location_id = any (%L::uuid[])', coalesce(private.location_subtree_ids(p_location_id), '{}'));
  end if;
  return v_sql || case when p_type is not null then format(' and o.obligation_type = %L', p_type) else '' end;
end;
$$;

create function private.obligation_list_sql(
  p_bucket text, p_term text, p_category_id uuid, p_location_id uuid, p_type text, p_vendor_id uuid,
  p_coverage text, p_after_value text, p_after_id uuid, p_limit integer)
returns text language plpgsql stable set search_path = '' as $$
declare
  v_sql text;
begin
  if p_bucket is null or p_bucket not in ('overdue', 'due_soon', 'scheduled') then
    raise exception 'unknown bucket: %', p_bucket using errcode = '22023';
  end if;
  if p_limit is null or p_limit not between 1 and 100 then
    raise exception 'limit must be 1 to 100' using errcode = '22023';
  end if;
  v_sql := 'select o.id, o.asset_id, o.name, o.obligation_type, o.interval_count, o.interval_unit, o.anchor,'
        || ' o.next_due_date, o.last_done_date, o.due_state, v.tag, v.name, v.location_id, v.category_id,'
        || ' v.in_service_date, v.purchase_date, v.purchase_value, v.purchase_currency::text'
        || ' from public.obligation o join public.asset_view v on v.tenant_id = o.tenant_id and v.id = o.asset_id'
        || format(' where o.deleted_at is null and o.due_state = %L and ', p_bucket)
        || private.maintenance_where(p_term, p_category_id, p_location_id, p_type, p_vendor_id, p_coverage);
  -- Oldest due first: most overdue on Overdue, soonest on Due soon and Scheduled. obligation_state_idx order.
  if p_after_id is not null then
    v_sql := v_sql || format(' and (o.next_due_date, o.id) > (%L::date, %L::uuid)', p_after_value, p_after_id);
  end if;
  return v_sql || format(' order by o.next_due_date, o.id limit %s', p_limit);
end;
$$;

create function private.completion_list_sql(
  p_term text, p_category_id uuid, p_location_id uuid, p_type text, p_vendor_id uuid, p_coverage text,
  p_after_value text, p_after_id uuid, p_limit integer)
returns text language plpgsql stable set search_path = '' as $$
declare
  v_sql text;
begin
  if p_limit is null or p_limit not between 1 and 100 then
    raise exception 'limit must be 1 to 100' using errcode = '22023';
  end if;
  -- Obligation and vendor through invoker joins: their names show only with obligation.view and vendor_core.view.
  v_sql := 'select r.id, r.obligation_id, r.asset_id, r.done_on, r.outcome, private.member_name(r.done_by_user_id),'
        || ' r.vendor_id, vn.name, r.cost_amount, r.cost_currency::text,'
        || ' (select count(*)::int from public.service_record_attachment f'
        || '   where f.tenant_id = r.tenant_id and f.service_record_id = r.id and f.deleted_at is null),'
        || ' o.name, o.obligation_type, v.tag, v.name, v.location_id, v.category_id,'
        || ' v.in_service_date, v.purchase_date, v.purchase_value, v.purchase_currency::text'
        || ' from public.service_record_view r'
        || ' join public.asset_view v on v.tenant_id = r.tenant_id and v.id = r.asset_id'
        || ' left join public.obligation o on o.tenant_id = r.tenant_id and o.id = r.obligation_id'
        || ' left join public.vendor vn on vn.tenant_id = r.tenant_id and vn.id = r.vendor_id'
        || ' where ' || private.maintenance_where(p_term, p_category_id, p_location_id, p_type, p_vendor_id, p_coverage);
  -- service_record_done_idx is (done_on desc, id): start at the cursor date, then skip ids already shown.
  if p_after_id is not null then
    v_sql := v_sql || format(' and r.done_on <= %1$L::date and (r.done_on < %1$L::date or r.id > %2$L::uuid)',
                             p_after_value, p_after_id);
  end if;
  return v_sql || format(' order by r.done_on desc, r.id limit %s', p_limit);
end;
$$;

create function public.list_obligations(
  p_bucket text, p_term text default null, p_category_id uuid default null, p_location_id uuid default null,
  p_type text default null, p_vendor_id uuid default null, p_coverage text default null,
  p_after_value text default null, p_after_id uuid default null, p_limit integer default 50)
returns table (id uuid, asset_id uuid, name text, obligation_type text, interval_count smallint, interval_unit text,
               anchor text, next_due_date date, last_done_date date, due_state text, tag text, asset_name text,
               location_id uuid, category_id uuid, in_service_date date, purchase_date date,
               purchase_value numeric, purchase_currency text)
language plpgsql stable set search_path = '' as $$
begin
  return query execute private.obligation_list_sql(p_bucket, p_term, p_category_id, p_location_id, p_type,
                                                   p_vendor_id, p_coverage, p_after_value, p_after_id, p_limit);
end;
$$;

create function public.list_completions(
  p_term text default null, p_category_id uuid default null, p_location_id uuid default null,
  p_type text default null, p_vendor_id uuid default null, p_coverage text default null,
  p_after_value text default null, p_after_id uuid default null, p_limit integer default 50)
returns table (id uuid, obligation_id uuid, asset_id uuid, done_on date, outcome text, done_by_name text,
               vendor_id uuid, vendor_name text, cost_amount numeric, cost_currency text, attachments integer,
               obligation_name text, obligation_type text, tag text, asset_name text, location_id uuid,
               category_id uuid, in_service_date date, purchase_date date, purchase_value numeric,
               purchase_currency text)
language plpgsql stable set search_path = '' as $$
begin
  return query execute private.completion_list_sql(p_term, p_category_id, p_location_id, p_type, p_vendor_id,
                                                   p_coverage, p_after_value, p_after_id, p_limit);
end;
$$;

-- Tab and tile counts (M4 a: exact, capped at 10,001, the 3.2 rule), same filters and joins as the lists.
-- next_7 and next_30 are fixed windows from tenant today (the tile labels); 5.4 reuses this function.
create function public.maintenance_counts(
  p_term text default null, p_category_id uuid default null, p_location_id uuid default null,
  p_type text default null, p_vendor_id uuid default null, p_coverage text default null)
returns table (overdue integer, due_soon integer, scheduled integer, completed integer, next_7 integer, next_30 integer)
language plpgsql stable set search_path = '' as $$
declare
  w text := private.maintenance_where(p_term, p_category_id, p_location_id, p_type, p_vendor_id, p_coverage);
  ob text := 'select count(*)::int from (select 1 from public.obligation o join public.asset_view v'
          || ' on v.tenant_id = o.tenant_id and v.id = o.asset_id where o.deleted_at is null and ';
  d date := private.tenant_today();
begin
  return query execute 'select '
    || '(' || ob || format('o.due_state = %L and ', 'overdue') || w || ' limit 10001) c), '
    || '(' || ob || format('o.due_state = %L and ', 'due_soon') || w || ' limit 10001) c), '
    || '(' || ob || format('o.due_state = %L and ', 'scheduled') || w || ' limit 10001) c), '
    || '(select count(*)::int from (select 1 from public.service_record_view r'
    || ' join public.asset_view v on v.tenant_id = r.tenant_id and v.id = r.asset_id'
    || ' left join public.obligation o on o.tenant_id = r.tenant_id and o.id = r.obligation_id where '
    || w || ' limit 10001) c), '
    || '(' || ob || format('o.due_state in (''due_soon'', ''scheduled'') and o.next_due_date <= %L::date and ', d + 6)
    || w || ' limit 10001) c), '
    || '(' || ob || format('o.due_state in (''due_soon'', ''scheduled'') and o.next_due_date <= %L::date and ', d + 29)
    || w || ' limit 10001) c)';
end;
$$;

revoke all on function private.maintenance_where(text, uuid, uuid, text, uuid, text),
  private.obligation_list_sql(text, text, uuid, uuid, text, uuid, text, text, uuid, integer),
  private.completion_list_sql(text, uuid, uuid, text, uuid, text, text, uuid, integer),
  public.list_obligations(text, text, uuid, uuid, text, uuid, text, text, uuid, integer),
  public.list_completions(text, uuid, uuid, text, uuid, text, text, uuid, integer),
  public.maintenance_counts(text, uuid, uuid, text, uuid, text)
  from public, anon;
grant execute on function private.maintenance_where(text, uuid, uuid, text, uuid, text),
  private.obligation_list_sql(text, text, uuid, uuid, text, uuid, text, text, uuid, integer),
  private.completion_list_sql(text, uuid, uuid, text, uuid, text, text, uuid, integer),
  public.list_obligations(text, text, uuid, uuid, text, uuid, text, text, uuid, integer),
  public.list_completions(text, uuid, uuid, text, uuid, text, text, uuid, integer),
  public.maintenance_counts(text, uuid, uuid, text, uuid, text)
  to authenticated;
