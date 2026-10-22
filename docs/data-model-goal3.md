# Goal 3 data model: asset (story 3.1)

**Status:** in review, 22 Oct 2026. Owner answered A1 to A6 on 22 Oct 2026 (section 9). Built in the `3_1_*` migrations.

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
