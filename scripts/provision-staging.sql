-- Story 1.6b: provision the two staging test tenants (sales-led, OQ-16 lean). Not a migration.
-- Run as postgres on staging (Supabase MCP execute_sql, or psql), after `db push`, before `config push`.
-- Auth users first: Supabase dashboard, Authentication, Add user, auto-confirm. No passwords here.
-- One DO block, so it is all or nothing. Re-running changes nothing.
-- shortcut: one tenant per user, because the "Choose company" screen (D3) is not built yet.
do $$
declare
  r     record;
  v_uid uuid;
  v_tid uuid;
  v_gid uuid;
begin
  insert into public.tenant (name, slug, currency_code, locale, time_zone, date_format) values
    ('STAGING Tenant A', 'staging-tenant-a', 'INR', 'en-IN', 'Asia/Kolkata',     'dd-MM-yyyy'),
    ('STAGING Tenant B', 'staging-tenant-b', 'USD', 'en-US', 'America/New_York', 'MM/dd/yyyy')
  on conflict (slug) do nothing;

  perform private.seed_starter_groups(id) from public.tenant where slug in ('staging-tenant-a', 'staging-tenant-b');

  for r in
    select * from (values
      ('krunal.bhavsar@assetly.com',  'staging-tenant-a', 'tenant_admin'),  -- owner, the 0.5 user
      ('auditor.a@assetly.com',       'staging-tenant-a', 'auditor'),
      ('hiya.bhavsar@assetly.com',    'staging-tenant-b', 'tenant_admin')
    ) v (email, slug, group_code)
  loop
    select id into v_uid from auth.users where lower(email) = lower(r.email);
    if v_uid is null then
      raise exception 'No auth user %. Add it in the dashboard first.', r.email;
    end if;
    select id into v_tid from public.tenant where slug = r.slug;
    if exists (select 1 from public.tenant_membership where user_id = v_uid and tenant_id <> v_tid) then
      raise exception '% already belongs to another tenant (one tenant per user until D3 picker).', r.email;
    end if;
    select id into v_gid from public.security_group
    where tenant_id = v_tid and template_code = 'starter.' || r.group_code;
    if v_gid is null then
      raise exception 'No starter group % in %.', r.group_code, r.slug;
    end if;

    insert into public.user_profile (id, display_name, email)
    values (v_uid, split_part(r.email, '@', 1), r.email)
    on conflict (id) do nothing;
    insert into public.tenant_membership (tenant_id, user_id) values (v_tid, v_uid)
    on conflict (tenant_id, user_id) do nothing;
    insert into public.user_group_assignment (tenant_id, user_id, security_group_id)
    select v_tid, v_uid, v_gid
    where not exists (select 1 from public.user_group_assignment
                      where tenant_id = v_tid and user_id = v_uid and security_group_id = v_gid
                        and deleted_at is null);
  end loop;
end;
$$;
