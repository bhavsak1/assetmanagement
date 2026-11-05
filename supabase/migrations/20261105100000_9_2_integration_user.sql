-- Story 9.2: integration users (docs/data-model-goal9.md §17 A1, A2, A7, A12). Owner accepted the leans, 5 Nov 2026.
-- OWNER REVIEW (CLAUDE.md §9): writes to auth.users (Auth), every security definer function, the changed
-- last-admin guard and fan-out.
-- An integration user is an ordinary identity (auth.users + user_profile + tenant_membership) that cannot sign
-- in, so groups, scope, secure views, audit and the explainer work for it unchanged.

alter table public.user_profile
  add column kind text not null default 'person' check (kind in ('person', 'integration'));

-- A7: which API key made a change. Set from the claims the service sets (withKey); null for the web app.
alter table public.audit_log add column api_key_id uuid null;
grant select (api_key_id) on public.audit_log to authenticated;

-- Same body as 1.5, plus api_key_id.
create or replace function private.audit_row()
returns trigger language plpgsql security definer set search_path = '' as $$
declare
  v_old    jsonb := case when tg_op <> 'INSERT' then to_jsonb(old) end;
  v_new    jsonb := case when tg_op <> 'DELETE' then to_jsonb(new) end;
  v_row    jsonb := coalesce(v_new, v_old);
  v_actor  uuid  := auth.uid();
  v_action text  := case
    when tg_op = 'INSERT' then 'insert'
    when tg_op = 'DELETE' then 'delete'
    when v_old ->> 'deleted_at' is null and v_new ->> 'deleted_at' is not null then 'soft_delete'
    else 'update' end;
begin
  -- An update keeps only the changed columns (§2.12).
  if tg_op = 'UPDATE' then
    select jsonb_object_agg(o.key, o.value), jsonb_object_agg(o.key, v_new -> o.key)
      into v_old, v_new
    from jsonb_each(v_old) o
    where o.value is distinct from v_new -> o.key;
  end if;

  insert into public.audit_log (tenant_id, category, actor_type, actor_user_id, action, table_name, record_id,
                                old_data, new_data, api_key_id)
  values ((v_row ->> 'tenant_id')::uuid, tg_argv[0], case when v_actor is null then 'system' else 'user' end, v_actor,
          v_action, tg_table_name, (v_row ->> 'id')::uuid, v_old, v_new, nullif(auth.jwt() ->> 'api_key_id', '')::uuid);

  insert into private.outbox_event (tenant_id, event_type, aggregate_type, aggregate_id, payload)
  values ((v_row ->> 'tenant_id')::uuid, tg_table_name || '.' || v_action, tg_table_name, (v_row ->> 'id')::uuid,
          jsonb_build_object('old', v_old, 'new', v_new));
  return null;
end;
$$;

-- A security audit row and its outbox event, for changes not made through an audited table write
-- (integration users here, API keys in 9_2_api_key). p_data never holds a secret.
create function private.audit_security(p_tenant uuid, p_table text, p_id uuid, p_action text, p_data jsonb)
returns void language sql volatile security definer set search_path = '' as $$
  insert into public.audit_log (tenant_id, category, actor_type, actor_user_id, action, table_name, record_id, new_data, api_key_id)
  values (p_tenant, 'security', 'user', (select auth.uid()), p_action, p_table, p_id, p_data,
          nullif(auth.jwt() ->> 'api_key_id', '')::uuid);
  insert into private.outbox_event (tenant_id, event_type, aggregate_type, aggregate_id, payload)
  values (p_tenant, p_table || '.' || p_action, p_table, p_id, jsonb_build_object('new', p_data));
$$;
revoke all on function private.audit_security(uuid, text, uuid, text, jsonb) from public, anon, authenticated;

-- A2 a: users_security.manage creates the identity; its groups are assigned on the Security screen like a person's.
-- No password, no auth.identities row, banned: it can never sign in. The email is a placeholder (.invalid, RFC 6761).
create function public.create_integration_user(p_name text)
returns uuid language plpgsql volatile security definer set search_path = '' as $$
declare
  v_tenant uuid := private.current_tenant_id();
  v_id     uuid := gen_random_uuid();
  v_name   text := btrim(p_name);
  v_email  text := v_id || '@integration.invalid';
begin
  if not (private.has_permission('users_security', 'manage') and private.tenant_can_write()) then
    raise exception 'not allowed' using errcode = '42501';
  end if;
  if v_name is null or v_name = '' or length(v_name) > 100 then
    raise exception 'name is required, up to 100 characters' using errcode = '22023';
  end if;

  insert into auth.users (instance_id, id, aud, role, email, encrypted_password, banned_until,
                          raw_app_meta_data, raw_user_meta_data, created_at, updated_at,
                          confirmation_token, recovery_token, email_change, email_change_token_new)
  values ('00000000-0000-0000-0000-000000000000', v_id, 'authenticated', 'authenticated', v_email, null,
          '2999-12-31', '{"provider":"integration"}', '{}', now(), now(), '', '', '', '');
  insert into public.user_profile (id, display_name, email, kind, created_by, updated_by)
  values (v_id, v_name, v_email, 'integration', (select auth.uid()), (select auth.uid()));
  -- email_digest off: no daily email to a placeholder address (A12).
  insert into public.tenant_membership (tenant_id, user_id, email_digest, created_by, updated_by)
  values (v_tenant, v_id, false, (select auth.uid()), (select auth.uid()));

  perform private.audit_security(v_tenant, 'integration_user', v_id, 'insert',
                                 jsonb_build_object('display_name', v_name));
  return v_id;
