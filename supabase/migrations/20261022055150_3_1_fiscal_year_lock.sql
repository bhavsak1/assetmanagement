-- Story 3.1 (handed over by 2.5 S3): the fiscal year start locks once the tenant has an asset,
-- soft-deleted ones included (open-items section A: "fiscal year locks after the first asset").
create function private.check_fiscal_year_lock()
returns trigger language plpgsql security definer set search_path = '' as $$
begin
  if exists (select 1 from public.asset a where a.tenant_id = new.id) then
    raise exception 'fiscal year start cannot change once the tenant has assets' using errcode = '23514';
  end if;
  return new;
end;
$$;
revoke all on function private.check_fiscal_year_lock() from public, anon, authenticated;

create trigger check_fiscal_year_lock before update of fiscal_year_start_month on public.tenant
  for each row when (old.fiscal_year_start_month is distinct from new.fiscal_year_start_month)
  execute function private.check_fiscal_year_lock();
