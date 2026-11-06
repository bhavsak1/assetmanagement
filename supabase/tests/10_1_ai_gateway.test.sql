-- Story 10.1: ai_call, ai_begin, ai_finish, ai_set_outcome (docs/data-model-goal10.md §2.3).
-- Uses the seed: tenant A (...0a, active, ai_addon with no limit), tenant B (...0b, read_only, no ai_addon),
-- test.user a1 (A and B, no groups), test.user2 a2 (B only). Adds u3, a second member of A.
begin;
select plan(44);

create function pg_temp.err(p_sql text) returns text language plpgsql as $$
begin
  execute p_sql;
  return 'ok';
exception when others then
  return sqlerrm;
end;
$$;

insert into auth.users (instance_id, id, aud, role, email, raw_app_meta_data, raw_user_meta_data, created_at, updated_at)
values ('00000000-0000-0000-0000-000000000000', '00000000-0000-0000-0000-0000000010a3', 'authenticated',
        'authenticated', 'u3.ai@example.com', '{}', '{}', now(), now());
insert into public.user_profile (id, display_name, email)
values ('00000000-0000-0000-0000-0000000010a3', 'AI user three', 'u3.ai@example.com');
insert into public.tenant_membership (tenant_id, user_id)
values ('00000000-0000-0000-0000-00000000000a', '00000000-0000-0000-0000-0000000010a3');

-- 1. Shape: RLS on, no direct writes, the functions are definer with a fixed search_path.
select ok((select relrowsecurity from pg_class where oid = 'public.ai_call'::regclass), 'ai_call has RLS on');
select ok(not has_table_privilege('authenticated', 'public.ai_call', 'insert'), 'authenticated cannot insert ai_call');
select ok(not has_table_privilege('authenticated', 'public.ai_call', 'update'), 'authenticated cannot update ai_call');
select ok(not has_table_privilege('authenticated', 'public.ai_call', 'delete'), 'authenticated cannot delete ai_call');
select is((select count(*)::int from pg_proc p join pg_namespace n on n.oid = p.pronamespace
           where n.nspname = 'private' and p.proname in ('ai_begin', 'ai_finish', 'ai_set_outcome')
             and p.prosecdef and p.proconfig @> array['search_path=""']), 3,
          'ai functions are security definer with search_path empty');
select ok(not has_function_privilege('anon', 'private.ai_begin(text, uuid, bigint)', 'execute'), 'anon cannot call ai_begin');
select ok(not has_function_privilege('authenticated', 'private.ai_housekeeping()', 'execute'), 'authenticated cannot call ai_housekeeping');

-- 2. Refusals.
select tests.act_as('00000000-0000-0000-0000-0000000000a1', '00000000-0000-0000-0000-00000000000a');
select is(pg_temp.err($$select private.ai_begin('insights', null, 100)$$), 'ai_no_right', 'no insights_query.ask: ai_no_right');
select is(pg_temp.err($$select private.ai_begin('nope', null, 100)$$), 'ai_bad_call', 'unknown feature: ai_bad_call');
select is(pg_temp.err($$select private.ai_begin('insights', null, -1)$$), 'ai_bad_call', 'negative estimate: ai_bad_call');

reset role;
select tests.grant('00000000-0000-0000-0000-00000000000b', '00000000-0000-0000-0000-0000000000a1', 'insights_query');
select tests.act_as('00000000-0000-0000-0000-0000000000a1', '00000000-0000-0000-0000-00000000000b');
select is(pg_temp.err($$select private.ai_begin('insights', null, 100)$$), 'ai_not_licensed', 'tenant without ai_addon: ai_not_licensed');

reset role;
update public.tenant_entitlement set valid_to = now() - interval '1 second', valid_from = now() - interval '1 day'
where tenant_id = '00000000-0000-0000-0000-00000000000a' and feature_code = 'ai_addon';
select tests.grant('00000000-0000-0000-0000-00000000000a', '00000000-0000-0000-0000-0000000000a1', 'insights_query');
select tests.act_as('00000000-0000-0000-0000-0000000000a1', '00000000-0000-0000-0000-00000000000a');
select is(pg_temp.err($$select private.ai_begin('insights', null, 100)$$), 'ai_not_licensed', 'expired ai_addon: ai_not_licensed');
reset role;
update public.tenant_entitlement set valid_to = null
where tenant_id = '00000000-0000-0000-0000-00000000000a' and feature_code = 'ai_addon';

