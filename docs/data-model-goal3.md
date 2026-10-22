# Goal 3 data model: asset (story 3.1)

**Status:** done, 22 Oct 2026. Owner answered A1 to A6 on 22 Oct 2026 (section 9). Built in the `3_1_*` migrations.

**Reads with:** CLAUDE.md §6 to §8, `security-model.md` §4 and §8, [data-model-goal1.md](data-model-goal1.md) §1 (conventions) and D7, [data-model-goal2.md](data-model-goal2.md) §1.2, §2 and §5 (fields, values, 2.5 mandatory rules), [data-model-goal2-locations.md](data-model-goal2-locations.md), [spike-1-7-rls-performance.md](spike-1-7-rls-performance.md) §3 and §6.

**Open items used (current lean, not settled):** OQ-01 (quantity, default 1, no split), OQ-04 (Disposed terminal, admin reopen with reason), OQ-07 (parent and child, cap 5 levels, no cascade), B9 (tag pattern, atomic counter, override needs a permission), B11 (status transitions, reason for Inactive and Disposed). OQ-06 does not apply yet (vendors are Goal 4).

**Owner change to CLAUDE.md §8:** asset status is no longer only a fixed lifecycle. The 5 system statuses stay fixed; tenants add their own statuses mapped to them, per category (A2, story 3.7). CLAUDE.md §8 is out of date on this point.

---

## 1. `asset` (public, 1.4 RLS pattern)

| Column | Type | Notes |
|---|---|---|
| id, tenant_id, std | | Standard (goal 1 §1) |
| tag | text not null | Human identifier, printed on labels. Stored in upper case. Unique per tenant among live rows. Generated when not given [A1] |
| name | text not null | Not unique (two "Pump 01" in two plants is normal) |
| category_id | uuid not null | Composite FK `(tenant_id, category_id) → asset_category`. Always required (2.5) |
| location_id | uuid null | Composite FK `(tenant_id, location_id) → location`. Optional, tenant can make it mandatory (2.5 M1 `location`) |
| status | text not null default `'active'` | System status: `check in ('in_stock', 'active', 'under_maintenance', 'inactive', 'disposed')` [A2]. Text plus check, not an enum |
| status_reason | text null | Reason of the last status change. Required for `inactive`, `disposed` and reopen |
| status_changed_at | timestamptz null | Set by the status action |
| quantity | integer not null default 1 | `check (quantity >= 1)`. OQ-01 lean: a lot is one row with a count. No split, no partial transfer |
| parent_asset_id | uuid null | Composite FK to `asset`. OQ-07 lean: optional, max 5 levels, no cycle, nothing cascades to children |
| criticality | text null | `check in ('A', 'B', 'C')`. On the detail screen; a D7 scope dimension (F22) |
| serial_number, manufacturer, model | text null | System fields from 2.5 M1. Real columns, not custom fields: import dedupe and search need them |
| purchase_date | date null | Domain `asset_core` (a date is not sensitive) |
| purchase_value | numeric(19,4) null | Domain **`asset_financials`**. `check (purchase_value >= 0)`. 4 decimals: some currencies use 3 |
| purchase_currency | char(3) null | `check (purchase_currency ~ '^[A-Z]{3}$')`, `check (purchase_value is null or purchase_currency is not null)`. The form defaults it to the tenant currency. No conversion (CLAUDE.md §8) |
| in_service_date | date null | 2.5 M1 |
| custom_values | jsonb not null default `'{}'` | `check (jsonb_typeof(custom_values) = 'object')`. Keyed by `field_definition.key` (G5). Section 4 |

- `unique (tenant_id, id)` for composite FKs.
- The 2.5 allowed list for `tenant.required_asset_fields` (`serial_number, manufacturer, model, location, purchase_date, purchase_value, in_service_date`) matches these columns. No change. `location` means `location_id`.
- **Not added (hooks only, knowledge base §12):** vendor columns [A5], depreciation (B14: one nullable column each when a story uses them; KB §12 only asks for purchase date and value, which are here), custody (B5, needs person and department tables), incident and work order links, telemetry, tenant status (3.7).

## 2. Tag (identifier) [A1]

