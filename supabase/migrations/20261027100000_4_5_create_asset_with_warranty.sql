-- Story 4.5: one save for a new asset and its warranty lines (data-model-goal4.md §29, W5 b, W6 a).
-- Invoker on purpose: the plain inserts run under the caller's RLS, column grants and triggers, so every
-- 3.3 and 4.2 check applies unchanged and nothing is copied here. One call is one transaction.
create function public.create_asset_with_warranty(p_asset jsonb, p_coverages jsonb)
returns uuid language plpgsql security invoker set search_path = '' as $$
declare
  v_asset_id uuid := coalesce((p_asset ->> 'id')::uuid, gen_random_uuid());
  v_asset    jsonb := p_asset || jsonb_build_object('id', v_asset_id);
  v_cols     text;
  v_line     jsonb;
  v_cov_id   uuid;
begin
  if jsonb_typeof(p_coverages) is distinct from 'array' or jsonb_array_length(p_coverages) = 0 then
    raise exception 'coverages: at least one line' using errcode = '22023';
  end if;

  -- The same keys the form sends to a plain insert; an unknown key fails as an unknown column.
  select string_agg(quote_ident(k), ', ') into v_cols from jsonb_object_keys(v_asset) k;
  execute format('insert into public.asset (%s) select %s from jsonb_populate_record(null::public.asset, $1)', v_cols, v_cols)
    using v_asset;

  for v_line in select * from jsonb_array_elements(p_coverages) loop
    if jsonb_typeof(v_line) is distinct from 'object'
       or exists (select 1 from jsonb_object_keys(v_line) k
                  where k not in ('coverage_type', 'vendor_id', 'reference', 'start_date', 'end_date')) then
      raise exception 'coverages: unknown key' using errcode = '22023';
    end if;
    if v_line ->> 'coverage_type' is null or v_line ->> 'coverage_type' not in ('warranty', 'extended_warranty') then
      raise exception 'coverages: type must be warranty or extended_warranty' using errcode = '22023';
    end if;
    v_cov_id := gen_random_uuid();
    insert into public.coverage (id, tenant_id, coverage_type, vendor_id, reference, start_date, end_date)
    values (v_cov_id, (v_asset ->> 'tenant_id')::uuid, v_line ->> 'coverage_type', (v_line ->> 'vendor_id')::uuid,
            v_line ->> 'reference', (v_line ->> 'start_date')::date, (v_line ->> 'end_date')::date);
    insert into public.coverage_asset (tenant_id, coverage_id, asset_id)
    values ((v_asset ->> 'tenant_id')::uuid, v_cov_id, v_asset_id);
  end loop;

  return v_asset_id;
end;
$$;
revoke all on function public.create_asset_with_warranty(jsonb, jsonb) from public, anon;
grant execute on function public.create_asset_with_warranty(jsonb, jsonb) to authenticated;
