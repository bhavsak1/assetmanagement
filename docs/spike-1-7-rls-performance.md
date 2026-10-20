# Spike 1.7: RLS and scope-check performance on about 1M assets

Date: 20 Oct 2026. Status: In review. Local only; nothing here touched staging, CI or `seed.sql`.

**Short answer.** The Goal 1 design holds. The helpers (`current_tenant_id()`, `has_permission()`, `tenant_can_write()`) run once per query as InitPlans and cost about 1 to 2 ms in total. They do not slow down with 45 groups. Writes with the audit trigger take about 7 ms. D7 option X (store `scope_profile_id`, check scope through the closure table) works, **but only in set form**. A per-row scope helper is 100 to 1000 times slower. The slow reads came from **index and query shape on the asset table**, not from Goal 1. Two Goal 1 rebuild fixes were worth making before staging, and are now made in migration `1_7_rebuild_triggers` (section 6). G1: policy changes now refresh each member once per statement; saving 20 policies on a group with 80 members went from 6.7 s to 0.27 s. G2: the rebuild no longer writes duplicate rows.

## 1. Setup and data shape

| Item | Value |
|---|---|
| Machine | Windows 11, Docker Desktop, local Supabase stack, Postgres 17. Timings are noisy (p95 jumps); treat them as order of magnitude |
| Tenants | 200: three large (200k, 150k, 100k), then a power-law tail. Median 1,183 assets, smallest 650 |
| Assets | 950,595 in `spike.asset`, 2% soft-deleted. Table 387 MB with indexes |
| Users | 2,307 (5 to 400 per tenant), each with one starter group via `seed_starter_groups` and the real rebuild triggers |
| Locations | site > building > area (large tenant: 5 sites, 1,055 nodes) plus a closure table |
| Scope | 10% of users in the three large tenants are scoped, either to one site (20% of assets) or to one area (0.1%) |
| Many groups | One user with 45 assignments: 5 starter groups and 40 copies of Tenant Admin. That is 2,028 effective rows, 47 of them distinct |
| `user_effective_permission` | 61,232 rows, 28 MB |

The stand-in asset table copies the 1.4 pattern exactly: std columns, `unique (tenant_id, id)`, composite FKs to location, category and vendor, the `set_updated_at`, `check_soft_delete('asset_core','delete')` and `audit` triggers, and the same three policies. The select policy adds the scope check. Stand-ins for 2.3 (location, closure) and 6.1 (scope profile and rule, plus `user_effective_permission.scope_profile_id`) exist only in the local `spike` schema.

Method: `spike.bench()` runs each statement 31 times as the user (`tests.act_as`: role `authenticated` plus JWT claims), rolls each run back, and drops the first run as warm-up. It records p50, p95 and max wall-clock time inside Postgres (planning plus execution, no network or JSON). It also saves one `EXPLAIN (ANALYZE, BUFFERS)` plan. Every plan is in `spike.result.plan`.

## 2. Targets (proposed)

The docs set no numbers. **These are my proposals**, for local hardware, measured inside the database:

| Query | p95 target |
|---|---|
| List page (50 rows, sorted), lookup | 100 ms list, 20 ms lookup |
| Search by name (50 rows) | 200 ms |
| Count, large tenant | 200 ms |
| Single write with audit | 50 ms |
| Rebuild after one assignment change | 50 ms |
| Rebuild after a group change (all members) | 2 s |

## 3. Results, as built (1.4 pattern, indexes a first draft would have)

Large = 200k tenant, small = about 1.2k tenant. Times in ms.