- **Pattern per tenant:** `tenant.asset_tag_pattern text not null default 'AST-{SEQ:5}'`. The tenant builds its own pattern from:

  | Part | Gives |
  |---|---|
  | `{LOC}` | Code of the asset's location, or of its nearest ancestor with a code |
  | `{CAT}` | Code of the asset's category, or of its nearest ancestor with a code |
  | `{DATE:fmt}` | The creation date in the tenant time zone. `fmt` is built from `yyyy`, `yy`, `mmm` (OCT), `mm`, `dd`, optionally split by `-`, `/` or `.` |
  | `{SEQ:n}` | Counter, zero-padded to n digits (3 to 9), exactly once, last |
  | literal text | Letters, digits, `.`, `_`, `/`, `-` |

  Examples a tenant may choose: `{LOC}-{SEQ:4}` → `PNE-0412`; `{CAT}/{DATE:yyyymm}/{SEQ:3}` → `CNC/202610/001`. Nothing is hard-coded but the default.
- **Counter per prefix:** `private.asset_tag_counter (tenant_id, prefix, last_value)`. The prefix is the rendered text before `{SEQ}`, so a pattern with `{DATE:yyyymm}` starts at 1 every month, and `{LOC}` numbers each site on its own. Taken with `insert ... on conflict do update ... returning`: atomic, no gaps (it rolls back with the insert). If a typed tag already holds the next number, it skips forward.
- **When:** a before-insert trigger fills `tag` when it is null. Pattern needs `{LOC}` or `{CAT}` but no code is found up the tree: refused, "add a code or type a tag".
- **Setting the pattern:** action `public.set_asset_tag_pattern(p_pattern)` (`tenant_settings.manage`, `tenant_can_write()`, format check, audit row). The Settings field is a separate story (3.8).
- **Category code:** new `asset_category.code text null`, `check (code ~ '^[A-Za-z0-9._-]{1,20}$')`, unique per tenant among live rows (case-insensitive). The Code field on the category form is story 3.8.
- **Typed tag (override):** a user may type a tag, or change one later, only with the new operation `asset_core.set_tag` (B9). Goal 8 decides how imported tags are allowed (B9 says imports may bring their own).
- **Unique, upper case:** typed and generated tags are upper-cased, format check `^[A-Z0-9][A-Z0-9._/-]{0,59}$`, `unique (tenant_id, tag) where deleted_at is null`. Disposed assets are not deleted, so their tags stay taken. Why upper case: a lookup must be plain `tag = 'X'`. `lower(tag)` is not leakproof, so through the `security_barrier` view it cannot use an index (the spike's `ilike` rule); `=` on text is leakproof and can.
- **Stable:** a transfer (3.5) does not change the tag. Labels stay valid.
- No `asset_identifier` table yet [A4].

## 3. Status lifecycle [A2] [A3]

The 5 **system statuses** are fixed; reports, hooks and events use them. B11 transitions:

| From | To | Reason |
|---|---|---|
| (insert) | `in_stock`, `active` | |
| `in_stock` | `active`, `disposed` | required for `disposed` |
| `active` | `under_maintenance`, `inactive`, `disposed` | required for `inactive`, `disposed` |
| `under_maintenance` | `active`, `disposed` | required for `disposed` |
| `inactive` | `active`, `disposed` | required for `disposed` |
| `disposed` | reopen to `in_stock`, `active` or `inactive` | always required; needs `asset_lifecycle.reopen` [A3] |

- **Action, not a write** (CLAUDE.md §7.8): `public.change_asset_status(p_asset_id uuid, p_status text, p_reason text)`. `security definer`, fixed `search_path`. Checks: current tenant, `asset_core.view`, `asset_lifecycle.execute` (or `reopen` from `disposed`), `tenant_can_write()`, row locked `for update`, the table above, reason not blank where required. Sets `status`, `status_reason`, `status_changed_at`, `updated_by`.
- **Audit:** the generic `audit` trigger writes the update row (old and new status and reason) in the same transaction. The action also writes one outbox event `asset.status_changed` (knowledge base §6.6 names it).
- **Tenant statuses (story 3.7, not 3.1):** a tenant defines its own statuses, each mapped to exactly one system status (one system status can have many). Status sets attach to categories; a category without a set uses its parent's, then its grandparent's, and so on; no set anywhere means the 5 system statuses. A set is ordered: an asset may move to any later step, or back to an earlier one, and every move must still be a B11 move between the mapped system statuses, with the same reason rules. 3.7 adds a nullable `asset.status_id` and changes `change_asset_status`; nothing built in 3.1 changes shape.
- 3.5 builds the Retire dialog on this function. Transfer (location change with history) is 3.5.

### What a plain update may touch

Column grants, like `field_definition` (2.1):

| | Columns |
|---|---|
| insert | everything in §1 except `status_reason`, `status_changed_at`, std columns other than `created_by`, `updated_by` |
| update | `name`, `category_id`, `quantity`, `parent_asset_id`, `criticality`, `serial_number`, `manufacturer`, `model`, `purchase_date`, `purchase_value`, `purchase_currency`, `in_service_date`, `custom_values`, `tag` (trigger-gated, §2), `updated_by`, `deleted_at` |
| never by users | `tenant_id`, `status`, `status_reason`, `status_changed_at` (action only), `location_id` (3.5 transfer action; set freely on insert) |

A write of a column outside the grant fails with 42501, as `field_definition` does.

## 4. Custom values

### 4.1 Write checks (trigger, deterministic, in SQL)

`private.check_asset_values()`, before insert or update, `security definer` (must read every field definition, not only what RLS shows).

1. **Field line:** definitions with `entity = 'asset'`, not deleted, and `category_id` null or the asset's category or any ancestor (G3, recursive CTE up `parent_id`).
2. **Hidden keys kept:** for keys the user cannot view (field domain without `view`), the stored value is kept and whatever the client sent is ignored. A form that never saw a key cannot blank it (data-model-goal2 §2).
3. **Changed keys** (new, or value differs from the old row) must: be in the field line, be active, match the type (`text` string, `number` number, `date` string `YYYY-MM-DD` that casts, `boolean`, `list` an active option code), not be JSON `null` (omit the key instead), and the user must hold `update` on the field's domain.
4. **Unchanged keys** must still have a definition in the tenant (any category). So a category change or a deactivated field keeps old values (G4 keys never change meaning), and an unknown key is always refused.
5. **Financial columns:** a change to `purchase_value` or `purchase_currency` needs `asset_financials.update`.
6. **Mandatory (2.5):** `field_definition.is_required` in the line, plus `tenant.required_asset_fields`. Checked on insert, and on any user update that changes a data column (not on a soft delete, not inside the status action). M2: a mandatory field whose domain the user cannot update is skipped. One error lists every missing field.
7. Category and location must be active when set or changed (inactive ones drop out of pickers; old assets keep them).

Checks 2, 3, 5 and 6, the insert status rule and the `set_tag` rule run for every write with a signed-in user behind it (`auth.uid()` set): the UI, the API, actions, and later imports under the user's token, so one engine everywhere (CLAUDE.md §7.3). The status action changes no data column, so they never block it. Provisioning and system jobs have no user. Type checks run for everyone.

### 4.2 Reads: per-key domain filter (CLAUDE.md §7.7)

In the read view (§5): `a.custom_values - (select private.hidden_field_keys('asset'))`. The helper returns, once per statement, a `text[]` of keys whose field domain the user cannot view. Plain jsonb `-` per row, no `jsonb_each`. The 3.4 history, 3.3 form, exports and the AI layer use the same helper.

## 5. Read path [A6]

RLS cannot hide columns, so:

- **Base table:** `select` granted on every column **except** `purchase_value`, `purchase_currency`, `custom_values`. Base policies stay (1.4 pattern), so updates by id, the tenancy guard and `tests.cross_tenant` work.
- **View `public.asset_view`** (owner-run, `security_barrier`, like `my_permission`). The app reads assets only here. It repeats the base select policy (tenant, `asset_core.view`, helpers in `(select ...)`), shows **live rows only** (`deleted_at is null`), and masks:
  - `purchase_value`, `purchase_currency`: `case when (select private.has_permission('asset_financials', 'view')) then ... end`
  - `custom_values`: §4.2.
- Writes go to the base table (PostgREST `Prefer: return=minimal`, then read the view).
- **Asset history (owner, A6):** everyone who can view an asset sees its history, with purchase value and hidden custom keys masked. 3.4 builds `asset_history(asset_id)` on `hidden_field_keys()` and the same financials rule, so it does not depend on `audit_log.view`.
- **Audit log screen gap (flag for 6.2):** the raw `audit_log` rows hold purchase value and custom values. A tenant that grants `audit_log.view` without `asset_financials.view` leaks them there. Starter groups do not. 6.2 masks the audit log read.

## 6. RLS and scope

- **Domains:** `asset_core`, `asset_financials`, `asset_lifecycle` exist in the 1.2 catalog. 3.1 adds two operations (as data): `asset_core.set_tag` [A1] and `asset_lifecycle.reopen` [A3]. Starter grid: `set_tag` to Tenant Admin and Plant Manager, `reopen` to Tenant Admin. A new migration replaces `seed_starter_groups` with the new grid and backfills existing starter groups. The 1.6 test grid gets the same cells.
- **Policies:** the 1.4 template on `asset_core`: select `view`; insert `create` plus `tenant_can_write()`; update `update` plus `tenant_can_write()` in `using` and `with check`; no delete policy, delete and truncate revoked; `check_soft_delete('asset_core', 'delete')`; `set_updated_at`; `audit_row('data')`.
- **Row scope (D7) is not enforced in 3.1.** Scope is story 6.1. 3.1 keeps the scope columns (`location_id`, `category_id`, `criticality`; vendor in Goal 4) and writes every read path so 6.1 adds one set-form clause, never a per-row helper (spike §6): `and location_id = any ((select private.scope_location_ids(...))::uuid[])` in the base select policy, `asset_view`, `change_asset_status`, and the 3.2 search helper.

## 7. Parent and child (OQ-07)

Trigger `private.check_asset_parent()` on insert or `parent_asset_id` change: refuses a cycle, and refuses when parent depth plus the moved subtree height exceeds 5. Index `(tenant_id, parent_asset_id) where parent_asset_id is not null`. Status, coverage and obligations do not cascade.

## 8. Indexes and access path (spike §3, §6)

The planner cannot see the tenant (InitPlan), so every list index is **partial `where deleted_at is null` and leads with `tenant_id`** (F2). The view adds `deleted_at is null` itself, so every query matches the partial indexes.

| Query | Index | Spike result for this shape |
|---|---|---|
| List by name, 50 rows, large or small tenant | `(tenant_id, name, id) where deleted_at is null` (`id` for stable keyset paging) | 2.2 / 4.1 ms large, 3.2 / 7.1 small (F2) |
| List by last updated | `(tenant_id, updated_at desc, id) where deleted_at is null` | same shape as F2 |
| Lookup by tag (client upper-cases the input) | unique `(tenant_id, tag) where deleted_at is null` | 1 to 2 ms, index lookup |
| Lookup by id | primary key | 1.5 / 2.3 ms |
| Filter by category, location; 6.1 scope | `(tenant_id, category_id)`, `(tenant_id, location_id)`, both partial | |
| Children of an asset | `(tenant_id, parent_asset_id)` partial | |
| Count | exact; large tenant 84 / 146 ms (row 05). 3.2 may cap it ("10,000+") | |
| Search by name or tag | **3.2 builds it**: id-only `security definer` helper with the same tenant and permission checks, trigram GIN via `pg_trgm` and `btree_gin` (spike F5: 276 down to 8 ms). `ilike` on the view would read the whole tenant (leakproof rule) | |

3.1 tests `EXPLAIN` on the view: the list walks the name index with a limit, and the tag lookup uses the tag index.

## 9. Owner decisions (22 Oct 2026)

"Cost to reverse" assumes the table is on staging with real assets.

| # | Decision | Outcome | Cost to reverse |
|---|---|---|---|
| A1 | Tag generation | Tenant-built pattern from `{LOC}`, `{CAT}`, `{DATE:fmt}`, `{SEQ:n}` and literals; counter per prefix (so `{DATE:yyyymm}` restarts monthly); `asset_category.code` added for `{CAT}`; typed tag needs `asset_core.set_tag`. Settings field and category Code field: story 3.8 | Low for the generator; high for tags already printed |
| A2 | Status | 5 fixed system statuses (3.1). Tenant statuses mapped to one system status each, sets per category with inheritance, ordered, any later step or back (story 3.7) | Codes high; 3.7 is additive |
| A3 | Reopen disposed | New operation `asset_lifecycle.reopen`, Tenant Admin only, reason required (OQ-04 lean) | Low |
| A4 | Identifiers table | Not now; `tag` and `serial_number` are columns. Table with the first story that needs it | Low |
| A5 | Vendor link | No column now. 3.3 and 3.4 show OEM and O&M fields empty and disabled; 4.1 adds the columns and fills them | Low |
| A6 | Masking in 3.1 | Column grants and `asset_view` with masking now. Everyone who can view an asset sees its history, masked (3.4) | Medium |

## 10. Also in 3.1 (no decision needed)

- **Fiscal-year lock** (2.5 S3 handed it here): a trigger on `tenant` refuses a change of `fiscal_year_start_month` once the tenant has an asset (soft-deleted ones count).
- **Harness:** `tests.cross_tenant` takes one row for both tenants, but `asset.category_id` is not null and must be same-tenant. It gains an optional fourth argument with tenant B's overrides. Local seed only, never staging.

## 11. Build plan

Migrations, one purpose each:
1. `3_1_asset_operations`: `set_tag`, `reopen` operations, new starter grid, backfill.
2. `3_1_category_code`: `asset_category.code`.
3. `3_1_asset`: table, indexes, grants, policies, triggers (updated_at, soft delete, audit, tag, values, parent), tag counter, `tenant.asset_tag_pattern`, `set_asset_tag_pattern()`.
4. `3_1_asset_view`: `hidden_field_keys()`, `asset_view`.
5. `3_1_asset_status`: `change_asset_status()`.
6. `3_1_fiscal_year_lock`: tenant trigger.

## 12. Not in 3.1

UI (3.2 to 3.4), search helper and trigram index (3.2), transfer and history (3.5), asset history function (3.4), attachments and QR (3.6), tenant statuses (3.7), tag pattern and category code fields in the UI (3.8), vendors (4.1), scope (6.1), audit log masking (6.2), B14 depreciation columns, custody.

---

## 13. Story 3.2: Assets list, search, saved views

**Status:** done, 22 Oct 2026. Owner accepted every lean (S1a to S5a) on 22 Oct 2026. Built in the `3_2_*` migrations.

**Screen:** `Assets` in `assetly-screens.html`. Columns Tag, Name, Category, Location, Status. Filters: text box, Location, Category, Status (In Stock included, open-items change #5), Saved views. Count "Showing 1–50 of N", Previous and Next.

**Not built in 3.2:** Coverage filter and column, Next service column (no coverage or maintenance data until Goal 4 and Phase 2). Import Excel (Goal 8) and Export (no story yet) buttons. Add asset links to 3.3, so it shows once 3.3 lands. The list screen shows no masked column (purchase value is not on it); masked values show as "Hidden" on the 3.4 detail screen.

### 13.1 Why the list is a function, not PostgREST filters on `asset_view`

Probed on the local stack. PostgREST passes RPC arguments as statement parameters (GET: `fn(p := $1)`; POST: a `json_to_record` lateral). So a plain SQL function with `p_x is null or ...` keeps the OR in the plan, and the plan cache may reuse a generic plan. Three things break with that:

1. **Search** must drive from the trigram ids (spike F5). Behind `p_term is null or ...` it cannot, and a rare term walks the whole tenant (spike row 11, 276 ms).
2. **Keyset paging** with PostgREST is `or=(name.gt.X,and(name.eq.X,id.gt.Y))`, which cannot start the index scan at the cursor. A deep page reads every row before it, like offset (spike row 04).
3. **Location with descendants** needs the closure table, which is private.

### 13.2 Objects

| Object | Kind | What it does |
|---|---|---|
| `asset_search_trgm` | index | `gin (tenant_id, name gin_trgm_ops, tag gin_trgm_ops, serial_number gin_trgm_ops) where deleted_at is null`. Extensions `pg_trgm`, `btree_gin` in `extensions` (plain Postgres, portable) |
| `private.search_asset_ids(p_term)` | `security definer`, stable, `search_path = ''` | Ids only. Tenant, `asset_core.view`, `deleted_at is null`, then `name`, `tag` or `serial_number` `ilike '%term%'` (wildcards in the term escaped). 6.1 adds the scope clause here in set form |
| `private.location_subtree_ids(p_id)`, `private.category_subtree_ids(p_id)` | `security definer`, stable | The node and every descendant, current tenant only, as `uuid[]`. Location reads the closure; category walks `parent_id` |
| `public.list_assets(...)` | invoker, plpgsql | Reads **`asset_view`** (so masking, tenant and permission checks stay in one place). Builds the statement from typed arguments with `format('%L')` and runs it with `execute`, so each call is planned with its real values |
| `public.count_assets(...)` | invoker, plpgsql | Same filters, `count(*)` capped at 10,001 rows (S5) |

`list_assets(p_term, p_status, p_category_id, p_location_id, p_sort, p_after_value, p_after_id, p_limit)`:

- `p_term`: adds `v.id in (select private.search_asset_ids(p_term))`. Blank is no search.
- `p_status`: one system status, or null for all. Single choice, like the screen's chip.
- `p_category_id`, `p_location_id`: `= any (subtree ids)`, set form (spike §6).
- `p_sort`: `name` (default), `tag`, `updated` (newest first). Each has its index (§8). `id` breaks ties.
- Keyset: `p_after_value`, `p_after_id` from the last row of the page. `name`: `(v.name, v.id) > (value, id)`. `tag`: `v.tag > value` (unique). `updated`: `v.updated_at <= value and (v.updated_at < value or v.id > id)`. Previous keeps a stack of page cursors in the app.
- `p_limit`: 1 to 100, default 50. The app asks for 51 to know whether Next exists.

The functions are the read path for the list only. Detail (3.4) and the form (3.3) keep reading `asset_view` by id.

**As built:** the statements come from `private.asset_list_sql()` and `private.asset_search_sql()`, so the tests EXPLAIN exactly what runs. Two findings from those plans: the search pattern must be a literal (as a parameter the planner cannot cost the trigram index and reads the whole table), and the list takes the found ids in set form, `v.id = any ((select array(...))::uuid[])`, so it looks them up in `(tenant_id, id)` whatever the table statistics say. The search helper and both subtree helpers return nothing without `asset_core.view` in the token's tenant.

### 13.3 Saved views (new table)

```
saved_view: std columns, user_id uuid not null default auth.uid(), entity text check (entity = 'asset'),
            name text not null, filters jsonb not null check (jsonb_typeof(filters) = 'object'),
            sort text not null default 'name'
unique (tenant_id, user_id, entity, lower(name)) where deleted_at is null
filters: {"q": text, "status": text, "category_id": uuid, "location_id": uuid}
```

1.4 pattern: `set_updated_at`, `check_soft_delete`, `audit_row('data')`, select, insert and update policies with `tenant_can_write()` on writes, no delete grant, soft delete. Every policy also has `user_id = (select auth.uid())`. A filter that points to a deleted category or location is dropped when the view loads.

### 13.4 Owner decisions (22 Oct 2026): every lean accepted

| # | Question | Options | Lean | Cost to reverse |
|---|---|---|---|---|
| S1 | List and search shape | **a)** `list_assets()` and `count_assets()` as above, plpgsql with `execute`. **b)** One inlinable SQL function with PostgREST filters and `or=` keyset: less SQL, but the plans in 13.1 | a | Low: two functions and one call site in the app |
| S2 | Who sees a saved view | **a)** Only its owner. **b)** Owner, plus a "shared" flag that shows it to everyone in the tenant who can view assets | a. Shared later is one column and one policy change | Low |
| S3 | Table shape | **a)** One `saved_view` table with `entity` (assets now; vendors and others later reuse it). **b)** `asset_saved_view`. Stored: filters and sort. Not stored: columns (the screen has no column picker) | a | Medium once users have views (rename and copy) |
| S4 | Permission for own views | **a)** No new domain: anyone with `asset_core.view` keeps their own views (soft delete checks `asset_core.view` too). **b)** New domain `saved_view` with view, create, update, delete, added to the starter grid (new `seed_starter_groups` and backfill, as 3.1 did) | a. A personal view is a preference, not asset data | Low for a to b (add a domain, change policies) |
| S5 | Total count | **a)** Exact, capped: "10,000+" past 10,000 (spike: exact count of 200k is 84 to 146 ms). **b)** Exact always. **c)** PostgREST estimate | a | Low |

