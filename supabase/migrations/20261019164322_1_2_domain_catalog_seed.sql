-- Story 1.2: draft default domain catalog (OQ-25 lean: draft in M1). From security-model.md §4,
-- Phase 1 only. Codes are never renamed once shipped. Labels are translated in the UI by code.
-- In a function so re-running it can be tested: on conflict do nothing, so no duplicates.
create function private.seed_domain_catalog()
returns void language sql set search_path = '' as $$
  insert into public.security_domain (code, entity, kind, description) values
    ('asset_core',         'asset',     'entity',   'Asset register records'),
    ('asset_financials',   'asset',     'field',    'Asset purchase value and other money fields'),
    ('asset_lifecycle',    'asset',     'action',   'Asset lifecycle actions such as transfer and retire'),
    ('vendor_core',        'vendor',    'entity',   'Vendor records and contacts'),
    ('vendor_tax_ids',     'vendor',    'field',    'Vendor tax and statutory IDs'),
    ('coverage_contract',  'coverage',  'entity',   'Warranty and AMC contracts'),
    ('coverage_values',    'coverage',  'field',    'Contract values and rates'),
    ('obligation',         'obligation','entity',   'Service obligations and schedules'),
    ('service_record',     'service',   'entity',   'Service records'),
    ('location_hierarchy', 'location',  'entity',   'Location hierarchy'),
    ('category_config',    'category',  'entity',   'Categories and field configuration'),
    ('excel_import',       'import',    'action',   'Excel import'),
    ('import_undo',        'import',    'action',   'Undo a committed import'),
    ('users_security',     'platform',  'platform', 'Users, groups and security policies'),
    ('api_keys',           'platform',  'platform', 'API keys'),
    ('audit_log',          'platform',  'platform', 'Audit log'),
    ('tenant_settings',    'platform',  'platform', 'Tenant settings'),
    ('ai_usage',           'platform',  'platform', 'AI usage and add-on'),
    ('insights_query',     'insights',  'action',   'Query-based insights'),
    ('insights_widget',    'insights',  'entity',   'Saved insight widgets')
  on conflict (code) do nothing;

  insert into public.domain_operation (security_domain_id, code, sort_order)
  select d.id, o.code, o.sort_order
  from (values
    ('asset_core', 'view', 1), ('asset_core', 'create', 2), ('asset_core', 'update', 3), ('asset_core', 'delete', 4),
    ('asset_financials', 'view', 1), ('asset_financials', 'update', 2),
    ('asset_lifecycle', 'execute', 1),
    ('vendor_core', 'view', 1), ('vendor_core', 'create', 2), ('vendor_core', 'update', 3), ('vendor_core', 'delete', 4),
    ('vendor_tax_ids', 'view', 1), ('vendor_tax_ids', 'update', 2),
    ('coverage_contract', 'view', 1), ('coverage_contract', 'create', 2), ('coverage_contract', 'update', 3), ('coverage_contract', 'delete', 4),
    ('coverage_values', 'view', 1), ('coverage_values', 'update', 2),
    ('obligation', 'view', 1), ('obligation', 'create', 2), ('obligation', 'update', 3), ('obligation', 'complete', 4),
    ('service_record', 'view', 1), ('service_record', 'create', 2), ('service_record', 'update', 3), ('service_record', 'complete', 4),
    ('location_hierarchy', 'view', 1), ('location_hierarchy', 'manage', 2),
    ('category_config', 'view', 1), ('category_config', 'manage', 2),
    ('excel_import', 'run', 1), ('excel_import', 'review', 2), ('excel_import', 'commit', 3),
    ('import_undo', 'undo', 1),
    ('users_security', 'view', 1), ('users_security', 'manage', 2),
    ('api_keys', 'view', 1), ('api_keys', 'manage', 2),
    -- view only: the log is append-only, so manage would grant nothing (data-model §2.12).
    ('audit_log', 'view', 1),
    ('tenant_settings', 'view', 1), ('tenant_settings', 'manage', 2),
    ('ai_usage', 'view', 1), ('ai_usage', 'manage', 2),
    ('insights_query', 'ask', 1),
    ('insights_widget', 'save', 1), ('insights_widget', 'share', 2)
  ) as o (domain_code, code, sort_order)
  join public.security_domain d on d.code = o.domain_code
  on conflict (security_domain_id, code) do nothing;
$$;
revoke all on function private.seed_domain_catalog() from public, anon, authenticated;

select private.seed_domain_catalog();
