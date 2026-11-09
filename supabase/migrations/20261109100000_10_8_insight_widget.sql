-- Story 10.8: saved insight widgets (docs/data-model-goal10.md §5.5.1, W1-W9 accepted 9 Nov 2026).
-- OWNER REVIEW (CLAUDE.md §9): RLS policies. A widget holds a name and the 10.6 structured query only:
-- never SQL, never result rows. It re-runs through POST /insights/run under the viewer's own rights, so a
-- shared widget never shows a viewer more than they may see. Domain insights_widget (save, share) and its
-- starter grants exist since 1.2 and 1.6: nothing to seed. The owner is created_by (W9).

create table public.insight_widget (
  id         uuid primary key default gen_random_uuid(),
  tenant_id  uuid not null references public.tenant (id),
  name       text not null check (length(btrim(name)) between 1 and 80),
  query      jsonb not null check (jsonb_typeof(query) = 'object' and pg_column_size(query) <= 8192),
  shared     boolean not null default false,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  created_by uuid null default auth.uid() references public.user_profile (id),
  updated_by uuid null references public.user_profile (id),
  deleted_at timestamptz null,
  unique (tenant_id, id)
);
create unique index insight_widget_name_uq on public.insight_widget (tenant_id, created_by, lower(btrim(name)))
  where deleted_at is null;

-- W7: at most 25 live widgets per owner. Invoker: the owner reads their own rows under RLS.
create function private.insight_widget_limit()
returns trigger language plpgsql set search_path = '' as $$
begin
  if new.deleted_at is null and (tg_op = 'INSERT' or old.deleted_at is not null)
     and (select count(*) from public.insight_widget w
          where w.tenant_id = new.tenant_id and w.created_by = new.created_by
            and w.deleted_at is null and w.id <> new.id) >= 25 then
    raise exception 'widget limit reached' using errcode = '54000';
  end if;
  return new;
end;
$$;
revoke all on function private.insight_widget_limit() from public, anon;

create trigger insight_widget_limit before insert or update of deleted_at on public.insight_widget
  for each row execute function private.insight_widget_limit();
create trigger set_updated_at before update on public.insight_widget
  for each row execute function private.set_updated_at();
create trigger check_soft_delete before update of deleted_at on public.insight_widget
  for each row execute function private.check_soft_delete('insights_widget', 'save');
create trigger audit after insert or update or delete on public.insight_widget
  for each row execute function private.audit_row('data');

alter table public.insight_widget enable row level security;

-- W2: your own widgets with save; shared widgets with insights_query.ask (needed to re-run them anyway).
create policy insight_widget_select on public.insight_widget
  for select to authenticated
  using (tenant_id = (select private.current_tenant_id())
         and ((created_by = (select auth.uid()) and (select private.has_permission('insights_widget', 'save')))
              or (shared and (select private.has_permission('insights_query', 'ask')))));
-- Only the owner writes (W8). A shared live widget needs share; unsharing or removing does not.
create policy insight_widget_insert on public.insight_widget
  for insert to authenticated
  with check (tenant_id = (select private.current_tenant_id())
              and created_by = (select auth.uid())
              and (select private.has_permission('insights_widget', 'save'))
              and (not shared or (select private.has_permission('insights_widget', 'share')))
              and (select private.tenant_can_write()));
create policy insight_widget_update on public.insight_widget
  for update to authenticated
  using (tenant_id = (select private.current_tenant_id())
         and created_by = (select auth.uid())
         and (select private.has_permission('insights_widget', 'save'))
         and (select private.tenant_can_write()))
  with check (tenant_id = (select private.current_tenant_id())
              and created_by = (select auth.uid())
              and (select private.has_permission('insights_widget', 'save'))
              and (not shared or deleted_at is not null or (select private.has_permission('insights_widget', 'share')))
              and (select private.tenant_can_write()));

revoke delete, truncate on public.insight_widget from anon, authenticated;
