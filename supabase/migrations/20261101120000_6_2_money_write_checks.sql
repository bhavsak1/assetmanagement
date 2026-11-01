-- Story 6.2, R1 (data-model-goal6.md §15 G1, §16): close the equality oracle on masked money columns.
-- Before, a user without the field's view could send a guess: same as stored passed, different raised.
-- Now, on update, a user without view keeps the stored value silently (as hidden custom keys do), so the
-- check_* triggers see no change. View but no update still raises there. Insert is unchanged (nothing to probe).
-- Args: the field domain, then the columns it masks.
create function private.keep_masked_values()
returns trigger language plpgsql security definer set search_path = '' as $$
declare
  v_old jsonb := to_jsonb(old);
begin
  if auth.uid() is not null and not private.has_permission(tg_argv[0], 'view') then
    new := jsonb_populate_record(new, (select jsonb_object_agg(c, v_old -> c) from unnest(tg_argv[1:]) c));
  end if;
  return new;
end;
$$;
revoke all on function private.keep_masked_values() from public, anon, authenticated;

-- Before triggers fire in name order: the a_ prefix runs this before check_asset_values_update,
-- check_coverage and check_service_record. Owner review item.
create trigger a_keep_masked_values before update of purchase_value, purchase_currency on public.asset
  for each row execute function private.keep_masked_values('asset_financials', 'purchase_value', 'purchase_currency');
create trigger a_keep_masked_values before update of contract_value, contract_currency on public.coverage
  for each row execute function private.keep_masked_values('coverage_values', 'contract_value', 'contract_currency');
create trigger a_keep_masked_values before update of cost_amount, cost_currency on public.service_record
  for each row execute function private.keep_masked_values('service_values', 'cost_amount', 'cost_currency');
