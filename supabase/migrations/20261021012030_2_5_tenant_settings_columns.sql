-- Story 2.5: checks on the D2 settings columns, fiscal year start (S3) and tenant-wide mandatory
-- asset system fields (M1). data-model-goal2.md §5. Writes go through update_tenant_settings() (S1).

-- No India default (CLAUDE.md §8): provisioning passes every setting.
alter table public.tenant alter column locale drop default;

-- S3: existing tenants are Indian pilots or test tenants, so April. Then no default.
alter table public.tenant add column fiscal_year_start_month smallint not null default 4
  check (fiscal_year_start_month between 1 and 12);
alter table public.tenant alter column fiscal_year_start_month drop default;

-- M1: optional asset system fields this tenant makes mandatory. 3.1 may change the list
-- with a new migration once the asset columns are final. Minimal by default (CLAUDE.md §10.3).
alter table public.tenant add column required_asset_fields text[] not null default '{}'
  constraint tenant_required_asset_fields_check check (required_asset_fields <@ array[
    'serial_number', 'manufacturer', 'model', 'location', 'purchase_date', 'purchase_value', 'in_service_date'
  ]::text[]);

-- ISO 4217 shape, BCP 47 language[-REGION]. The time zone is checked against pg_timezone_names
-- in update_tenant_settings(): a check constraint cannot read a catalog view.
alter table public.tenant
  add constraint tenant_currency_code_check check (currency_code ~ '^[A-Z]{3}$'),
  add constraint tenant_locale_check check (locale ~ '^[a-z]{2,3}(-[A-Z]{2})?$'),
  add constraint tenant_date_format_check check (date_format in
    ('dd-MM-yyyy', 'dd/MM/yyyy', 'MM/dd/yyyy', 'yyyy-MM-dd', 'dd MMM yyyy'));
