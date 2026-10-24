-- Story 4.1b (B1, B2, B9): vendors tagged to a category, per role. docs/data-model-goal4.md §10.
-- Stored on the category like status sets (3.7 R1), so the category policy (category_config.manage)
-- and its audit trigger already cover writes. Tags are inherited by every child (union, like G3).
alter table public.asset_category
  add column oem_vendor_ids uuid[] not null default '{}',
  add column om_vendor_ids  uuid[] not null default '{}';

-- No duplicates; every added id is a live, active vendor of the tenant holding the role. Ids already
-- there stay after the vendor is deactivated or drops the role (B4). Definer: reads vendors whatever
-- the caller's grants.
create function private.check_category_vendors()
returns trigger language plpgsql security definer set search_path = '' as $$
declare
  v_role text;
  v_ids  uuid[];
  v_old  uuid[];
begin
  foreach v_role in array array['oem', 'om'] loop
    v_ids := case v_role when 'oem' then new.oem_vendor_ids else new.om_vendor_ids end;
    v_old := case when tg_op = 'INSERT' then '{}'
                  when v_role = 'oem' then old.oem_vendor_ids else old.om_vendor_ids end;
    if cardinality(v_ids) <> (select count(distinct x) from unnest(v_ids) x) then
      raise exception 'a vendor is tagged twice' using errcode = '23514';
    end if;
    if exists (select 1 from unnest(v_ids) x
               where x <> all (v_old)
                 and not exists (select 1 from public.vendor v
                                 where v.tenant_id = new.tenant_id and v.id = x and v.is_active
                                   and v.deleted_at is null and v_role = any (v.roles))) then
      raise exception 'tagged vendor is unknown, inactive or not an % vendor', v_role using errcode = '23514';
    end if;
  end loop;
  return new;
end;
$$;
revoke all on function private.check_category_vendors() from public, anon, authenticated;

create trigger check_category_vendors before insert or update of oem_vendor_ids, om_vendor_ids on public.asset_category
  for each row execute function private.check_category_vendors();

-- Vendors allowed for a role on a category: tags on the category and every ancestor, kept when the
-- vendor is live, active and holds the role. Categories are small trees (2.1: no closure).
create function private.allowed_vendor_ids(p_tenant_id uuid, p_category_id uuid, p_role text)
returns uuid[] language sql stable security definer set search_path = '' as $$
  with recursive up as (
    select c.id, c.parent_id, case p_role when 'oem' then c.oem_vendor_ids else c.om_vendor_ids end as ids
    from public.asset_category c where c.tenant_id = p_tenant_id and c.id = p_category_id
    union all
    select c.id, c.parent_id, case p_role when 'oem' then c.oem_vendor_ids else c.om_vendor_ids end
    from public.asset_category c join up on c.tenant_id = p_tenant_id and c.id = up.parent_id
  )
  select coalesce(array_agg(v.id order by v.name), '{}')
  from public.vendor v
  where v.tenant_id = p_tenant_id and v.id in (select unnest(up.ids) from up)
    and v.is_active and v.deleted_at is null and p_role = any (v.roles);
$$;
revoke all on function private.allowed_vendor_ids(uuid, uuid, text) from public, anon, authenticated;

-- For the asset form: the vendors it may offer, by name. Nothing without category_config.view.
create function public.category_vendors(p_category_id uuid, p_role text)
returns setof uuid language sql stable security definer set search_path = '' as $$
  select x from unnest(private.allowed_vendor_ids((select private.current_tenant_id()), p_category_id, p_role)) x
  where (select private.has_permission('category_config', 'view'));
$$;
revoke all on function public.category_vendors(uuid, text) from public, anon;
grant execute on function public.category_vendors(uuid, text) to authenticated;
