-- Story 2.5: tenant settings checks and update_tenant_settings() (S1, S2, S3, M1).
-- Uses the seed (tenant A active, B read_only; a1 in A and B) and supabase/test_harness.sql.
begin;
select plan(22);

select ok(not has_function_privilege('anon', 'public.update_tenant_settings(text, text, text, text, smallint, text[], smallint)', 'execute'), 'anon cannot call');
select ok(not has_table_privilege('authenticated', 'public.tenant', 'update'), 'no update grant on tenant');
select ok(not has_column_privilege('authenticated', 'public.tenant', 'status', 'update'), 'no update grant on tenant.status');

-- No grant: reads own tenant settings (every member needs them), cannot change them.
select tests.act_as('00000000-0000-0000-0000-0000000000a1', '00000000-0000-0000-0000-00000000000a');
select results_eq(
  $$select currency_code::text, locale, time_zone, date_format, fiscal_year_start_month::int, required_asset_fields
    from public.tenant where id = '00000000-0000-0000-0000-00000000000a'$$,
  $$values ('INR', 'en-IN', 'Asia/Kolkata', 'dd-MM-yyyy', 4, '{}'::text[])$$,
  'member without grant reads settings'
);
select throws_ok(
  $$select public.update_tenant_settings('EUR', 'en-GB', 'Europe/London', 'dd/MM/yyyy', 1::smallint, '{}')$$,
  '42501', null, 'no grant, no update'
);

-- view only.
reset role;
select tests.grant('00000000-0000-0000-0000-00000000000a', '00000000-0000-0000-0000-0000000000a1', 'tenant_settings', '{view}');
select tests.act_as('00000000-0000-0000-0000-0000000000a1', '00000000-0000-0000-0000-00000000000a');
select throws_ok(
  $$select public.update_tenant_settings('EUR', 'en-GB', 'Europe/London', 'dd/MM/yyyy', 1::smallint, '{}')$$,
  '42501', null, 'view cannot update'
);

-- manage.
reset role;
select tests.grant('00000000-0000-0000-0000-00000000000a', '00000000-0000-0000-0000-0000000000a1', 'tenant_settings', '{manage}');
select tests.act_as('00000000-0000-0000-0000-0000000000a1', '00000000-0000-0000-0000-00000000000a');
select lives_ok(
  $$select public.update_tenant_settings('EUR', 'en-GB', 'Europe/London', 'dd/MM/yyyy', 1::smallint, '{serial_number,model}')$$,
  'manage updates settings'
);
select results_eq(
  $$select currency_code::text, locale, time_zone, date_format, fiscal_year_start_month::int, required_asset_fields
    from public.tenant where id = '00000000-0000-0000-0000-00000000000a'$$,
  $$values ('EUR', 'en-GB', 'Europe/London', 'dd/MM/yyyy', 1, '{serial_number,model}'::text[])$$,
  'new settings are stored'
);
select lives_ok(
  $$select public.update_tenant_settings('EUR', 'en-GB', 'Europe/London', 'dd/MM/yyyy', 1::smallint, '{serial_number,model}')$$,
  'same values again is fine'
);

-- Bad values.
select throws_ok($$select public.update_tenant_settings('eur', 'en-GB', 'Europe/London', 'dd/MM/yyyy', 1::smallint, '{}')$$,
  '23514', null, 'currency must be 3 capital letters');
select throws_ok($$select public.update_tenant_settings('EUR', 'English', 'Europe/London', 'dd/MM/yyyy', 1::smallint, '{}')$$,
  '23514', null, 'locale must be BCP 47 language[-REGION]');
select throws_ok($$select public.update_tenant_settings('EUR', 'en-GB', 'Mars/Base', 'dd/MM/yyyy', 1::smallint, '{}')$$,
  '22023', null, 'time zone must be an IANA name');
select throws_ok($$select public.update_tenant_settings('EUR', 'en-GB', 'Europe/London', 'd.M.yy', 1::smallint, '{}')$$,
  '23514', null, 'date format must be in the list');
select throws_ok($$select public.update_tenant_settings('EUR', 'en-GB', 'Europe/London', 'dd/MM/yyyy', 13::smallint, '{}')$$,
  '23514', null, 'fiscal month must be 1 to 12');
select throws_ok($$select public.update_tenant_settings('EUR', 'en-GB', 'Europe/London', 'dd/MM/yyyy', 1::smallint, '{colour}')$$,
  '23514', null, 'only optional system fields can be mandatory');

-- Protected columns: no direct writes, even with manage.
select throws_ok($$update public.tenant set status = 'active'$$, '42501', null, 'manage cannot change status directly');
select throws_ok($$update public.tenant set currency_code = 'USD'$$, '42501', null, 'manage cannot bypass the function');

-- Tenant B is read_only (S2).
reset role;
select tests.grant('00000000-0000-0000-0000-00000000000b', '00000000-0000-0000-0000-0000000000a1', 'tenant_settings');
select tests.act_as('00000000-0000-0000-0000-0000000000a1', '00000000-0000-0000-0000-00000000000b');
select throws_ok(
  $$select public.update_tenant_settings('EUR', 'en-GB', 'Europe/London', 'dd/MM/yyyy', 1::smallint, '{}')$$,
  '42501', null, 'read_only tenant cannot update'
);

reset role;
select results_eq(
  $$select name, slug, status, currency_code::text, time_zone from public.tenant order by slug$$,
  $$values ('TEST Tenant A', 'test-tenant-a', 'active', 'EUR', 'Europe/London'),
           ('TEST Tenant B', 'test-tenant-b', 'read_only', 'USD', 'America/New_York')$$,
  'name, slug, status unchanged; other tenant untouched'
);

-- Audit: one row for the real change, none for the no-op.
select results_eq(
  $$select actor_user_id, action, table_name, record_id, old_data ->> 'currency_code', new_data ->> 'currency_code', new_data ? 'updated_at'
    from public.audit_log where table_name = 'tenant'$$,
  $$values ('00000000-0000-0000-0000-0000000000a1'::uuid, 'update', 'tenant', '00000000-0000-0000-0000-00000000000a'::uuid, 'INR', 'EUR', false)$$,
  'one audit row with the changed columns'
);
select is(
  (select count(*)::int from private.outbox_event where event_type = 'tenant.update'
     and aggregate_id = '00000000-0000-0000-0000-00000000000a'),
  1, 'one outbox event'
);
select is(
  (select required_asset_fields from public.tenant where id = '00000000-0000-0000-0000-00000000000b'),
  '{}'::text[], 'mandatory system fields default to none'
);

select * from finish();
rollback;
