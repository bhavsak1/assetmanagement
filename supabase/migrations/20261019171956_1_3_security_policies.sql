-- Story 1.3: RLS policies that waited for has_permission() and tenant_can_write().
-- Reads need users_security.view, writes need users_security.manage plus tenant_can_write(),
-- always in the current tenant. Separate insert and update policies (CLAUDE.md §7.4).
-- No delete policies: soft delete only (CLAUDE.md §8), so delete is revoked and a removal is an
-- update of deleted_at. Audit triggers come in 1.5.

-- Catalog: security admins only (owner decision, 19 Oct 2026). Still no user writes.
create policy security_domain_select on public.security_domain
  for select to authenticated
  using ((select private.has_permission('users_security', 'view')));
create policy domain_operation_select on public.domain_operation
  for select to authenticated
  using ((select private.has_permission('users_security', 'view')));

-- security_group. System groups (owner, billing) cannot be edited by the tenant (§2.7).
create policy security_group_select on public.security_group
  for select to authenticated
  using (tenant_id = (select private.current_tenant_id())
         and (select private.has_permission('users_security', 'view')));
create policy security_group_insert on public.security_group
  for insert to authenticated
  with check (tenant_id = (select private.current_tenant_id())
              and (select private.has_permission('users_security', 'manage'))
              and (select private.tenant_can_write())
              and group_type <> 'system');
create policy security_group_update on public.security_group
  for update to authenticated
  using (tenant_id = (select private.current_tenant_id())
         and (select private.has_permission('users_security', 'manage'))
         and (select private.tenant_can_write())
         and group_type <> 'system')
  with check (tenant_id = (select private.current_tenant_id())
              and (select private.has_permission('users_security', 'manage'))
              and (select private.tenant_can_write())
              and group_type <> 'system');

-- group_domain_policy. A system group's grants are part of the group, so they are not editable either.
-- The group check reads security_group under RLS, so it also needs view: fails closed.
create policy group_domain_policy_select on public.group_domain_policy
  for select to authenticated
  using (tenant_id = (select private.current_tenant_id())
         and (select private.has_permission('users_security', 'view')));
create policy group_domain_policy_insert on public.group_domain_policy
  for insert to authenticated
  with check (tenant_id = (select private.current_tenant_id())
              and (select private.has_permission('users_security', 'manage'))
              and (select private.tenant_can_write())
              and exists (select 1 from public.security_group g
                          where g.tenant_id = group_domain_policy.tenant_id
                            and g.id = group_domain_policy.security_group_id
                            and g.group_type <> 'system'));
create policy group_domain_policy_update on public.group_domain_policy
  for update to authenticated
  using (tenant_id = (select private.current_tenant_id())
         and (select private.has_permission('users_security', 'manage'))
         and (select private.tenant_can_write())
         and exists (select 1 from public.security_group g
                     where g.tenant_id = group_domain_policy.tenant_id
                       and g.id = group_domain_policy.security_group_id
                       and g.group_type <> 'system'))
  with check (tenant_id = (select private.current_tenant_id())
              and (select private.has_permission('users_security', 'manage'))
              and (select private.tenant_can_write())
              and exists (select 1 from public.security_group g
                          where g.tenant_id = group_domain_policy.tenant_id
                            and g.id = group_domain_policy.security_group_id
                            and g.group_type <> 'system'));

-- user_group_assignment.
create policy user_group_assignment_select on public.user_group_assignment
  for select to authenticated
  using (tenant_id = (select private.current_tenant_id())
         and (select private.has_permission('users_security', 'view')));
create policy user_group_assignment_insert on public.user_group_assignment
  for insert to authenticated
  with check (tenant_id = (select private.current_tenant_id())
              and (select private.has_permission('users_security', 'manage'))
              and (select private.tenant_can_write()));
create policy user_group_assignment_update on public.user_group_assignment
  for update to authenticated
  using (tenant_id = (select private.current_tenant_id())
         and (select private.has_permission('users_security', 'manage'))
         and (select private.tenant_can_write()))
  with check (tenant_id = (select private.current_tenant_id())
              and (select private.has_permission('users_security', 'manage'))
              and (select private.tenant_can_write()));

revoke delete, truncate on public.security_group, public.group_domain_policy, public.user_group_assignment
  from anon, authenticated;

-- tenant_membership (§2.3): admins read and write members of the current tenant. Own-row read stays.
create policy tenant_membership_select_admin on public.tenant_membership
  for select to authenticated
  using (tenant_id = (select private.current_tenant_id())
         and (select private.has_permission('users_security', 'view')));
create policy tenant_membership_insert_admin on public.tenant_membership
  for insert to authenticated
  with check (tenant_id = (select private.current_tenant_id())
              and (select private.has_permission('users_security', 'manage'))
              and (select private.tenant_can_write()));
create policy tenant_membership_update_admin on public.tenant_membership
  for update to authenticated
  using (tenant_id = (select private.current_tenant_id())
         and (select private.has_permission('users_security', 'manage'))
         and (select private.tenant_can_write()))
  with check (tenant_id = (select private.current_tenant_id())
              and (select private.has_permission('users_security', 'manage'))
              and (select private.tenant_can_write()));
-- RLS cannot hide columns: permission_version is set only by the rebuild triggers.
revoke insert, update, delete, truncate on public.tenant_membership from anon, authenticated;
grant insert (tenant_id, user_id, status) on public.tenant_membership to authenticated;
grant update (status, deleted_at) on public.tenant_membership to authenticated;

-- tenant_entitlement: swap the 1.1 inline claim read for the helper.
drop policy tenant_entitlement_select_current on public.tenant_entitlement;
create policy tenant_entitlement_select_current on public.tenant_entitlement
  for select to authenticated
  using (
    tenant_id = (select private.current_tenant_id())
    and exists (
      select 1 from public.tenant_membership m
      where m.tenant_id = tenant_entitlement.tenant_id
        and m.user_id = (select auth.uid())
        and m.status = 'active' and m.deleted_at is null
    )
  );