**No decision needed:** the trigram index and search helper follow spike F5 and §8. Hide "Ask Assetly" and the Intelligence nav group when the tenant has no live `ai_addon` row in `tenant_entitlement` (CLAUDE.md §11; `tenant_entitlement` is readable by members since 1.1). Status filter labels and tag colours: Active green, In Stock and Inactive grey, Under maintenance amber, Disposed red, from `tokens.css`.

---

## 14. Story 3.3: Add and edit asset form

**Status:** done, 22 Oct 2026 (owner accepted). No DECIDE item: 3.1 already fixed the write path and the hidden-value rules. 3.3 closes two gaps in them (14.2) and builds the form. Built in migration `3_3_asset_write_rules`.

**Screen:** `assetly-screens.html` has no Add or Edit asset screen. The form follows the 2.2 and 2.5 card style and the field order of the Asset detail Details card (tag, category, location, make and model, serial, purchase, criticality).

### 14.1 Write path (from 3.1, no choice left)

- **Direct writes on `asset`** under RLS, the column grants (§3) and the `check_asset_values` trigger (§4.1). No create or update action function. The app inserts with a client `id` (`crypto.randomUUID()`, in the insert grant), updates by `id`, and reads back through `asset_view`.
- **Status on create:** a two-choice select, Active (the table default, §1) or In Stock (the only insert statuses, §3). Later changes only through `change_asset_status` (3.5 builds the dialog). The edit form shows status read-only.
- **Location on edit:** read-only. `location_id` is not in the update grant; it changes through the 3.5 transfer.
- **Tag:** empty means generated on save (A1). The field is editable only with `asset_core.set_tag`; without it the form says "Generated on save" (create) or shows the tag read-only (edit).
- **Parent (OQ-07):** typed as the parent's tag and looked up in `asset_view` (`tag = upper(input)`, the tag index). A select of every asset does not scale. The trigger's cycle and depth errors show on the field.
- **Vendor (OQ-06, A5):** OEM vendor and O&M vendor show empty and disabled, with a note that vendors come in Goal 4. 4.1 adds the columns.

