-- Story 2.2: two read-only helpers the web app needs (owner decision, 20 Oct 2026).
-- The UI uses them only to hide or disable actions. RLS on each table stays the real check.

-- The caller's own grants in the active tenant: one row per domain and operation.
-- Owner-run view (not security_invoker) so it can read the private table; the where clause
-- limits it to auth.uid() and the token's tenant, the same rows has_permission() reads.
create view public.my_permission with (security_barrier) as
  select distinct d.code as domain, o.code as operation
  from private.user_effective_permission uep
  join public.domain_operation o on o.id = uep.domain_operation_id
  join public.security_domain d  on d.id = o.security_domain_id
  where uep.tenant_id = (select private.current_tenant_id())
    and uep.user_id   = (select auth.uid())
    and uep.effective_from <= now()
    and (uep.effective_to is null or uep.effective_to > now());
revoke all on public.my_permission from public, anon, authenticated;
grant select on public.my_permission to authenticated;

-- Domains a custom field of p_entity can sit in, for the field form's picker (G6).
-- security_domain itself stays readable only with users_security.view (1.3). Action domains
-- are left out: a field holds data, it is not an action.
create function public.field_domains(p_entity text)
returns table (id uuid, code text)
language sql stable security definer set search_path = '' as $$
  select d.id, d.code
  from public.security_domain d
  where d.entity = p_entity and d.kind in ('entity', 'field')
    and (select private.has_permission('category_config', 'view'))
  order by d.kind, d.code;
$$;
revoke all on function public.field_domains(text) from public, anon;
grant execute on function public.field_domains(text) to authenticated;