| # | Query | Rows | p50 | p95 | Plan summary | Verdict |
|---|---|---|---|---|---|---|
| 01 | List 50 by name, large, admin | 50 | 96 | 444 | Read all 196k tenant rows through `asset_code_uq`, then top-N sort | **Fail** |
| 02 | List 50 by name, small | 50 | 4 | 6 | Same plan, small tenant | Pass |
| 03 | Same as 01, no RLS (postgres) | 50 | 0.14 | 0.4 | Walk `(tenant_id, name)` index, stop at 50 | Baseline |
| 04 | List page 101 (offset 5000), large | 50 | 158 | 208 | Full read and sort | **Fail** |
| 05 | Count, large | 1 | 84 | 146 | Index scan of the tenant, filter per row | Pass |
| 06 | Count, small | 1 | 6 | 16 | | Pass |
| 07 | Count, large, explicit `tenant_id` filter | 1 | 67 | 88 | | Pass |
| 08 | Count, large, no RLS | 1 | 32 | 42 | | Baseline |
| 09 | Lookup by id, large | 1 | 1.5 | 2.3 | Primary key | Pass |
| 10 | Lookup by id, small | 1 | 2.1 | 4.0 | Primary key | Pass |
| 11 | Search "motor 0012" (rare), large | 0 | 276 | 477 | Trigram index not used: reads the whole tenant | **Fail** |
| 12 | Search "pump" (5% of rows), large | 50 | 271 | 433 | Name walk, 147k rows filtered out | **Fail** |
| 13 | Search "pump", small | 50 | 4 | 7 | | Pass |
| 14 | Search by code prefix, large | 50 | 5 | 7 | `asset_code_uq` range | Pass |
| 20 | Insert one asset (policy, FKs, audit) | – | 7 | 19 | | Pass |
| 21 | Update one asset | – | 7 | 13 | | Pass |
| 22 | Soft delete one asset (plus delete check) | – | 7 | 10 | | Pass |
| 23 | Update one asset, small | – | 8 | 11 | | Pass |
| 30 | List 50, large, Technician, no scope | 50 | 76 | 85 | As 01 | Pass, only just |
| 31 | List 50, large, scoped to 1 site (20%) | 50 | 233 | 325 | As 01, 157k rows filtered by scope | **Fail** |
| 32 | List 50, large, scoped to 1 area (0.1%) | 50 | 60 | 76 | As 01 | Pass |
| 33 | Count, large, site scope | 1 | 225 | 260 | `location_id = any(array of 211)` per row | **Fail** (just) |
| 34 | Count, large, area scope | 1 | 59 | 74 | | Pass |
| 35 | ROW-FORM scope, list, site scope | 50 | 72 | 98 | Helper called per row | Pass, by luck of plan |
| 36 | ROW-FORM scope, list, area scope | 50 | 12,914 | 13,629 | Helper called 196k times | **Fail** |
| 37 | ROW-FORM scope, count, site scope | 1 | 44,005 | 49,362 | | **Fail** |
| 38 | ROW-FORM scope, count, admin (no scope) | 1 | 53,351 | 61,670 | The per-row cost lands on unscoped users too | **Fail** |
| 40 | List 50, large, user with 45 groups | 50 | 84 | 137 | As 01 | Fail (same cause as 01) |
| 41 | Count, large, 45 groups | 1 | 53 | 62 | | Pass |
| 42 | `has_permission()` alone, 45 groups | 1 | 0.6 | 1.1 | Index `(tenant_id, user_id, domain_operation_id)` | Pass |
| 50 | Rebuild: assign 1 group to 1 user | – | 5 | 9 | Row trigger, 1 member | Pass |
| 51 | Rebuild: refresh the user with 45 groups | – | 90 | 154 | Writes 2,028 rows (43x duplicates) | **Fail** (target 50) |
| 52 | Rebuild: add 1 policy to Technician (80 users) | – | 281 | 363 | 80 member rebuilds | Pass |
| 53 | Rebuild: soft delete Technician group | – | 211 | 300 | 80 member rebuilds | Pass |
| 54 | Rebuild: refresh all 400 users of the tenant | 400 | 1,171 | 1,230 | About 3 ms per member | Pass |
| 55 | `seed_starter_groups` for a new tenant | – | 105 | 188 | No members yet | Pass |
| F3 | Save 20 policies on Technician (80 users) in one statement | – | 6,730 | 9,631 | Row trigger rebuilds each member 20 times | **Fail** |

