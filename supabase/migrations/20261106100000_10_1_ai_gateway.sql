-- Story 10.1: the AI gateway log and its guards (docs/data-model-goal10.md §2.3, §2.4). Owner accepted D1 to D12.
-- OWNER REVIEW (CLAUDE.md §9): RLS on ai_call, and three security definer functions (ai_begin, ai_finish,
-- ai_set_outcome). The service calls them under withUser; each reads auth.uid() and the tenant claim itself.
-- No new domain: ai_usage and insights_query exist since 1.2 (§ "Facts checked").

create table public.ai_call (
  id                uuid primary key default gen_random_uuid(),
  tenant_id         uuid not null references public.tenant (id),
  user_id           uuid not null,
  feature           text not null check (feature in ('import_map', 'import_values', 'insights', 'assist', 'check')),
  subject_id        uuid null,
  status            text not null default 'started' check (status in ('started', 'ok', 'error', 'lost')),
  provider          text null,
  model             text null,
  input_tokens      integer null,
  output_tokens     integer null,
  cache_read_tokens integer null,
  est_micro_usd     bigint not null check (est_micro_usd >= 0),
  cost_micro_usd    bigint null check (cost_micro_usd >= 0),
  latency_ms        integer null,
  error_code        text null check (length(error_code) <= 60),
  request           jsonb null,   -- D6: insights and assist only, nulled after 90 days
  output            jsonb null,   -- D6: insights and assist only, nulled after 90 days
  outcome           text null check (outcome in ('ran', 'edited', 'saved', 'discarded')),
  created_at        timestamptz not null default now(),
  finished_at       timestamptz null,
  unique (tenant_id, id),
  foreign key (tenant_id, user_id) references public.tenant_membership (tenant_id, user_id)
);
create index ai_call_month_idx on public.ai_call (tenant_id, created_at);
create index ai_call_user_idx on public.ai_call (tenant_id, user_id, created_at);
create index ai_call_started_idx on public.ai_call (created_at) where status = 'started';

-- A log, like audit_log: no row trigger, no outbox. Rows are written only by the functions below.
alter table public.ai_call enable row level security;
create policy ai_call_select on public.ai_call
  for select to authenticated
  using (tenant_id = (select private.current_tenant_id())
         and ((select private.has_permission('ai_usage', 'view')) or user_id = (select auth.uid())));
revoke insert, update, delete, truncate on public.ai_call from anon, authenticated;

-- §2.2 step 1. Refuses with a stable code (message), else logs a 'started' row and returns its id.
-- AI_ENABLED is checked in the service before this runs (an env var, not data).
create function private.ai_begin(p_feature text, p_subject_id uuid, p_est_micro_usd bigint)
returns uuid language plpgsql volatile security definer set search_path = '' as $$
declare
  v_tenant uuid := private.current_tenant_id();
  v_user   uuid := (select auth.uid());
  v_cap    bigint;
  v_spent  bigint;
  v_id     uuid;
  v_domain text;
  v_op     text;
begin
  -- The domain of each feature. A new feature adds a line here and to the table check.
  select f.d, f.o into v_domain, v_op
  from (values ('import_map', 'excel_import', 'run'), ('import_values', 'excel_import', 'review'),
               ('insights', 'insights_query', 'ask'), ('assist', 'insights_query', 'ask'),
               ('check', 'ai_usage', 'view')) as f (feature, d, o)
  where f.feature = p_feature;
  if v_domain is null or v_tenant is null or v_user is null or p_est_micro_usd is null or p_est_micro_usd < 0 then
    raise exception 'ai_bad_call' using errcode = '22023';
  end if;
  if not private.has_permission(v_domain, v_op) then
    raise exception 'ai_no_right' using errcode = 'P0001';
  end if;

  -- One begin at a time per tenant, so two parallel calls cannot both slip under the cap.
  perform pg_advisory_xact_lock(hashtextextended('ai_call:' || v_tenant::text, 0));

  -- §2.4 (OQ-11 lean, D4): limit_value = monthly cap in US cents of provider cost; null = 500 ($5).
  select coalesce(e.limit_value, 500)::bigint * 10000 into v_cap
  from public.tenant_entitlement e
  where e.tenant_id = v_tenant and e.feature_code = 'ai_addon' and e.deleted_at is null
    and e.valid_from <= now() and (e.valid_to is null or e.valid_to > now())
  order by e.valid_from desc
  limit 1;
  if v_cap is null then
    raise exception 'ai_not_licensed' using errcode = 'P0001';
  end if;

  -- A started or lost row counts at its estimate, so a crash never lets spend escape the cap (§2.2).
  select coalesce(sum(coalesce(c.cost_micro_usd, c.est_micro_usd)), 0) into v_spent
  from public.ai_call c
  where c.tenant_id = v_tenant and c.created_at >= date_trunc('month', now() at time zone 'utc') at time zone 'utc';
  if v_spent + p_est_micro_usd > v_cap then
    raise exception 'ai_cap_reached' using errcode = 'P0001';
  end if;

  -- 20 calls a minute per user, like the /v1 per-key limit.
  if (select count(*) from public.ai_call c
      where c.tenant_id = v_tenant and c.user_id = v_user and c.created_at > now() - interval '1 minute') >= 20 then
    raise exception 'ai_rate_limited' using errcode = 'P0001';
  end if;

  insert into public.ai_call (tenant_id, user_id, feature, subject_id, est_micro_usd)
  values (v_tenant, v_user, p_feature, p_subject_id, p_est_micro_usd)
  returning id into v_id;
  return v_id;
