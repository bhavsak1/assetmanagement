-- Story 3.1: two new asset operations, as data (CLAUDE.md §7.10). data-model-goal3.md A1, A3.
--   asset_core.set_tag       type or change an asset tag instead of the generated one (B9)
--   asset_lifecycle.reopen   bring a disposed asset back, with a reason (OQ-04 lean)
insert into public.domain_operation (security_domain_id, code, sort_order)
select d.id, o.code, o.sort_order
from (values ('asset_core', 'set_tag', 5), ('asset_lifecycle', 'reopen', 2)) as o (domain_code, code, sort_order)
join public.security_domain d on d.code = o.domain_code
on conflict (security_domain_id, code) do nothing;

-- Same function as 1.6 with the new grid cells: set_tag to Tenant Admin and Plant Manager,
-- reopen to Tenant Admin. The owner-review copy is docs/data-model-goal1.md §2.7a.
create or replace function private.seed_starter_groups(p_tenant_id uuid)
returns void language sql set search_path = '' as $$
  with grid (domain_code, tenant_admin, plant_manager, planner, technician, auditor) as (values
    --                     Tenant Admin                                  Plant Manager                                 Planner                               Technician                            Auditor
    ('asset_core',         '{view,create,update,delete,set_tag}'::text[], '{view,create,update,delete,set_tag}'::text[], '{view,update}'::text[],              '{view}'::text[],                     '{view}'::text[]),
    ('asset_financials',   '{view,update}',                              '{view}',                                     '{}',                                 '{}',                                 '{view}'),
    ('asset_lifecycle',    '{execute,reopen}',                           '{execute}',                                  '{}',                                 '{}',                                 '{}'),
    ('vendor_core',        '{view,create,update,delete}',                '{view,create,update}',                       '{view}',                             '{view}',                             '{view}'),
    ('vendor_tax_ids',     '{view,update}',                              '{view}',                                     '{}',                                 '{}',                                 '{view}'),
    ('coverage_contract',  '{view,create,update,delete}',                '{view,create,update}',                       '{view,create,update}',               '{view}',                             '{view}'),
    ('coverage_values',    '{view,update}',                              '{view}',                                     '{}',                                 '{}',                                 '{view}'),
    ('obligation',         '{view,create,update,complete}',              '{view,create,update,complete}',              '{view,create,update,complete}',      '{view,complete}',                    '{view}'),
    ('service_record',     '{view,create,update,complete}',              '{view,create,update,complete}',              '{view,create,update,complete}',      '{view,create,update,complete}',      '{view}'),
    ('location_hierarchy', '{view,manage}',                              '{view,manage}',                              '{view}',                             '{view}',                             '{view}'),
    ('category_config',    '{view,manage}',                              '{view}',                                     '{view}',                             '{view}',                             '{view}'),
    ('excel_import',       '{run,review,commit}',                        '{run,review,commit}',                        '{run,review}',                       '{}',                                 '{}'),
    ('import_undo',        '{undo}',                                     '{undo}',                                     '{}',                                 '{}',                                 '{}'),
    ('users_security',     '{view,manage}',                              '{}',                                         '{}',                                 '{}',                                 '{view}'),
    ('api_keys',           '{view,manage}',                              '{}',                                         '{}',                                 '{}',                                 '{view}'),
    ('audit_log',          '{view}',                                     '{view}',                                     '{}',                                 '{}',                                 '{view}'),
    ('tenant_settings',    '{view,manage}',                              '{view}',                                     '{}',                                 '{}',                                 '{view}'),
    ('ai_usage',           '{view,manage}',                              '{view}',                                     '{}',                                 '{}',                                 '{view}'),
    ('insights_query',     '{ask}',                                      '{ask}',                                      '{ask}',                              '{}',                                 '{}'),
    ('insights_widget',    '{save,share}',                               '{save,share}',                               '{save}',                             '{}',                                 '{}')
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

-- Backfill the new cells into starter groups that already exist (staging pilots, local seed).
-- Live groups only; the policy triggers rebuild each member's permissions.
insert into public.group_domain_policy (tenant_id, security_group_id, domain_operation_id)
select g.tenant_id, g.id, o.id
from (values ('starter.tenant_admin', 'asset_core', 'set_tag'),
             ('starter.plant_manager', 'asset_core', 'set_tag'),
             ('starter.tenant_admin', 'asset_lifecycle', 'reopen')) as v (template_code, domain_code, op_code)
join public.security_group g on g.template_code = v.template_code and g.deleted_at is null
join public.security_domain d on d.code = v.domain_code
join public.domain_operation o on o.security_domain_id = d.id and o.code = v.op_code
where not exists (select 1 from public.group_domain_policy p
                  where p.security_group_id = g.id and p.domain_operation_id = o.id);