### What the plans show

1. **Helpers run once per query.** Every RLS plan has `InitPlan 1..4` (tenant, `has_permission`, scope twice) with `loops=1`, and the filter refers to `(InitPlan n).col1`. None of them run per row. The `(select ...)` wrapping in the 1.4 pattern works.
2. **The planner cannot see the tenant.** `tenant_id = (select current_tenant_id())` is an InitPlan parameter, so the planner estimates an *average* tenant (about 4.7k rows), not 200k. For a small tenant, read-all-then-sort is correct. For a large tenant it reads 196k rows (fails 01, 04, 31, 40).
3. **`ilike` cannot use an index under RLS.** `texticlike` is not leakproof, so Postgres must apply the policy before the search condition and cannot push it into an index. Without RLS the same rare-term search takes 4 ms through the trigram index; with RLS it takes 270 ms (fails 11). This holds for full-text `@@` too. It is a Postgres rule, not a bug in our policies.
4. **A row-form scope helper is a trap.** A `security definer` function cannot be inlined, so `in_scope_row(location_id)` runs once per row. It even slows unscoped users (38: 53 s for a count).
5. **The rebuild does not dedupe.** One row per assignment per policy, so the user with 45 groups holds 2,028 rows for 47 distinct grants. Reads do not notice (42 is 0.6 ms), but the rebuild writes 43 times the rows.

## 4. Fixes tried (spike only)

| # | Fix | Query | Before p50 / p95 | After p50 / p95 |
|---|---|---|---|---|
| F2 | Sort index partial like the filter the app always sends: `(tenant_id, name) where deleted_at is null` | 01 list, large | 96 / 444 | **2.2 / 4.1** |
| F2 | | 04 page 101, large | 158 / 208 | **7.6 / 23** |
| F2 | | 31 list, site scope | 233 / 325 | **5.1 / 11** |
| F2 | | 32 list, area scope | 60 / 76 | 60 / 139 (walks 61k index rows to find 50) |
| F2 | | 02 list, small | 4 / 6 | 3.2 / 7.1 |
| F1 | App sends `tenant_id = <active tenant>` too (no index change) | 01 list, large | 96 / 444 | 2.3 / 5.5 |
| F1 | | 04 page 101, large | 158 / 208 | 220 / 454 (no help) |
| F4 | Trigram GIN on `(tenant_id, name)` via `btree_gin` | 11 search rare | 276 / 477 | 435 / 759 (no help: point 3 above) |
| F5 | Id-only search helper (`security definer`, same tenant, permission and scope checks, InitPlan form) used as `id in (select search_asset_ids(term))`; RLS still checks every returned row | 11 search rare, large | 276 / 477 | **8.3 / 16** |
| F5 | | 12 search "pump", large | 271 / 433 | **85 / 193** |
| F5 | | 13 search "pump", small | 4 / 7 | 5.7 / 8 |
| F5 | | 14 search "motor", site scope | – | 48 / 76 |

F2 alone fixes the list pages without app changes, so F1 is not needed.

## 5. Pass and fail summary

- **Pass, no change needed:** tenant check, `has_permission()`, `tenant_can_write()`, composite FKs, the soft-delete guard, the audit trigger on writes, lookups, counts in small tenants, single-assignment rebuilds, `seed_starter_groups`, and many groups on the read path.
- **Pass after asset-table fixes (Goal 3, no Goal 1 change):** list pages and deep pages (F2), name search (F5).
- **Still marginal:** count in the large tenant with site scope (225 / 260 ms), and list with a very narrow scope (60 / 139 ms).
- **Failed in Goal 1, now fixed (G1, G2):** bulk policy saves on a group with many members (F3: 6.7 s, now 267 ms), and the rebuild for the many-groups user (90 ms, now 7.7 ms).

## 6. Recommended changes

