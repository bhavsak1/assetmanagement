-- Story 9.1: in-app notifications, the outbox fan-out and the email switch. docs/data-model-goal9.md §3 to §7.
-- OWNER REVIEW (CLAUDE.md §9): private.user_can (permission helper), notification RLS, fan_out_events and
-- set_email_digest (security definer).

-- One user's right to one asset, for any user (the 6.1 helpers work for auth.uid() only). Same rules as
-- has_permission plus asset_in_scope: a tenant-wide grant, or a live profile whose rules match the asset
-- (private.profile_scope, 6.5: no row for a profile with no live rule, S4). Only active members.
create function private.user_can(p_tenant uuid, p_user uuid, p_domain text, p_operation text, p_asset_id uuid)
returns boolean language sql stable security definer set search_path = '' as $$
  select exists (
    select 1
    from private.user_effective_permission uep
    join public.domain_operation o on o.id = uep.domain_operation_id
    join public.security_domain d  on d.id = o.security_domain_id
    join public.tenant_membership m on m.tenant_id = uep.tenant_id and m.user_id = uep.user_id
                                   and m.status = 'active' and m.deleted_at is null
    join public.asset a on a.tenant_id = uep.tenant_id and a.id = p_asset_id
    where uep.tenant_id = p_tenant and uep.user_id = p_user
      and d.code = p_domain and o.code = p_operation
      and uep.effective_from <= now()
      and (uep.effective_to is null or uep.effective_to > now())
      and (uep.scope_profile_id is null
           or exists (select 1 from private.profile_scope(uep.scope_profile_id) ps
                      where (ps.locs is null or a.location_id = any (ps.locs))
                        and (ps.cats is null or a.category_id = any (ps.cats))))
  );
$$;
revoke all on function private.user_can(uuid, uuid, text, text, uuid) from public, anon, authenticated;

-- The inbox. Written only by the fan-out job, so no created_by, updated_*, or deleted_at (users never
-- delete), and no audit trigger (a row per alert is noise; its outbox event would loop back here).
-- payload: the event's payload plus asset name and tag at fan-out time. Text is built in the browser (i18n).
create table public.notification (
  id         uuid primary key default gen_random_uuid(),
  tenant_id  uuid not null references public.tenant (id),
  user_id    uuid not null,
  event_id   uuid not null,  -- private.outbox_event.id; no FK, so the outbox can be purged later
  event_type text not null,
  domain     text not null,  -- checked on read: a lost grant hides old alerts
  asset_id   uuid not null,
  payload    jsonb not null,
  read_at    timestamptz null,
  emailed_on date null,      -- the daily summary that carried it
  created_at timestamptz not null default now(),
  unique (tenant_id, id),
  unique (event_id, user_id),  -- N2: a re-run of the fan-out never doubles
  foreign key (tenant_id, user_id) references public.tenant_membership (tenant_id, user_id),
  foreign key (tenant_id, asset_id) references public.asset (tenant_id, id)
);
create index notification_inbox_idx on public.notification (tenant_id, user_id, created_at desc);
create index notification_unread_idx on public.notification (tenant_id, user_id) where read_at is null;
create index notification_unemailed_idx on public.notification (tenant_id, user_id) where emailed_on is null and read_at is null;

alter table public.notification enable row level security;
-- Own rows, and only while the user still holds view on the domain and the asset is in their scope.
-- shortcut: has_permission and asset_in_scope run per row; fine for an inbox page, revisit past ~10k rows a user.
create policy notification_select on public.notification
  for select to authenticated
  using (tenant_id = (select private.current_tenant_id()) and user_id = (select auth.uid())
         and private.has_permission(domain, 'view') and private.asset_in_scope(domain, 'view', asset_id));
-- Mark as read: own rows, read_at only (column grant). No tenant_can_write(): a read-only tenant can mark read.
create policy notification_update on public.notification
  for update to authenticated
  using (tenant_id = (select private.current_tenant_id()) and user_id = (select auth.uid()))
  with check (tenant_id = (select private.current_tenant_id()) and user_id = (select auth.uid()));
revoke all on public.notification from anon, authenticated;
grant select on public.notification to authenticated;
grant update (read_at) on public.notification to authenticated;

-- N7 b: one switch per user per tenant. Read through tenant_membership_select_own.
alter table public.tenant_membership add column email_digest boolean not null default true;

create function public.set_email_digest(p_on boolean)
returns boolean language sql volatile security definer set search_path = '' as $$
  update public.tenant_membership set email_digest = p_on, updated_by = (select auth.uid())
  where tenant_id = private.current_tenant_id() and user_id = (select auth.uid()) and deleted_at is null
  returning email_digest;
$$;
revoke all on function public.set_email_digest(boolean) from public, anon;
grant execute on function public.set_email_digest(boolean) to authenticated;

-- The fan-out (N1 a, N2, N3 b). Events no consumer wants yet are marked published in one statement (9.3
-- webhooks add their consumer here). Alert events: one at a time, skip locked, so two runs never share a row;
-- a failing row gets attempts and last_error and stops after 5 (it stays unpublished, so it shows).
-- Recipients: active members holding <domain>.update with the asset in their scope.
create function private.fan_out_events(p_batch integer default 500)
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
revoke all on function private.fan_out_events(integer) from public, anon, authenticated;

select cron.schedule('assetly_notify_fan_out', '* * * * *', 'select private.fan_out_events()');