### 14.2 Hidden keys and columns on save (database guarantees)

| Case | Guarantee | Where |
|---|---|---|
| Custom key the user cannot view | Kept as stored, whatever the client sends | 3.1 trigger (§4.1.2) |
| Custom key the user can view, not update (read-only on the form) | Sent back unchanged, allowed. **Gap closed:** omitting it (removing the key) is now refused with 42501, like a change | `3_3_asset_write_rules` |
| `purchase_value`, `purchase_currency` | A plain update only writes the columns it names, so the form leaves them out when hidden. A change needs `asset_financials.update` (3.1). **Gap closed:** it now also needs `asset_financials.view`, so a user who cannot see the value cannot overwrite or blank it blind | `3_3_asset_write_rules` |
| Custom keys of fields that no longer apply after a category change | Kept, unchanged, not shown (§4.1.4, G4) | 3.1 trigger; the form keeps them in the payload |

The form never sends a key or column the user cannot view: it builds `custom_values` from the `asset_view` row (already masked) plus the edited visible fields.

### 14.3 Form rules

- **Fields shown:** the category line (G3: every-asset fields, then furthest ancestor first, by `sort_order`), active fields only. Hidden without the field domain's `view`; read-only without its `update` (or without `asset_core.update`/`create`).
- **Required markers:** name and category always. `field_definition.is_required` in the line, and `tenant.required_asset_fields`, minus fields the user cannot write (M2), minus `location` on edit (§4.1.6). The same rule the trigger applies, so the marker and the database agree.
- **Client checks** for fast feedback only: required, number, date, quantity ≥ 1, money ≥ 0. The database is the truth.
- **Error mapping:** one function maps the Postgres error to a field (`missing mandatory fields: a, b` to each field; `custom field X ...` to X; FK and check names to category, location, parent, quantity, tag) and an i18n message.
- **Money:** amount plus currency, currency defaulting to `tenant.currency_code`. Shown only with `asset_financials.view`, editable with `update`.

