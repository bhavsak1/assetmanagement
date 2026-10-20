-- Story 1.5: one generic trigger that writes the audit row and the outbox event in the same
-- transaction as the change (CLAUDE.md §8). Attach per table with the category as the argument:
--   create trigger audit after insert or update or delete on public.<table>
--     for each row execute function private.audit_row('data');

create function private.audit_row()
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

  insert into public.audit_log (tenant_id, category, actor_type, actor_user_id, action, table_name, record_id, old_data, new_data)
  values ((v_row ->> 'tenant_id')::uuid, tg_argv[0], case when v_actor is null then 'system' else 'user' end, v_actor,
          v_action, tg_table_name, (v_row ->> 'id')::uuid, v_old, v_new);

  insert into private.outbox_event (tenant_id, event_type, aggregate_type, aggregate_id, payload)
  values ((v_row ->> 'tenant_id')::uuid, tg_table_name || '.' || v_action, tg_table_name, (v_row ->> 'id')::uuid,
          jsonb_build_object('old', v_old, 'new', v_new));
  return null;
end;
$$;
revoke all on function private.audit_row() from public, anon, authenticated;

-- Security changes (CLAUDE.md §7.9, data-model-goal1.md §2.8, §2.9).
create trigger audit after insert or update or delete on public.security_group
  for each row execute function private.audit_row('security');
create trigger audit after insert or update or delete on public.group_domain_policy
  for each row execute function private.audit_row('security');
create trigger audit after insert or update or delete on public.user_group_assignment
  for each row execute function private.audit_row('security');

-- The 1.4 RLS pattern table, so the template carries the audit line too.
create trigger audit after insert or update or delete on public.rls_sample
  for each row execute function private.audit_row('data');
