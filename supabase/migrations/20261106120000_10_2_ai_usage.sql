-- Story 10.2: the AI usage tab in Settings reads this (docs/data-model-goal10.md §3). Read only.
-- OWNER REVIEW (CLAUDE.md §9): security definer, so it can read the cap (tenant_entitlement) and member names
-- (user_profile) for an ai_usage.view holder who may not hold users_security.view. It checks the tenant claim
-- and ai_usage.view itself and returns null without the right or without a live ai_addon (the tab then hides).
-- Spend and cap follow private.ai_begin exactly: cost, else the estimate; limit_value in US cents, null = 500; UTC month.
create function public.ai_usage()
returns jsonb language sql stable security definer set search_path = '' as $$
  with cap as (
    select coalesce(e.limit_value, 500)::bigint * 10000 as micro_usd
    from public.tenant_entitlement e
    where e.tenant_id = private.current_tenant_id() and e.feature_code = 'ai_addon' and e.deleted_at is null
      and e.valid_from <= now() and (e.valid_to is null or e.valid_to > now())
    order by e.valid_from desc
    limit 1
  ), month as (
    select c.feature, coalesce(c.cost_micro_usd, c.est_micro_usd) as spent
    from public.ai_call c
    where c.tenant_id = private.current_tenant_id()
      and c.created_at >= date_trunc('month', now() at time zone 'utc') at time zone 'utc'
  )
  select jsonb_build_object(
    'cap_micro_usd', cap.micro_usd,
    'spent_micro_usd', (select coalesce(sum(m.spent), 0) from month m),
    'features', (select coalesce(jsonb_agg(f order by f.feature), '[]')
                 from (select m.feature, count(*) as calls, sum(m.spent) as spent_micro_usd
                       from month m group by m.feature) f),
    'calls', (select coalesce(jsonb_agg(r order by r.created_at desc), '[]')
              from (select c.id, c.created_at, p.display_name as user_name, c.feature, c.status,
                           c.input_tokens, c.output_tokens, coalesce(c.cost_micro_usd, c.est_micro_usd) as cost_micro_usd
                    from public.ai_call c
                    left join public.user_profile p on p.id = c.user_id
                    where c.tenant_id = private.current_tenant_id()
                    order by c.created_at desc
                    limit 50) r))
  from cap
  where private.has_permission('ai_usage', 'view');
$$;
revoke all on function public.ai_usage() from public, anon;
grant execute on function public.ai_usage() to authenticated;