### 14.4 Open items used (lean)

OQ-01 (quantity, a number ≥ 1, no split), OQ-06 (no vendor picker until Goal 4, A5), OQ-07 (parent by tag, depth and cycle checked by the 3.1 trigger).

### 14.5 Not in 3.3

Detail page (3.4: the row link goes to the edit form until then), status change and transfer dialogs (3.5), tag pattern and category code fields (3.8), vendor columns (4.1), optimistic locking (two people editing the same asset: last save wins).

---

## 15. Story 3.4: Asset detail, Overview and Audit tabs

**Status:** in review, 22 Oct 2026. Owner chose H1 a) on 22 Oct 2026. Everything else follows A6, §4.2 and §5. Built in migration `3_4_asset_history`.

**Screen:** `Asset detail` in `assetly-screens.html`. Head: breadcrumb `Assets / <category>`, name, status tag; buttons QR label (3.6), Transfer and Retire (3.5), Edit (3.3 form, shown with `asset_core.update`). 3.4 shows Edit only; the status action belongs to the 3.5 Retire dialog. Tabs: Overview and Audit work; Coverage, Obligations, Service history, BOM and Attachments show disabled (later stories), so the tab bar matches the screen. The Coverage and Obligations cards are left out (no data until Goal 4 and Phase 2).