-- a2 is in B only and forges a tenant A claim: holds nothing in A.
select tests.act_as('00000000-0000-0000-0000-0000000000a2', '00000000-0000-0000-0000-00000000000a');
select is(pg_temp.err($$select private.ai_begin('insights', null, 100)$$), 'ai_no_right', 'forged tenant claim: ai_no_right');

-- 3. Begin and finish.
select tests.act_as('00000000-0000-0000-0000-0000000000a1', '00000000-0000-0000-0000-00000000000a');
create temp table t_call as select private.ai_begin('insights', null, 5000) as id;
select is((select status from public.ai_call where id = (select id from t_call)), 'started', 'begin logs a started row');
select is((select user_id from public.ai_call where id = (select id from t_call)),
          '00000000-0000-0000-0000-0000000000a1'::uuid, 'the row is the caller''s');
select lives_ok($$select private.ai_finish((select id from t_call), 'ok', 'anthropic', 'claude-haiku-5-5', 1000, 200, 0,
                                           200, 900, null, '{"question":"q"}', '{"subject":"asset"}')$$, 'finish own call');
select is((select array[status, provider, request ->> 'question', cost_micro_usd::text] from public.ai_call where id = (select id from t_call)),
          array['ok', 'anthropic', 'q', '200'], 'finish stores status, provider, question and cost');
select is(pg_temp.err($$select private.ai_finish((select id from t_call), 'ok', null, null, null, null, null, 0, 0, null, null, null)$$),
          'ai call not found', 'a finished call cannot be finished again');
select is(pg_temp.err($$select private.ai_finish((select id from t_call), 'started', null, null, null, null, null, 0, 0, null, null, null)$$),
          'ai_bad_call', 'finish only to ok or error');
select lives_ok($$select private.ai_set_outcome((select id from t_call), 'edited')$$, 'set outcome on own call');
select is((select outcome from public.ai_call where id = (select id from t_call)), 'edited', 'outcome stored');

-- Import calls never keep text (D6).
reset role;
select tests.grant('00000000-0000-0000-0000-00000000000a', '00000000-0000-0000-0000-0000000000a1', 'excel_import', '{run}');
select tests.act_as('00000000-0000-0000-0000-0000000000a1', '00000000-0000-0000-0000-00000000000a');
create temp table t_imp as select private.ai_begin('import_map', null, 100) as id;
select private.ai_finish((select id from t_imp), 'error', 'vertex', 'claude-haiku-5-5', 10, 0, 0, 1, 50, 'overloaded',
                         '{"cells":"x"}', '{"m":1}');
select is((select array[status, error_code, request::text, output::text] from public.ai_call where id = (select id from t_imp)),
          array['error', 'overloaded', null, null], 'import call keeps no request or output text');

-- 4. Another user's call: unreadable without ai_usage.view, and cannot be finished or marked.
reset role;
select tests.grant('00000000-0000-0000-0000-00000000000a', '00000000-0000-0000-0000-0000000010a3', 'insights_query');
select tests.act_as('00000000-0000-0000-0000-0000000010a3', '00000000-0000-0000-0000-00000000000a');
create temp table t_u3 as select private.ai_begin('insights', null, 100) as id;
select is(pg_temp.err($$select private.ai_finish((select id from t_call), 'ok', null, null, null, null, null, 0, 0, null, null, null)$$),
          'ai call not found', 'cannot finish another user''s call');
select is(pg_temp.err($$select private.ai_set_outcome((select id from t_call), 'saved')$$),
          'ai call not found', 'cannot mark another user''s call');
select is((select count(*)::int from public.ai_call where user_id <> '00000000-0000-0000-0000-0000000010a3'), 0,
          'without ai_usage.view: only own calls visible');
