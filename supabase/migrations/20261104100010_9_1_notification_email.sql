-- Story 9.1: the daily email summary and the jobs role. docs/data-model-goal9.md §3, §6, §10 (N2, N6, N10).
-- OWNER REVIEW (CLAUDE.md §9): role assetly_jobs, claim_emails and finish_email (security definer, the
-- only things that role can run). No service-role key anywhere.

-- One summary per user per tenant per local day. RLS on, no policies: only the definer functions below.
create table private.notification_email (
  id          uuid primary key default gen_random_uuid(),
  tenant_id   uuid not null references public.tenant (id),
  user_id     uuid not null references public.user_profile (id),
  digest_date date not null,
  status      text not null default 'pending' check (status in ('pending', 'sending', 'sent', 'failed', 'skipped')),
  attempts    integer not null default 0,
  next_try_at timestamptz not null default now(),
  claimed_at  timestamptz null,
  sent_at     timestamptz null,
  provider_id text null,
  last_error  text null,
  created_at  timestamptz not null default now(),
  unique (tenant_id, user_id, digest_date)
);
create index notification_email_due_idx on private.notification_email (next_try_at) where status in ('pending', 'sending');
alter table private.notification_email enable row level security;
revoke all on private.notification_email from public, anon, authenticated;

-- Hourly (N6 a): for tenants whose local time has passed p_hour, a summary row for each member with the
-- switch on and unread alerts not yet emailed. Alerts are stamped only when their row is new, so an alert
-- that arrives after today's summary waits for tomorrow's.
create function private.queue_email_digests(p_now timestamptz default now(), p_hour integer default 8)
returns integer language sql volatile security definer set search_path = '' as $$
  with c as (
    select distinct n.tenant_id, n.user_id, (p_now at time zone t.time_zone)::date as d
    from public.notification n
    join public.tenant t on t.id = n.tenant_id and t.deleted_at is null
    join public.tenant_membership m on m.tenant_id = n.tenant_id and m.user_id = n.user_id
                                   and m.status = 'active' and m.deleted_at is null and m.email_digest
    where n.emailed_on is null and n.read_at is null
      and extract(hour from p_now at time zone t.time_zone) >= p_hour
  ), i as (
    insert into private.notification_email (tenant_id, user_id, digest_date)
    select tenant_id, user_id, d from c
    on conflict (tenant_id, user_id, digest_date) do nothing
    returning tenant_id, user_id, digest_date
  ), s as (
    update public.notification n set emailed_on = i.digest_date
    from i
    where n.tenant_id = i.tenant_id and n.user_id = i.user_id and n.emailed_on is null and n.read_at is null
    returning 1
  )
  select count(*)::int from i;
$$;
revoke all on function private.queue_email_digests(timestamptz, integer) from public, anon, authenticated;

-- Claim up to p_limit due rows (N2): pending and due, or sending for over 10 minutes (a crashed run).
-- Skip locked, so two runs never share a row. Lines are checked again (view and scope, switch still on);
-- a row with none left is marked skipped and not returned.
create function private.claim_emails(p_limit integer default 50)
returns table (id uuid, email text, display_name text, tenant_name text, date_format text, lines jsonb)
language plpgsql volatile security definer set search_path = '' as $$
#variable_conflict use_column
declare
  r record;
begin
  for r in
    with c as (
      select e.id from private.notification_email e
      where (e.status = 'pending' and e.next_try_at <= now())
         or (e.status = 'sending' and e.claimed_at < now() - interval '10 minutes')
      order by e.next_try_at limit p_limit for update skip locked
    )
    update private.notification_email e set status = 'sending', claimed_at = now()
    from c where e.id = c.id
    returning e.id, e.tenant_id, e.user_id, e.digest_date
  loop
    id := r.id;
    select p.email, p.display_name, t.name, t.date_format into email, display_name, tenant_name, date_format
    from public.user_profile p, public.tenant t where p.id = r.user_id and t.id = r.tenant_id;
    select jsonb_agg(jsonb_build_object('event_type', n.event_type, 'asset_id', n.asset_id, 'payload', n.payload)
                     order by n.created_at)
      into lines
    from public.notification n
    join public.tenant_membership m on m.tenant_id = n.tenant_id and m.user_id = n.user_id and m.email_digest
    where n.tenant_id = r.tenant_id and n.user_id = r.user_id and n.emailed_on = r.digest_date
      and private.user_can(n.tenant_id, n.user_id, n.domain, 'view', n.asset_id);
    if lines is null then
      update private.notification_email set status = 'skipped' where private.notification_email.id = r.id;
    else
      return next;
    end if;
  end loop;
end;
$$;

-- p_error null: sent. Else back to pending with a backoff (15 min, 1 h, 4 h, 12 h), failed after 5 tries.
create function private.finish_email(p_id uuid, p_provider_id text, p_error text)
returns void language sql volatile security definer set search_path = '' as $$
  update private.notification_email set
    status      = case when p_error is null then 'sent' when attempts + 1 >= 5 then 'failed' else 'pending' end,
    attempts    = attempts + case when p_error is null then 0 else 1 end,
    sent_at     = case when p_error is null then now() end,
    provider_id = p_provider_id,
    last_error  = left(p_error, 500),
    next_try_at = case when p_error is null then next_try_at
                       else now() + ('{15 minutes,1 hour,4 hours,12 hours}'::interval[])[least(attempts + 1, 4)] end
  where id = p_id and status = 'sending';
$$;

-- The jobs login role (8.1 G9, N10 a): noinherit, no table rights, these two functions only.
-- No password in git: the local seed sets a test one; on staging the owner sets it (Secret Manager).
do $$
begin
  if not exists (select 1 from pg_roles where rolname = 'assetly_jobs') then
    create role assetly_jobs login noinherit;
  end if;
end $$;
grant usage on schema private to assetly_jobs;
revoke all on function private.claim_emails(integer), private.finish_email(uuid, text, text) from public, anon, authenticated;
grant execute on function private.claim_emails(integer), private.finish_email(uuid, text, text) to assetly_jobs;

select cron.schedule('assetly_notify_email_queue', '5 * * * *', 'select private.queue_email_digests()');