### 15.1 Overview (reads `asset_view` by id, §5)

Details card: tag, category path, location path, make and model, serial, purchase date and value ("Hidden" without `asset_financials.view`), in-service date, criticality, quantity, parent (link), children (links, `parent_asset_id = id`, by tag). OEM and O&M vendor empty and disabled (A5). Custom fields card: the category line (3.3 `lineFields`); a field whose domain the user cannot view shows "Hidden" (its value is not in the row). Status reason and date under the status when set.

### 15.2 `public.asset_history(p_asset_id, p_before, p_before_id, p_limit)`

| | |
|---|---|
| Kind | `security definer`, `stable`, SQL, `search_path = ''`, in `public` (a read action; it reads `audit_log` without `audit_log.view`, A6) |
| Checks | Current tenant, `asset_core.view`, and the asset exists in the tenant (soft-deleted included, as the base select policy). Otherwise no rows, like `asset_view`. 6.1 adds its set-form scope clause to that `exists` |
| Rows | `audit_log` where `tenant_id`, `table_name = 'asset'`, `record_id = p_asset_id`. Index `audit_log_record_idx` |
| Returns | `id, occurred_at, action, actor_type, actor_name, old_data, new_data, hidden_fields text[]` |
| Masking | Same rules as `asset_view`: without `asset_financials.view`, `purchase_value` and `purchase_currency` are removed from `old_data` and `new_data`; `custom_values` loses `private.hidden_field_keys('asset')` in both. `hidden_fields` names what was removed **and changed** in that row (`purchase_value`, `purchase_currency`, `custom.<key>`), so the tab can say "Purchase value: hidden" instead of dropping the change |
| Paging | Keyset, newest first: `(occurred_at, id) < (p_before, p_before_id)`. `p_limit` 1 to 100, default 50; the app asks for 51 |