reset role;
select tests.grant('00000000-0000-0000-0000-00000000000a', '00000000-0000-0000-0000-0000000010a3', 'ai_usage', '{view}');
select tests.act_as('00000000-0000-0000-0000-0000000010a3', '00000000-0000-0000-0000-00000000000a');
select is((select count(*)::int from public.ai_call where user_id = '00000000-0000-0000-0000-0000000000a1'), 2,
          'with ai_usage.view: the tenant''s calls visible');
select isnt(pg_temp.err($$select private.ai_begin('check', null, 1)$$), 'ai_no_right', 'ai_usage.view may run the check call');

-- 5. Cap: limit_value is US cents; spent = cost, or the estimate while unfinished.
reset role;
delete from public.ai_call where tenant_id = '00000000-0000-0000-0000-00000000000a';
update public.tenant_entitlement set limit_value = 1  -- 1 cent = 10,000 micro USD
where tenant_id = '00000000-0000-0000-0000-00000000000a' and feature_code = 'ai_addon';
select tests.act_as('00000000-0000-0000-0000-0000000000a1', '00000000-0000-0000-0000-00000000000a');
select is(pg_temp.err($$select private.ai_begin('insights', null, 9000)$$), 'ok', 'under the cap: allowed');
select is(pg_temp.err($$select private.ai_begin('insights', null, 1001)$$), 'ai_cap_reached', 'estimate over the cap: ai_cap_reached');
select is(pg_temp.err($$select private.ai_begin('insights', null, 1000)$$), 'ok', 'exactly at the cap: allowed');
select is(pg_temp.err($$select private.ai_begin('insights', null, 1)$$), 'ai_cap_reached', 'at the cap: ai_cap_reached');
reset role;
update public.ai_call set created_at = date_trunc('month', now()) - interval '1 day'
where tenant_id = '00000000-0000-0000-0000-00000000000a';
select tests.act_as('00000000-0000-0000-0000-0000000000a1', '00000000-0000-0000-0000-00000000000a');
select is(pg_temp.err($$select private.ai_begin('insights', null, 9000)$$), 'ok', 'last month''s spend does not count');

-- 6. Rate limit: 20 calls a minute per user.
reset role;
update public.tenant_entitlement set limit_value = null
where tenant_id = '00000000-0000-0000-0000-00000000000a' and feature_code = 'ai_addon';
insert into public.ai_call (tenant_id, user_id, feature, est_micro_usd)
select '00000000-0000-0000-0000-00000000000a', '00000000-0000-0000-0000-0000000000a1', 'insights', 0
from generate_series(1, 19);
select tests.act_as('00000000-0000-0000-0000-0000000000a1', '00000000-0000-0000-0000-00000000000a');
select is(pg_temp.err($$select private.ai_begin('insights', null, 1)$$), 'ai_rate_limited', '20 calls in a minute: ai_rate_limited');
select tests.act_as('00000000-0000-0000-0000-0000000010a3', '00000000-0000-0000-0000-00000000000a');
select is(pg_temp.err($$select private.ai_begin('insights', null, 1)$$), 'ok', 'the limit is per user');

-- 7. Housekeeping: an old started row is lost and still counts; old text is cleared.
reset role;
update public.ai_call set created_at = now() - interval '2 hours'
where tenant_id = '00000000-0000-0000-0000-00000000000a' and est_micro_usd = 0;
insert into public.ai_call (tenant_id, user_id, feature, status, est_micro_usd, cost_micro_usd, request, created_at)
values ('00000000-0000-0000-0000-00000000000a', '00000000-0000-0000-0000-0000000000a1', 'insights', 'ok', 5, 5,
        '{"question":"old"}', now() - interval '91 days');
select private.ai_housekeeping();
select is((select count(*)::int from public.ai_call where est_micro_usd = 0 and status = 'lost'), 19, 'old started rows become lost');
select is((select count(*)::int from public.ai_call where request ->> 'question' = 'old'), 0, 'text older than 90 days is cleared');

-- 8. Cross-tenant (CLAUDE.md §6.8).
select * from tests.cross_tenant('public.ai_call', 'ai_usage',
  '{"user_id":"00000000-0000-0000-0000-0000000000a1","feature":"check","est_micro_usd":0}');

select * from finish();
rollback;