end;
$$;
revoke all on function public.create_integration_user(text) from public, anon;
grant execute on function public.create_integration_user(text) to authenticated;

-- Disable or enable. A disabled integration user's keys stop at the next request (9_2_api_key).
create function public.set_integration_user_status(p_user_id uuid, p_status text)
returns uuid language plpgsql volatile security definer set search_path = '' as $$
declare
  v_tenant uuid := private.current_tenant_id();
begin
  if not (private.has_permission('users_security', 'manage') and private.tenant_can_write()) then
    raise exception 'not allowed' using errcode = '42501';
  end if;
  if p_status is null or p_status not in ('active', 'disabled') then
    raise exception 'status must be active or disabled' using errcode = '22023';
  end if;
  update public.tenant_membership m set status = p_status, updated_by = (select auth.uid())
  from public.user_profile p
  where p.id = m.user_id and p.kind = 'integration'
    and m.tenant_id = v_tenant and m.user_id = p_user_id and m.deleted_at is null;
  if not found then
    raise exception 'integration user not found' using errcode = 'P0002';
  end if;
  perform private.audit_security(v_tenant, 'integration_user', p_user_id, 'update', jsonb_build_object('status', p_status));
  return p_user_id;
end;
$$;
revoke all on function public.set_integration_user_status(uuid, text) from public, anon;
grant execute on function public.set_integration_user_status(uuid, text) to authenticated;

-- The 6.3 member list gains kind (A12: the screen tags integration users). New return type, so drop and create.
drop function public.security_members();
create function public.security_members()
returns table (user_id uuid, display_name text, email text, status text, kind text)
language sql stable security definer set search_path = '' as $$
  select m.user_id, p.display_name, p.email, m.status, p.kind
  from public.tenant_membership m
  join public.user_profile p on p.id = m.user_id
  where m.tenant_id = private.current_tenant_id() and m.deleted_at is null
    and private.has_permission('users_security', 'view')
  order by p.display_name;
$$;
revoke all on function public.security_members() from public, anon;
grant execute on function public.security_members() to authenticated;

-- 6.3 last-admin guard, same body, plus: only a person counts (A12). An integration user cannot sign in to fix security.
create or replace function private.check_security_admin_left()
returns trigger language plpgsql security definer set search_path = '' as $$
declare
  v_tenant uuid := case when tg_op = 'DELETE' then old.tenant_id else new.tenant_id end;
begin
  if (select auth.uid()) is null then
    return null;
  end if;
  if not exists (
    select 1
    from private.user_effective_permission uep
    join public.domain_operation o on o.id = uep.domain_operation_id
    join public.security_domain d  on d.id = o.security_domain_id
    join public.user_profile p     on p.id = uep.user_id and p.kind = 'person'
    where uep.tenant_id = v_tenant
      and d.code = 'users_security' and o.code = 'manage'
      and uep.effective_from <= now() and uep.effective_to is null
  ) then
    raise exception 'last security admin' using errcode = '42501',
      hint = 'Keep at least one member who can manage security, with no end date.';
  end if;
  return null;
end;
$$;

-- 9.1 fan-out, same body, plus: people only (A12). Integration users get no in-app alerts and so no email.
create or replace function private.fan_out_events(p_batch integer default 500)
returns integer language plpgsql volatile security definer set search_path = '' as $$
declare
  v_types  text[] := array['obligation.due_soon', 'obligation.overdue', 'coverage.expiring', 'coverage.expired'];
  v_total  integer := 0;
  v_domain text;
  e        record;
begin
  update private.outbox_event set published_at = now()
  where id in (select id from private.outbox_event
               where published_at is null and event_type <> all (v_types)
               order by occurred_at limit 50000 for update skip locked);

  for e in select * from private.outbox_event
           where published_at is null and attempts < 5 and event_type = any (v_types)
           order by occurred_at limit p_batch for update skip locked loop
    begin
      v_domain := case when e.event_type like 'obligation.%' then 'obligation' else 'coverage_contract' end;
      insert into public.notification (tenant_id, user_id, event_id, event_type, domain, asset_id, payload)
      select e.tenant_id, m.user_id, e.id, e.event_type, v_domain, a.id,
             e.payload || jsonb_build_object('asset_name', a.name, 'asset_tag', a.tag)
      from public.asset a
      join public.tenant_membership m on m.tenant_id = a.tenant_id and m.status = 'active' and m.deleted_at is null
      join public.user_profile p on p.id = m.user_id and p.kind = 'person'
      where a.tenant_id = e.tenant_id and a.id = (e.payload ->> 'asset_id')::uuid and a.deleted_at is null
        and private.user_can(e.tenant_id, m.user_id, v_domain, 'update', a.id)
      on conflict (event_id, user_id) do nothing;
      update private.outbox_event set published_at = now() where id = e.id;
      v_total := v_total + 1;
    exception when others then
      update private.outbox_event set attempts = attempts + 1, last_error = left(sqlerrm, 500) where id = e.id;
    end;
  end loop;
  return v_total;
end;
$$;
