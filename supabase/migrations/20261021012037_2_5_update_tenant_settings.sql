-- Story 2.5 (S1): the only way a user changes tenant settings. `tenant` has no write grant for
-- users, so status, name, slug and deleted_at stay system-only. Writes its own audit row
-- and outbox event: private.audit_row() needs a tenant_id column, which `tenant` does not have.

-- 1.1 left Supabase's default grants (RLS with no write policy already refused every row).
-- Revoke them so a direct write fails loudly instead of matching zero rows.
revoke insert, update, delete, truncate on public.tenant from anon, authenticated;
create function public.update_tenant_settings(
  p_currency_code           text,
  p_locale                  text,
  p_time_zone               text,
  p_date_format             text,
  p_fiscal_year_start_month smallint,
  p_required_asset_fields   text[]
)
returns void language plpgsql security definer set search_path = '' as $$
declare
  v_tenant_id uuid := private.current_tenant_id();
  v_old       jsonb;
  v_new       jsonb;
begin
  if v_tenant_id is null
     or not private.has_permission('tenant_settings', 'manage')
     or not private.tenant_can_write() then
    raise exception 'not allowed to change tenant settings' using errcode = '42501';
  end if;

  if not exists (select 1 from pg_catalog.pg_timezone_names where name = p_time_zone) then
    raise exception 'unknown time zone: %', p_time_zone using errcode = '22023';
  end if;

  select to_jsonb(t) into v_old from public.tenant t where t.id = v_tenant_id;

  update public.tenant set
    currency_code           = p_currency_code,
    locale                  = p_locale,
    time_zone               = p_time_zone,
    date_format             = p_date_format,
    fiscal_year_start_month = p_fiscal_year_start_month,
    required_asset_fields   = coalesce(p_required_asset_fields, '{}'),
    updated_by              = auth.uid()
  where id = v_tenant_id
  returning to_jsonb(tenant.*) into v_new;

  -- Changed columns only, as audit_row() does (data-model-goal1.md §2.12).
  select jsonb_object_agg(o.key, o.value), jsonb_object_agg(o.key, v_new -> o.key)
    into v_old, v_new
  from jsonb_each(v_old) o
  where o.value is distinct from v_new -> o.key and o.key not in ('updated_at', 'updated_by');

  if v_old is null then
    return;  -- nothing changed, nothing to audit
  end if;

  insert into public.audit_log (tenant_id, category, actor_type, actor_user_id, action, table_name, record_id, old_data, new_data)
  values (v_tenant_id, 'data', 'user', auth.uid(), 'update', 'tenant', v_tenant_id, v_old, v_new);
  insert into private.outbox_event (tenant_id, event_type, aggregate_type, aggregate_id, payload)
  values (v_tenant_id, 'tenant.update', 'tenant', v_tenant_id, jsonb_build_object('old', v_old, 'new', v_new));
end;
$$;
revoke all on function public.update_tenant_settings(text, text, text, text, smallint, text[]) from public, anon;
grant execute on function public.update_tenant_settings(text, text, text, text, smallint, text[]) to authenticated;
