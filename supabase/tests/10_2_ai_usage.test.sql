-- Story 10.2: public.ai_usage() for the Settings AI tab (docs/data-model-goal10.md §3).
-- Uses the seed: tenant A (...0a, ai_addon with no limit), tenant B (...0b, no ai_addon),
-- test.user a1 (A and B, no groups), test.user2 a2 (B only).
begin;
select plan(15);

-- 1. Shape.
select ok((select prosecdef and proconfig @> array['search_path=""'] from pg_proc where oid = 'public.ai_usage()'::regprocedure),
          'ai_usage is security definer with search_path empty');
select ok(not has_function_privilege('anon', 'public.ai_usage()', 'execute'), 'anon cannot call ai_usage');

-- Rows written as owner, like ai_begin would. A: two this month (one finished, one started at its estimate),
-- one last month. B: one this month.
insert into public.ai_call (tenant_id, user_id, feature, status, est_micro_usd, cost_micro_usd, input_tokens, output_tokens, created_at)
values ('00000000-0000-0000-0000-00000000000a', '00000000-0000-0000-0000-0000000000a1', 'insights', 'ok', 900, 200, 1000, 50, now() - interval '2 minutes'),
       ('00000000-0000-0000-0000-00000000000a', '00000000-0000-0000-0000-0000000000a1', 'check', 'started', 5000, null, null, null, now() - interval '1 minute'),
       ('00000000-0000-0000-0000-00000000000a', '00000000-0000-0000-0000-0000000000a1', 'insights', 'ok', 1, 777777, 1, 1,
        date_trunc('month', now() at time zone 'utc') at time zone 'utc' - interval '1 hour'),
       ('00000000-0000-0000-0000-00000000000b', '00000000-0000-0000-0000-0000000000a1', 'check', 'ok', 1, 333, 1, 1, now());

-- 2. No ai_usage.view: nothing.
select tests.act_as('00000000-0000-0000-0000-0000000000a1', '00000000-0000-0000-0000-00000000000a');
select is(public.ai_usage(), null, 'no ai_usage.view: null');

-- 3. With the right: spend, cap, features, calls of A only.
reset role;
select tests.grant('00000000-0000-0000-0000-00000000000a', '00000000-0000-0000-0000-0000000000a1', 'ai_usage', '{view}');
select tests.act_as('00000000-0000-0000-0000-0000000000a1', '00000000-0000-0000-0000-00000000000a');
create temp table t_u as select public.ai_usage() as u;
select is((select (u ->> 'cap_micro_usd')::bigint from t_u), 5000000::bigint, 'null limit_value: cap 500 cents');
select is((select (u ->> 'spent_micro_usd')::bigint from t_u), 5200::bigint,
          'spend: this month only, cost else estimate, A only');
select is((select u -> 'features' from t_u),
          '[{"feature":"check","calls":1,"spent_micro_usd":5000},{"feature":"insights","calls":1,"spent_micro_usd":200}]'::jsonb,
          'calls and spend per feature this month');
select is((select jsonb_array_length(u -> 'calls') from t_u), 3, 'last calls: A rows of any month, not B');
select is((select u -> 'calls' -> 0 ->> 'feature' from t_u), 'check', 'newest call first');
select is((select array[c ->> 'user_name', c ->> 'status', c ->> 'input_tokens', c ->> 'cost_micro_usd']
           from t_u, jsonb_array_elements(u -> 'calls') c where c ->> 'feature' = 'insights' order by c ->> 'created_at' desc limit 1),
          array['Test User', 'ok', '1000', '200'], 'a call carries user name, status, tokens and cost');

reset role;
update public.tenant_entitlement set limit_value = 100
where tenant_id = '00000000-0000-0000-0000-00000000000a' and feature_code = 'ai_addon';
select tests.act_as('00000000-0000-0000-0000-0000000000a1', '00000000-0000-0000-0000-00000000000a');
select is((public.ai_usage() ->> 'cap_micro_usd')::bigint, 1000000::bigint, 'limit_value 100 cents: cap 1,000,000 micro USD');

-- 4. Only the last 50 calls.
reset role;
insert into public.ai_call (tenant_id, user_id, feature, status, est_micro_usd, cost_micro_usd, created_at)
select '00000000-0000-0000-0000-00000000000a', '00000000-0000-0000-0000-0000000000a1', 'check', 'ok', 1, 1,
       now() - make_interval(secs => g)
from generate_series(1, 55) g;
select tests.act_as('00000000-0000-0000-0000-0000000000a1', '00000000-0000-0000-0000-00000000000a');
select is(jsonb_array_length(public.ai_usage() -> 'calls'), 50, 'at most 50 calls');

-- 5. Cross-tenant and no add-on.
-- a2 is in B only and forges a tenant A claim: holds nothing in A.
select tests.act_as('00000000-0000-0000-0000-0000000000a2', '00000000-0000-0000-0000-00000000000a');
select is(public.ai_usage(), null, 'forged tenant claim: null');
-- a1 with ai_usage.view in B, which has no ai_addon: null, so the tab hides.
reset role;
select tests.grant('00000000-0000-0000-0000-00000000000b', '00000000-0000-0000-0000-0000000000a1', 'ai_usage', '{view}');
select tests.act_as('00000000-0000-0000-0000-0000000000a1', '00000000-0000-0000-0000-00000000000b');
select is(public.ai_usage(), null, 'tenant without ai_addon: null');
-- Expired add-on in A: null.
reset role;
update public.tenant_entitlement set valid_from = now() - interval '1 day', valid_to = now() - interval '1 second'
where tenant_id = '00000000-0000-0000-0000-00000000000a' and feature_code = 'ai_addon';
select tests.act_as('00000000-0000-0000-0000-0000000000a1', '00000000-0000-0000-0000-00000000000a');
select is(public.ai_usage(), null, 'expired ai_addon: null');
-- No session at all.
reset role;
set local role anon;
select throws_ok('select public.ai_usage()', '42501', null, 'anon is refused');

select * from finish();
rollback;
