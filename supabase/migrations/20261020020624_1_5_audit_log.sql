-- Story 1.5: audit_log, one append-only log for data and security changes [D8].
-- Shape from docs/data-model-goal1.md §2.12. Domains audit_log and users_security are already in the
-- 1.2 catalog seed. Written only by private.audit_row() (1_5_audit_triggers) and action functions.

create table public.audit_log (
  id             uuid primary key default gen_random_uuid(),
  tenant_id      uuid not null references public.tenant (id),
  occurred_at    timestamptz not null default now(),
  category       text not null check (category in ('data', 'security')),
  actor_type     text not null check (actor_type in ('user', 'system')),
  actor_user_id  uuid null references public.user_profile (id),
  action         text not null,
  table_name     text not null,
  record_id      uuid not null,
  old_data       jsonb null,
  new_data       jsonb null,
  reason         text null,
  transaction_id bigint not null default txid_current()
);
-- Audit tab on a record, and the log screen.
create index audit_log_record_idx on public.audit_log (tenant_id, table_name, record_id, occurred_at desc);
create index audit_log_tenant_idx on public.audit_log (tenant_id, occurred_at desc);

-- History cannot be edited, even by the table owner by mistake.
create function private.audit_log_append_only()
returns trigger language plpgsql set search_path = '' as $$
begin
  raise exception 'audit_log is append-only';
end;
$$;
create trigger append_only before update or delete on public.audit_log
  for each row execute function private.audit_log_append_only();
create trigger append_only_truncate before truncate on public.audit_log
  for each statement execute function private.audit_log_append_only();

-- Read only. Data rows need audit_log.view, security rows need users_security.view.
alter table public.audit_log enable row level security;

create policy audit_log_select on public.audit_log
  for select to authenticated
  using (tenant_id = (select private.current_tenant_id())
         and ((category = 'data' and (select private.has_permission('audit_log', 'view')))
              or (category = 'security' and (select private.has_permission('users_security', 'view')))));

-- No insert, update or delete policies, and no write grants for any API role.
revoke all on public.audit_log from anon, authenticated, service_role;
grant select on public.audit_log to authenticated;
