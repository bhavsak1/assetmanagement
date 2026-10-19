-- Story 1.4: soft delete needs the domain's delete operation, not only update.
-- RLS cannot see the old row, so a policy cannot tell a soft delete from an edit. A trigger can.
-- Use: before update of deleted_at ... execute function private.check_soft_delete('<domain>', '<operation>').

create function private.check_soft_delete()
returns trigger language plpgsql set search_path = '' as $$
begin
  -- Users only. System jobs and security definer actions run as the table owner and check their own domain.
  if current_user = 'authenticated'
     and old.deleted_at is distinct from new.deleted_at
     and not private.has_permission(tg_argv[0], tg_argv[1]) then
    raise exception 'no permission to delete or restore' using errcode = '42501';
  end if;
  return new;
end;
$$;
