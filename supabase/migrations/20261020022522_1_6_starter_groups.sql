-- Story 1.6: starter groups (OQ-25 lean: draft catalog and starter groups in M1).
-- One grid, group by domain by operations. The owner-review copy is docs/data-model-goal1.md §2.7a.
-- Provisioning (run as postgres, OQ-16) calls private.seed_starter_groups(tenant_id) once per new tenant.
-- Groups are tenant rows with template_code 'starter.<code>' (data-model §2.7). Tenants edit them freely.
-- rls_sample (1.4 template) is in no group on purpose: it is not business data.

create function private.seed_starter_groups(p_tenant_id uuid)
returns void language sql set search_path = '' as $$
  with grid (domain_code, tenant_admin, plant_manager, planner, technician, auditor) as (values
    --                     Tenant Admin                          Plant Manager                         Planner                               Technician                            Auditor
    ('asset_core',         '{view,create,update,delete}'::text[], '{view,create,update,delete}'::text[], '{view,update}'::text[],              '{view}'::text[],                     '{view}'::text[]),
    ('asset_financials',   '{view,update}',                      '{view}',                             '{}',                                 '{}',                                 '{view}'),
    ('asset_lifecycle',    '{execute}',                          '{execute}',                          '{}',                                 '{}',                                 '{}'),
    ('vendor_core',        '{view,create,update,delete}',        '{view,create,update}',               '{view}',                             '{view}',                             '{view}'),
    ('vendor_tax_ids',     '{view,update}',                      '{view}',                             '{}',                                 '{}',                                 '{view}'),
    ('coverage_contract',  '{view,create,update,delete}',        '{view,create,update}',               '{view,create,update}',               '{view}',                             '{view}'),
    ('coverage_values',    '{view,update}',                      '{view}',                             '{}',                                 '{}',                                 '{view}'),
    ('obligation',         '{view,create,update,complete}',      '{view,create,update,complete}',      '{view,create,update,complete}',      '{view,complete}',                    '{view}'),
    ('service_record',     '{view,create,update,complete}',      '{view,create,update,complete}',      '{view,create,update,complete}',      '{view,create,update,complete}',      '{view}'),
    ('location_hierarchy', '{view,manage}',                      '{view,manage}',                      '{view}',                             '{view}',                             '{view}'),
    ('category_config',    '{view,manage}',                      '{view}',                             '{view}',                             '{view}',                             '{view}'),
    ('excel_import',       '{run,review,commit}',                '{run,review,commit}',                '{run,review}',                       '{}',                                 '{}'),
    ('import_undo',        '{undo}',                             '{undo}',                             '{}',                                 '{}',                                 '{}'),
    ('users_security',     '{view,manage}',                      '{}',                                 '{}',                                 '{}',                                 '{view}'),
    ('api_keys',           '{view,manage}',                      '{}',                                 '{}',                                 '{}',                                 '{view}'),
    ('audit_log',          '{view}',                             '{view}',                             '{}',                                 '{}',                                 '{view}'),
    ('tenant_settings',    '{view,manage}',                      '{view}',                             '{}',                                 '{}',                                 '{view}'),
    ('ai_usage',           '{view,manage}',                      '{view}',                             '{}',                                 '{}',                                 '{view}'),
    ('insights_query',     '{ask}',                              '{ask}',                              '{ask}',                              '{}',                                 '{}'),
    ('insights_widget',    '{save,share}',                       '{save,share}',                       '{save}',                             '{}',                                 '{}')
  ),
  starter (code, name, description) as (values
    ('tenant_admin',  'Tenant Admin',  'Users, security and tenant settings, plus full data access'),
    ('plant_manager', 'Plant Manager', 'Runs the asset register, vendors, contracts and imports for the plant'),
    ('planner',       'Planner',       'Plans maintenance: obligations, service records and contracts'),
    ('technician',    'Technician',    'Does the work: completes obligations and logs service records'),
    ('auditor',       'Auditor',       'Read-only everywhere it has access')
  ),
  -- Idempotent: a template already used in this tenant (even if since edited or soft-deleted) is skipped.
  new_group as (
    insert into public.security_group (tenant_id, code, name, template_code, description)
    select p_tenant_id, s.code, s.name, 'starter.' || s.code, s.description
    from starter s
    where not exists (select 1 from public.security_group g
                      where g.tenant_id = p_tenant_id and g.template_code = 'starter.' || s.code)
    returning id, code
  )
  insert into public.group_domain_policy (tenant_id, security_group_id, domain_operation_id)
  select p_tenant_id, ng.id, o.id
  from new_group ng
  cross join grid
  join public.security_domain d  on d.code = grid.domain_code
  join public.domain_operation o on o.security_domain_id = d.id
  -- The grid column named after the group holds its operations for that domain.
  where o.code in (select jsonb_array_elements_text(to_jsonb(grid) -> ng.code));
$$;
revoke all on function private.seed_starter_groups(uuid) from public, anon, authenticated;