end;
$$;

-- §2.2 step 3. Only the caller's own started call in the current tenant. Text is kept for insights and
-- assist only (D6); import cell text never lands here.
create function private.ai_finish(
  p_id uuid, p_status text, p_provider text, p_model text,
  p_input_tokens integer, p_output_tokens integer, p_cache_read_tokens integer,
  p_cost_micro_usd bigint, p_latency_ms integer, p_error_code text, p_request jsonb, p_output jsonb)
returns void language plpgsql volatile security definer set search_path = '' as $$
begin
  if p_status not in ('ok', 'error') then
    raise exception 'ai_bad_call' using errcode = '22023';
  end if;
  update public.ai_call c set
    status = p_status, provider = p_provider, model = p_model,
    input_tokens = p_input_tokens, output_tokens = p_output_tokens, cache_read_tokens = p_cache_read_tokens,
    cost_micro_usd = p_cost_micro_usd, latency_ms = p_latency_ms, error_code = left(p_error_code, 60),
    request = case when c.feature in ('insights', 'assist') then p_request end,
    output  = case when c.feature in ('insights', 'assist') then p_output end,
    finished_at = now()
  where c.id = p_id and c.tenant_id = private.current_tenant_id() and c.user_id = (select auth.uid())
    and c.status = 'started';
  if not found then
    raise exception 'ai call not found' using errcode = 'P0002';
  end if;
end;
$$;

-- §6.4: what the user did with the answer (10.7, 10.9). Own calls only.
create function private.ai_set_outcome(p_id uuid, p_outcome text)
returns void language plpgsql volatile security definer set search_path = '' as $$
begin
  update public.ai_call c set outcome = p_outcome
  where c.id = p_id and c.tenant_id = private.current_tenant_id() and c.user_id = (select auth.uid())
    and c.status = 'ok';
  if not found then
    raise exception 'ai call not found' using errcode = 'P0002';
  end if;
end;
$$;

revoke all on function private.ai_begin(text, uuid, bigint),
  private.ai_finish(uuid, text, text, text, integer, integer, integer, bigint, integer, text, jsonb, jsonb),
  private.ai_set_outcome(uuid, text) from public, anon;
grant execute on function private.ai_begin(text, uuid, bigint),
  private.ai_finish(uuid, text, text, text, integer, integer, integer, bigint, integer, text, jsonb, jsonb),
  private.ai_set_outcome(uuid, text) to authenticated;

-- §2.3: daily. A started row older than an hour is lost (it keeps counting at its estimate). Question and
-- output text go after 90 days; token and cost numbers stay.
create function private.ai_housekeeping()
returns void language sql volatile set search_path = '' as $$
  update public.ai_call set status = 'lost', finished_at = now()
  where status = 'started' and created_at < now() - interval '1 hour';
  update public.ai_call set request = null, output = null
  where (request is not null or output is not null) and created_at < now() - interval '90 days';
$$;
revoke all on function private.ai_housekeeping() from public, anon, authenticated;
select cron.schedule('assetly_ai_housekeeping', '23 3 * * *', 'select private.ai_housekeeping()');