### Goal 1 (1.1 to 1.6 objects). Owner said yes on 20 Oct 2026. Done in migration `1_7_rebuild_triggers`, tests in `1_7_rebuild_triggers.test.sql`

| # | Change | Measured gain (re-run on a fresh load) | Cost to reverse |
|---|---|---|---|
| G1 | `group_domain_policy` triggers are now **statement-level with transition tables** (`private.on_policy_change()`). They collect the groups the statement touched, old and new rows, then refresh each affected member once. This replaces the row-level shortcut that 1.3 flagged in a comment. `user_group_assignment`, `tenant_membership` and `security_group` stay row-level (one member or one group per row is already cheap) | F3, 20 policies on 80 members: **6,730 / 9,631 ms down to 267 / 631 ms** (p50 / p95). Row 52, one policy: 281 / 363 down to 159 / 235 ms | Low: one trigger function and three trigger definitions. No table or column change |
| G2 | The rebuild inserts `select distinct`, so a grant that two groups give with the same window is one row. 6.1 must keep `scope_profile_id` in the distinct | Row 51, the user with 45 groups: **90 / 154 ms down to 7.7 / 9.0 ms**. Rows down from 2,028 to 67 (47 operations; the rest differ by effective window) | None: function body only. Reads are the same either way. A 1.3 test changed from 8 to 7 rows for this reason |

Nothing else in Goal 1 needs to change. `has_permission()` joining to `security_domain` and `domain_operation` by code costs 0.6 ms with 45 groups. Caching the operation id is not worth it.

### Goal 3 (asset table) and the 1.4 template. No change now; adopt when the stories come

1. **Every sort index is partial `where deleted_at is null` and leads with `tenant_id`** (F2). The 1.4 template already does this for `rls_sample_name_uq`; carry it to each list sort column (name, code, updated_at).
2. **Search goes through an id-only search helper** (F5), not `ilike` on the table, because of the leakproof rule. The helper repeats the tenant, permission and scope checks in InitPlan form. RLS still filters the returned rows. Use a trigram GIN on `(tenant_id, name)` (`btree_gin` plus `pg_trgm`, both plain Postgres extensions, so portable).
3. **Counts:** use exact counts for small tenants, and PostgREST `count=estimated` or a capped count ("10,000+") for large lists.

### 6.1 scope (D7). Confirms option X, with one rule

- **Scope helpers must be set-returning and called once per statement** (`location_id = any((select scope_location_ids(...))::uuid[])`). Never call a per-row `in_scope(location_id)`. The cast matters: without it, `any` reads the subquery as rows.
- A narrow scope (one area) on a sort walk still reads many index rows (60 ms). If 6.1 needs better, try a second plan path for small scope arrays. Measure it then; do not build it now.
- Only the location dimension was measured. Four dimensions with OR across profiles need the helper to return one row per profile; measure that in 6.1.
- Option Y (explode scope into rows) is **not needed**: the set form reads 211 closure rows once per query.

## 7. Not covered

- The coverage view (open items section E): it does not exist until Goal 4.
- Network, PostgREST and JSON time; concurrency; a hosted instance (staging is a free-tier micro in Tokyo, and its numbers would be slower).
- Audit log at volume: the 1M load skipped the audit trigger. The audit log held 50k rows during the write tests.
- Custom-field JSONB filters and secure field views (Goal 2 and 6.x).

## 8. How to run

See README, "RLS performance spike". Scripts are in `scripts/spike-1-7/`: `01_setup.sql` (stand-ins, policies, bench function), `02_data.sql` (generator, about 2.5 min), `03_bench.sql` (about 14 min, mostly the row-form runs), `04_fixes.sql` (F1 to F5, about 3 min; it changes indexes, so run it last). Read the numbers with `select label, plan_rows, p50_ms, p95_ms from spike.result order by label;` and the plans with `select plan from spike.result where label like '01%';`. `npm run db:reset` removes everything.
