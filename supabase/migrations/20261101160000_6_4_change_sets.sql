-- Story 6.4: draft, review and activate group policy changes (docs/data-model-goal6.md §27).
-- Owner accepted C1 to C8 on 1 Nov 2026. OQ-22 lean used: single approver, the drafter may activate (C3).
-- OWNER REVIEW (CLAUDE.md §9): every function here and the dropped group_domain_policy write policies.
-- Activation replays the draft through the live writes, so rebuild, permission_version bump, row audit and
-- the 6.3 lock-out guard are the existing 1.3, 1.5, 1.7 and 6.3 triggers.

-- One open draft per tenant [C4]; activated and discarded sets stay as history [C8].
create table public.policy_change_set (
  id           uuid primary key default gen_random_uuid(),
  tenant_id    uuid not null references public.tenant (id),
  status       text not null default 'draft' check (status in ('draft', 'activated', 'discarded')),
  activated_by uuid null references public.user_profile (id),
  activated_at timestamptz null,
  created_at   timestamptz not null default now(),
  updated_at   timestamptz not null default now(),
  created_by   uuid null references public.user_profile (id),
  updated_by   uuid null references public.user_profile (id),
  deleted_at   timestamptz null,
  unique (tenant_id, id)
);
create unique index policy_change_set_draft_uq on public.policy_change_set (tenant_id) where status = 'draft';

-- The group's whole wanted set [C5]; before_ids is the live set at activation, for history [C8].
create table public.policy_change_set_item (
  id                   uuid primary key default gen_random_uuid(),
  tenant_id            uuid not null references public.tenant (id),
  policy_change_set_id uuid not null,
  security_group_id    uuid not null,
  operation_ids        uuid[] not null,
  before_ids           uuid[] null,
  created_at           timestamptz not null default now(),
  updated_at           timestamptz not null default now(),
  created_by           uuid null references public.user_profile (id),
  updated_by           uuid null references public.user_profile (id),
  deleted_at           timestamptz null,
  unique (tenant_id, id),
  foreign key (tenant_id, policy_change_set_id) references public.policy_change_set (tenant_id, id),
  foreign key (tenant_id, security_group_id) references public.security_group (tenant_id, id)
);
create unique index policy_change_set_item_group_uq on public.policy_change_set_item (policy_change_set_id, security_group_id)
  where deleted_at is null;

create trigger set_updated_at before update on public.policy_change_set
  for each row execute function private.set_updated_at();
create trigger set_updated_at before update on public.policy_change_set_item
  for each row execute function private.set_updated_at();
create trigger audit after insert or update or delete on public.policy_change_set
  for each row execute function private.audit_row('security');
create trigger audit after insert or update or delete on public.policy_change_set_item
  for each row execute function private.audit_row('security');

-- Read with users_security.view. No write policies or grants: the functions below are the only writers [C2].
alter table public.policy_change_set enable row level security;
alter table public.policy_change_set_item enable row level security;
create policy policy_change_set_select on public.policy_change_set
  for select to authenticated
  using (tenant_id = (select private.current_tenant_id())
         and (select private.has_permission('users_security', 'view')));
create policy policy_change_set_item_select on public.policy_change_set_item
  for select to authenticated
  using (tenant_id = (select private.current_tenant_id())
         and (select private.has_permission('users_security', 'view')));
revoke insert, update, delete, truncate on public.policy_change_set, public.policy_change_set_item from anon, authenticated;

-- Live grants change only through activation [C2]. The select policy stays; with no write policy an insert
-- is refused and an update touches no row, as for the Auditor today.
drop policy group_domain_policy_insert on public.group_domain_policy;
drop policy group_domain_policy_update on public.group_domain_policy;

-- Shared checks for the three actions: manage, a writable tenant.
create function private.check_security_manage()
returns void language plpgsql stable set search_path = '' as $$
begin
  if not (private.has_permission('users_security', 'manage') and private.tenant_can_write()) then
    raise exception 'not allowed' using errcode = '42501';
  end if;
end;
$$;
revoke all on function private.check_security_manage() from public, anon, authenticated;

-- The 6.3 grid write path, now writing the tenant's draft. Same signature, so the screen's call is unchanged.
-- Definer, because tenants no longer write these tables; so the tenant is checked here, not by RLS.
-- Saving the live set removes the group's item (this is also "revert").
create or replace function public.set_group_policies(p_group_id uuid, p_operation_ids uuid[])
returns void language plpgsql security definer set search_path = '' as $$
declare
  v_tenant uuid := private.current_tenant_id();
  v_ids    uuid[];
  v_live   uuid[];
  v_set    uuid;
begin
  perform private.check_security_manage();
  if not exists (select 1 from public.security_group g
                 where g.id = p_group_id and g.tenant_id = v_tenant and g.deleted_at is null) then
    raise exception 'group not found' using errcode = 'P0002';
  end if;
  if exists (select 1 from public.security_group g where g.id = p_group_id and g.group_type = 'system') then
    raise exception 'system groups cannot be edited' using errcode = '42501';
  end if;

  -- Sorted and limited to real operations, so it compares with the live set.
  v_ids := coalesce((select array_agg(o.id order by o.id) from public.domain_operation o where o.id = any (p_operation_ids)), '{}');
  v_live := coalesce((select array_agg(p.domain_operation_id order by p.domain_operation_id) from public.group_domain_policy p
                      where p.security_group_id = p_group_id and p.deleted_at is null), '{}');
  select id into v_set from public.policy_change_set where tenant_id = v_tenant and status = 'draft' for update;

  if v_ids = v_live then
    update public.policy_change_set_item set deleted_at = now(), updated_by = auth.uid()
    where policy_change_set_id = v_set and security_group_id = p_group_id and deleted_at is null;
    return;
  end if;

  if v_set is null then
    insert into public.policy_change_set (tenant_id, created_by, updated_by)
    values (v_tenant, auth.uid(), auth.uid())
    on conflict (tenant_id) where status = 'draft' do nothing;
    select id into v_set from public.policy_change_set where tenant_id = v_tenant and status = 'draft' for update;
  end if;

  insert into public.policy_change_set_item (tenant_id, policy_change_set_id, security_group_id, operation_ids, created_by, updated_by)
  values (v_tenant, v_set, p_group_id, v_ids, auth.uid(), auth.uid())
  on conflict (policy_change_set_id, security_group_id) where deleted_at is null
  do update set operation_ids = excluded.operation_ids, updated_by = excluded.updated_by;