- **Order inside a transaction:** `audit_log.occurred_at` defaults to `now()`, the transaction start, so a create and an update in one transaction tie and come back in random order. The migration changes the default to `clock_timestamp()` (the time the row was written). `transaction_id` still groups a transaction. Old rows keep their values.
- **Readable changes (app):** one line per changed field, `Label: old → new`. Ids show as category or location names and parent tags; statuses use the status labels; custom keys use their field label. System columns (`id`, `tenant_id`, `created_*`, `updated_*`, `status_changed_at`) are not shown. A row whose `new_data` has `status` is titled "Status changed" (with the reason); `insert` "Created" (the values set); `soft_delete` "Deleted"; else "Updated". UI only, no schema.
- **Not here:** audit log screen masking (6.2), transfer rows (3.5 writes them; they will read as a location change).

### 15.3 DECIDE

| # | Question | Options | Lean | Cost to reverse |
|---|---|---|---|---|
| H1 (chose a) | Who shows as the actor (1.11, co-tenant profile read, is parked) | **a)** The actor's `display_name` when the actor is an active member of the current tenant (the same rule 1.11 plans for `user_profile`), "Former member" otherwise, "System" for system rows. Read inside `asset_history` only, name only, no email. **b)** "You" for own rows, "Another user" for others, "System"; names come with 1.11. **c)** Build 1.11 first | a. An audit tab without names is weak for the demo, and (a) shows no more than 1.11 will | Low: one function body; no data or schema |

### 15.4 Open items used (lean)

OQ-07 (children listed one level down, no cascade), A5 (vendor fields empty and disabled).
