-- Story 5.6: read-only check for scripts/demo-tenant.sql. Run as postgres before and after a run:
-- the non-demo rows must not change; the demo rows must match the targets in docs/data-model-goal5.md §15.2.

-- 1. Rows per tenant (every tenant). Compare the non-demo lines before and after.
select t.slug, t.status,
  (select count(*) from public.asset x where x.tenant_id = t.id) as assets,
  (select count(*) from public.obligation x where x.tenant_id = t.id) as obligations,
  (select count(*) from public.service_record x where x.tenant_id = t.id) as service_records,
  (select count(*) from public.coverage x where x.tenant_id = t.id) as coverage,
  (select count(*) from public.vendor x where x.tenant_id = t.id) as vendors,
  (select count(*) from public.location x where x.tenant_id = t.id) as locations,
  (select count(*) from public.asset_category x where x.tenant_id = t.id) as categories,
  (select count(*) from public.tenant_membership x where x.tenant_id = t.id and x.status = 'active') as active_members,
  (select count(*) from public.audit_log x where x.tenant_id = t.id) as audit_rows
from public.tenant t order by t.slug;

-- 2. The live demo tenant: assets per status, obligations per state, assets per coverage state.
select 'asset' as what, status as bucket, count(*) from public.asset
where tenant_id = (select id from public.tenant where slug = 'demo-manufacturing') group by status
union all
select 'obligation', due_state, count(*) from public.obligation
where tenant_id = (select id from public.tenant where slug = 'demo-manufacturing') group by due_state
union all
select 'coverage_state', coalesce(coverage_state, '(null)'), count(*) from public.asset
where tenant_id = (select id from public.tenant where slug = 'demo-manufacturing') group by coverage_state
order by 1, 2;

-- 3. Demo logins: each demo email has exactly one active membership, in the demo tenant, with its starter group.
select u.email, t.slug, m.status, string_agg(g.template_code, ', ') as groups
from auth.users u
join public.tenant_membership m on m.user_id = u.id
join public.tenant t on t.id = m.tenant_id
left join public.user_group_assignment a on a.tenant_id = m.tenant_id and a.user_id = u.id and a.deleted_at is null
left join public.security_group g on g.id = a.security_group_id
where u.email like 'bhavsar.krunal.h+demo-%@gmail.com' and m.status = 'active'
group by u.email, t.slug, m.status order by u.email;