end;
$$;

-- The diff for review and history [C7, C8]: wanted vs live for a draft, wanted vs before_ids once activated.
-- Invoker: RLS (users_security.view) decides what it reads. Items of deleted groups drop out of a draft [C6].
create function public.change_set_diff(p_change_set_id uuid)
returns table (security_group_id uuid, group_name text, domain_code text, operation_code text, change text)
language sql stable security invoker set search_path = '' as $$
  with i as (
    select i.security_group_id, g.name, i.operation_ids,
           coalesce(i.before_ids, (select coalesce(array_agg(p.domain_operation_id), '{}') from public.group_domain_policy p
                                   where p.security_group_id = i.security_group_id and p.deleted_at is null)) as base
    from public.policy_change_set_item i
    join public.policy_change_set cs on cs.id = i.policy_change_set_id
    join public.security_group g on g.id = i.security_group_id
    where i.policy_change_set_id = p_change_set_id and i.deleted_at is null
      and (cs.status <> 'draft' or g.deleted_at is null)
  ), d as (
    select i.security_group_id, i.name, op, 'add' as change from i, unnest(i.operation_ids) op where op <> all (i.base)
    union all
    select i.security_group_id, i.name, op, 'remove' from i, unnest(i.base) op where op <> all (i.operation_ids)
  )
  select d.security_group_id, d.name, sd.code, o.code, d.change
  from d
  join public.domain_operation o on o.id = d.op
  join public.security_domain sd on sd.id = o.security_domain_id
  order by d.name, sd.code, o.sort_order;
$$;
revoke all on function public.change_set_diff(uuid) from public, anon;
grant execute on function public.change_set_diff(uuid) to authenticated;

-- Activate [C3: any manager, the drafter too]. One transaction; the triggers rebuild, bump, audit, and the
-- deferred lock-out guard rolls everything back at commit if no security manager would be left.
create function public.activate_change_set(p_change_set_id uuid)
returns void language plpgsql security definer set search_path = '' as $$
begin
  perform private.check_security_manage();
  perform 1 from public.policy_change_set
  where id = p_change_set_id and tenant_id = private.current_tenant_id() and status = 'draft' for update;
  if not found then
    raise exception 'change set is not an open draft' using errcode = 'P0002';
  end if;

  -- [C6] a group deleted since it was drafted has nothing to apply.
  update public.policy_change_set_item i set deleted_at = now(), updated_by = auth.uid()
  from public.security_group g
  where i.policy_change_set_id = p_change_set_id and i.deleted_at is null
    and g.id = i.security_group_id and g.deleted_at is not null;

  update public.policy_change_set_item i
  set before_ids = (select coalesce(array_agg(p.domain_operation_id order by p.domain_operation_id), '{}')
                    from public.group_domain_policy p where p.security_group_id = i.security_group_id and p.deleted_at is null),
      updated_by = auth.uid()
  where i.policy_change_set_id = p_change_set_id and i.deleted_at is null;

  -- The 6.3 diff, for every item at once: unchanged grants keep their row.
  update public.group_domain_policy p set deleted_at = now()
  from public.policy_change_set_item i
  where i.policy_change_set_id = p_change_set_id and i.deleted_at is null
    and p.security_group_id = i.security_group_id and p.deleted_at is null
    and p.domain_operation_id <> all (i.operation_ids);

  insert into public.group_domain_policy (tenant_id, security_group_id, domain_operation_id)
  select i.tenant_id, i.security_group_id, op
  from public.policy_change_set_item i, unnest(i.operation_ids) op
  where i.policy_change_set_id = p_change_set_id and i.deleted_at is null
    and not exists (select 1 from public.group_domain_policy p
                    where p.security_group_id = i.security_group_id and p.domain_operation_id = op and p.deleted_at is null);

  update public.policy_change_set
  set status = 'activated', activated_by = auth.uid(), activated_at = now(), updated_by = auth.uid()
  where id = p_change_set_id;
end;
$$;
revoke all on function public.activate_change_set(uuid) from public, anon;
grant execute on function public.activate_change_set(uuid) to authenticated;

-- Discard: nothing applied; the next save opens a fresh draft.
create function public.discard_change_set(p_change_set_id uuid)
returns void language plpgsql security definer set search_path = '' as $$
begin
  perform private.check_security_manage();
  update public.policy_change_set set status = 'discarded', updated_by = auth.uid()
  where id = p_change_set_id and tenant_id = private.current_tenant_id() and status = 'draft';
  if not found then
    raise exception 'change set is not an open draft' using errcode = 'P0002';
  end if;
end;
$$;
revoke all on function public.discard_change_set(uuid) from public, anon;
grant execute on function public.discard_change_set(uuid) to authenticated;
