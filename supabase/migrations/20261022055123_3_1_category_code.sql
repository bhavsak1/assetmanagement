-- Story 3.1 (A1): optional short code per category, for the {CAT} token in asset tag patterns.
-- The Code field on the category form is story 3.8. Existing policies and grants cover it.
alter table public.asset_category add column code text null
  check (code ~ '^[A-Za-z0-9._-]{1,20}$');
create unique index asset_category_code_uq on public.asset_category (tenant_id, lower(code))
  where code is not null and deleted_at is null;
