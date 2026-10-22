-- Story 3.8: live sample tag for the Settings field. One renderer for the insert trigger and the
-- preview, so the sample is the tag an insert would get. next_asset_tag keeps its signature and result.

-- A1 format, once: the tenant check and the preview both use it.
create function private.asset_tag_pattern_ok(p_pattern text)
returns boolean language sql immutable set search_path = '' as $$
  select p_pattern ~
    '^([A-Za-z0-9._/-]|\{LOC\}|\{CAT\}|\{DATE:(yyyy|yy|mmm|mm|dd)([-/.]?(yyyy|yy|mmm|mm|dd))*\})*\{SEQ:[3-9]\}$';
$$;
revoke all on function private.asset_tag_pattern_ok(text) from public, anon;
-- Pure check; the tenant constraint runs it as whoever writes the row.
grant execute on function private.asset_tag_pattern_ok(text) to authenticated, service_role;

alter table public.tenant drop constraint tenant_asset_tag_pattern_check,
  add constraint tenant_asset_tag_pattern_check check (private.asset_tag_pattern_ok(asset_tag_pattern));

-- The pattern without {SEQ:n}, parts resolved, upper case. Moved unchanged from 3.1 next_asset_tag.
create function private.asset_tag_prefix(p_tenant_id uuid, p_pattern text, p_location_id uuid, p_category_id uuid)
returns text language plpgsql stable security definer set search_path = '' as $$
declare
  v_tz     text;
  v_prefix text := regexp_replace(p_pattern, '\{SEQ:\d\}$', '');
  v_code   text;
  m        text[];
begin
  select t.time_zone into v_tz from public.tenant t where t.id = p_tenant_id;

  -- Dates first, so a location or category code can never be read as a token.
  for m in select regexp_matches(v_prefix, '\{DATE:([^}]*)\}', 'g') loop
    v_prefix := replace(v_prefix, '{DATE:' || m[1] || '}',
      to_char(now() at time zone v_tz,
        replace(replace(replace(replace(replace(m[1], 'yyyy', 'YYYY'), 'yy', 'YY'), 'mmm', 'MON'), 'mm', 'MM'), 'dd', 'DD')));
  end loop;

  if strpos(v_prefix, '{CAT}') > 0 then
    with recursive up as (
      select c.parent_id, c.code, 0 as depth from public.asset_category c
      where c.tenant_id = p_tenant_id and c.id = p_category_id
      union all
      select c.parent_id, c.code, up.depth + 1 from public.asset_category c
      join up on c.tenant_id = p_tenant_id and c.id = up.parent_id
    )
    select up.code into v_code from up where up.code is not null order by up.depth limit 1;
    if v_code is null then
      raise exception 'the tag pattern needs a category code: add one to the category or type a tag' using errcode = '22023';
    end if;
    v_prefix := replace(v_prefix, '{CAT}', v_code);
  end if;

  if strpos(v_prefix, '{LOC}') > 0 then
    v_code := null;
    select l.code into v_code
    from private.location_closure c
    join public.location l on l.tenant_id = c.tenant_id and l.id = c.ancestor_id
    where c.tenant_id = p_tenant_id and c.descendant_id = p_location_id and l.code is not null
    order by c.depth limit 1;
    if v_code is null then
      raise exception 'the tag pattern needs a location code: set a location with a code or type a tag' using errcode = '22023';
    end if;
    v_prefix := replace(v_prefix, '{LOC}', v_code);
  end if;
  return upper(v_prefix);
end;
$$;

create or replace function private.next_asset_tag(p_tenant_id uuid, p_location_id uuid, p_category_id uuid)
returns text language plpgsql security definer set search_path = '' as $$
declare
  v_pattern text;
  v_prefix  text;
  v_width   int;
  v_n       bigint;
  v_tag     text;
begin
  select t.asset_tag_pattern into v_pattern from public.tenant t where t.id = p_tenant_id;
  v_width  := substring(v_pattern from '\{SEQ:(\d)\}$')::int;
  v_prefix := private.asset_tag_prefix(p_tenant_id, v_pattern, p_location_id, p_category_id);

  loop
    insert into private.asset_tag_counter as c (tenant_id, prefix, last_value) values (p_tenant_id, v_prefix, 1)
    on conflict (tenant_id, prefix) do update set last_value = c.last_value + 1
    returning c.last_value into v_n;
    -- lpad truncates, so never pad to less than the number itself.
    v_tag := v_prefix || lpad(v_n::text, greatest(v_width, length(v_n::text)), '0');
    exit when not exists (select 1 from public.asset a
                          where a.tenant_id = p_tenant_id and a.tag = v_tag and a.deleted_at is null);
  end loop;
  return v_tag;
end;
$$;
revoke all on function private.asset_tag_prefix(uuid, text, uuid, uuid), private.next_asset_tag(uuid, uuid, uuid)
  from public, anon, authenticated;

-- The tag the next insert would get with p_pattern, without touching the counter. The sample
-- location and category are optional; a pattern part that needs one raises 22023 as an insert does.
create function public.preview_asset_tag(p_pattern text, p_location_id uuid default null, p_category_id uuid default null)
returns text language plpgsql stable security definer set search_path = '' as $$
declare
  v_tenant_id uuid := private.current_tenant_id();
  v_prefix    text;
  v_width     int;
  v_n         bigint;
  v_tag       text;
begin
  if v_tenant_id is null or not private.has_permission('tenant_settings', 'view') then
    raise exception 'not allowed to view tenant settings' using errcode = '42501';
  end if;
  -- Codes are read past RLS here, so the caller must be able to see the sample rows.
  if p_location_id is not null and not (private.has_permission('location_hierarchy', 'view') and exists (
       select 1 from public.location l where l.tenant_id = v_tenant_id and l.id = p_location_id)) then
    raise exception 'unknown location' using errcode = '42501';
  end if;
  if p_category_id is not null and not (private.has_permission('category_config', 'view') and exists (
       select 1 from public.asset_category c where c.tenant_id = v_tenant_id and c.id = p_category_id)) then
    raise exception 'unknown category' using errcode = '42501';
  end if;
  if p_pattern is null or not private.asset_tag_pattern_ok(p_pattern) then
    raise exception 'invalid tag pattern' using errcode = '23514';
  end if;

  v_width  := substring(p_pattern from '\{SEQ:(\d)\}$')::int;
  v_prefix := private.asset_tag_prefix(v_tenant_id, p_pattern, p_location_id, p_category_id);
  select coalesce(max(c.last_value), 0) + 1 into v_n
  from private.asset_tag_counter c where c.tenant_id = v_tenant_id and c.prefix = v_prefix;
  -- Same skip as next_asset_tag: numbers a typed tag already holds.
  loop
    v_tag := v_prefix || lpad(v_n::text, greatest(v_width, length(v_n::text)), '0');
    exit when not exists (select 1 from public.asset a
                          where a.tenant_id = v_tenant_id and a.tag = v_tag and a.deleted_at is null);
    v_n := v_n + 1;
  end loop;
  return v_tag;
end;
$$;
revoke all on function public.preview_asset_tag(text, uuid, uuid) from public, anon;
grant execute on function public.preview_asset_tag(text, uuid, uuid) to authenticated;
