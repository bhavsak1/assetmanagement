-- Story 4.1 (V2): an optional format check on a text custom field, set by the tenant (for example a
-- GSTIN regex). Core code knows no country format. docs/data-model-goal4.md §3.
-- The check `('' ~ pattern) is not null` compiles the regex, so a broken pattern is refused on save.
alter table public.field_definition add column pattern text null
  constraint field_definition_pattern_check
  check (pattern is null or (type = 'text' and length(pattern) <= 200 and ('' ~ pattern) is not null));

grant update (pattern) on public.field_definition to authenticated;

-- Changed custom values must match their field's pattern. One trigger for every entity table
-- (tg_argv[0] is the entity). Named to fire after the check_*_values triggers, which restore hidden keys.
create function private.validate_field_pattern()
returns trigger language plpgsql security definer set search_path = '' as $$
declare
  v_old jsonb := case when tg_op = 'UPDATE' then old.custom_values else '{}' end;
  v_key text;
begin
  select o.key into v_key
  from jsonb_each(new.custom_values) o
  join public.field_definition fd
    on fd.tenant_id = new.tenant_id and fd.entity = tg_argv[0] and fd.key = o.key and fd.pattern is not null
  where v_old -> o.key is distinct from o.value
    and jsonb_typeof(o.value) = 'string' and not (o.value #>> '{}') ~ fd.pattern
  limit 1;
  if v_key is not null then
    raise exception 'custom field % does not match its format', v_key using errcode = '22023';
  end if;
  return new;
end;
$$;
revoke all on function private.validate_field_pattern() from public, anon, authenticated;

create trigger validate_field_pattern before insert or update of custom_values on public.asset
  for each row execute function private.validate_field_pattern('asset');
