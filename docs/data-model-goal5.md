# Goal 5 data model: obligations (story 5.1)

**Status:** in review, 28 Oct 2026. The owner accepted every lean, O1 to O9, on 28 Oct 2026. So 5.1 is the database part plus the Settings field and the Term prefill (O9 a); the category form defaults and the asset Obligations tab are story 5.1b. Built in migrations `5_1_obligation`, `5_1_obligation_state`, `5_1_category_defaults`; tests in `5_1_obligations.test.sql` (110).

**As built (differences from the design below):**
- Obligation names are unique per asset among live rows, case-insensitive (`obligation_name_uq`). A copy cannot duplicate a row.
- The job index is `(tenant_id, due_state_until)`, as 4.4's.
- The obligation refresh trigger stops on an empty set. A statement trigger fires for zero rows, so without that check the refresh's own update would fire it again without end.
- `update_tenant_settings` no longer writes the two refresh cursors (`coverage_refresh_after`, `obligation_refresh_after`) into the settings audit row. They are the job's state, not settings.
- Asset status changes and soft deletes refresh the asset's obligations through a row trigger with a `when` guard, so the 4.4 coverage refresh (which writes only the coverage columns) does not fire it.

**Goal (F11):** recurring obligations per asset (service, calibration, inspection, certificate) with a next-due date, a stored state (scheduled, due soon, overdue) kept right by `pg_cron`, and category defaults that new assets copy. The same default mechanism gives a default warranty term per category, which prefills the 4.5 Warranty block.

**Owner decisions already made (27 Oct 2026), not reopened here:**
1. OQ-03 decided: both anchors per rule. New rules default to "from last completion". Statutory types (inspection, calibration) default to "fixed dates".
2. Category defaults with asset override, for service intervals **and** warranty term. One mechanism. The warranty default prefills the 4.5 block.
3. Due soon is a tenant setting, like `coverage_expiring_days`.
4. State is stored and kept right by `pg_cron`, following 4.4 (`refresh_coverage_state`, delta job, settings queue).
5. Service cost (5.2): money with currency, own domain, masked like contract value. 5.1 only leaves room.
6. A Technician completes through `complete_obligation` (5.2), not open table writes.
7. Attachments (5.2): the 3.6 pattern with a second entity.
8. Outbox events `obligation.due_soon`, `obligation.overdue` now. Alerts are Goal 9.
9. BOM parked: BL-2.

**Reads with:** [data-model-goal3.md](data-model-goal3.md) §3 (system statuses), §14 (write path, column grants), §18.2 (3.7 per-category set, nearest parent); [data-model-goal2.md](data-model-goal2.md) §1.1 (category tree), §5 (settings, `update_tenant_settings`); [data-model-goal4.md](data-model-goal4.md) §27 to §32 (4.5), §35 to §36 (4.4 stored state, job, queue); spike 1.7 §6.

**Open items used:** OQ-03 (decided, decision 1). OQ-04 (Disposed is terminal, admin reopen) shapes §5 paused state.

**Screens:** Maintenance (tabs Overdue, Due soon, Scheduled, Completed; tiles Overdue, Next 7 days, Next 30 days, Out of coverage; columns Asset, Obligation, Location, Due, Status, Coverage), Dashboard ("Due in 30 days", "Overdue service", upcoming list), Asset detail (Obligations tab and card: "Quarterly service · Overdue", "Record completion"). So an obligation has a free **name** ("Quarterly service", "Statutory inspection") besides its type.

## 1. `obligation` (public, 1.4 RLS pattern, domain `obligation`)

| Column | Type | Notes |
|---|---|---|
| id, tenant_id, std | | Standard columns, `unique (tenant_id, id)` |
| asset_id | uuid not null | `(tenant_id, asset_id) references asset (tenant_id, id)` |
| name | text not null | 1 to 80 chars. What the screens show |
| obligation_type | text not null | [O1] `check in ('service', 'calibration', 'inspection', 'certificate')` |
| interval_count | smallint not null | `check between 1 and 999` |
| interval_unit | text not null | `check in ('day', 'week', 'month', 'year')` |
| anchor | text not null | `check in ('completion', 'fixed')`. Default by type (decision 1): `fixed` for inspection, calibration and certificate; `completion` for service. Set by the form or the copy, not a column default |
| first_due_date | date not null | The first due date. For `fixed`, every due date is `first_due_date + k × interval` (k ≥ 0) |
| last_done_date | date null | Insert grant only (history from before Assetly). After that only `complete_obligation` (5.2) moves it |
| next_due_date | date not null | Derived by trigger (§3). No user grant |
| due_state | text not null default `'scheduled'` | `check in ('scheduled', 'due_soon', 'overdue', 'paused')`. System only (§5) |
| due_state_until | date null | First tenant date on which the calendar alone can change the state. Null for overdue and paused |
| is_active | boolean not null default true | Pause or end an obligation. Inactive = `paused` |
| notes | text null | Instructions ("check belt tension"). Max 2,000 |

- **Hook for meter rules later (no build):** the rule is already structured (count + unit + anchor). A later `basis text not null default 'calendar'` plus `meter_id` and units such as `hour` widen two checks. Nothing in 5.1 depends on calendar being the only basis except `next_due_date not null`, which a meter rule can keep as its forecast date.
- **Room for 5.2:** `service_record` (its own table, domain `service_record`) holds date, notes, cost and attachments and points to the obligation. Cost lives there, behind a new field domain `service_values` (view, update), masked in a view like `coverage_values`. Nothing on `obligation` needs to change.
- **Grants:** insert: `asset_id, name, obligation_type, interval_count, interval_unit, anchor, first_due_date, last_done_date, is_active, notes` (plus id, tenant_id). Update: the same minus `asset_id` and `last_done_date`, plus `deleted_at`. `next_due_date`, `due_state`, `due_state_until` have no grant.
- **Triggers:** `set_updated_at`, `audit_row('data')` and the 4.4 guard so a state refresh writes no audit row and no outbox `obligation.updated` (`to_jsonb(old) - '{due_state,due_state_until}'`); `check_soft_delete('obligation', 'update')` [O7]; `set_obligation_next_due` (before insert or update of the rule columns, §3); statement-level after insert/update calls `refresh_obligation_state` (§5).
- **Policies (1.4):** select tenant + `obligation.view`; insert `obligation.create`; update `obligation.update`; both with `tenant_can_write()`. No delete policy. `tests.cross_tenant('public.obligation', 'obligation', ...)`. Row scope by location is 6.1.
- **Indexes** (partial `where deleted_at is null`, tenant first):
  - `(tenant_id, due_state, next_due_date, id)`: Maintenance tabs, sorted by due; Dashboard counts.
  - `(tenant_id, asset_id)`: asset detail.
  - `(due_state_until) where due_state_until is not null`: the job.

## 2. Category defaults (one mechanism for obligations and warranty) [O2] [O3]

Same shape as 3.7 `status_ids`: columns on `asset_category`, null = inherit from the nearest parent.

| Column | Type | Notes |
|---|---|---|
| `default_obligations` | jsonb null | Null = inherit. `[]` = none (stops inheritance). Array of `{name, obligation_type, interval_count, interval_unit, anchor}` |
| `default_warranty_months` | smallint null | Null = inherit. 0 = none. Else one of the 4.5 W2 terms (3, 6, 12, 18, 24, 36, 48, 60), so the Term select can show it |

- **Checks:** a trigger on `asset_category` when either column changes: array of objects, only those keys, same checks as the `obligation` columns, names unique in the array, at most 20 entries.
- **Write and audit:** the existing category update (`category_config.manage`, `tenant_can_write()`) and category audit trigger. No new table, policy or cross-tenant test.
- **Inheritance:** `private.category_defaults(p_tenant_id, p_category_id)` walks up `parent_id` (as `effective_status_ids`) and returns the first non-null of **each** column separately. So "Rotating equipment" can hold the warranty term and "Pumps" its own obligations. Nothing up the tree: no obligations, no warranty term.
- **Read for the app:** `public.category_defaults(p_category_id) returns table (default_obligations jsonb, default_warranty_months smallint, obligations_from uuid, warranty_from uuid)`. The `_from` ids let the category form show "Inherited from Rotating equipment". Readable with `asset_core.create` or `category_config.view`.

### How the asset gets them, and override [O3] [O4]

- **Copy on asset insert.** An after-insert trigger on `asset` (`security definer`, fixed `search_path`) inserts one `obligation` per effective default. Every writer gets it: the form, `create_asset_with_warranty`, imports (Goal 8). After that the asset **owns** its rows: override means editing or deactivating the asset's own row, or adding one.
- **Why definer:** the category decided the defaults. A user who may create an asset but lacks `obligation.create` still gets the rows, and cannot edit them.
- **First due date of a copied rule [O4]:** base = `in_service_date`, else `purchase_date`, else tenant today. First due = the first `base + k × interval` (k ≥ 1) that is on or after tenant today. So an old asset added today is not overdue on day one for history nobody recorded.
- **Category default changed later:** existing assets are not touched. A "apply to existing assets" bulk action is a later idea, not 5.1.
- **Asset changes category:** its obligations stay as they are (it owns them). No add, no remove.
- **Warranty:** no copy. On Add asset, when the category changes and the user has not picked a term by hand, the 4.5 block's Term is set to `default_warranty_months` (End recomputed by W1). The block stays closed until the user opens it (coverage needs a vendor, so opening it could block a save). The asset's override is its warranty coverage row, as in 4.5. Nothing stored.

## 3. Next-due math (`private.obligation_next_due`, immutable, pure)

`obligation_next_due(anchor, interval_count, interval_unit, first_due_date, last_done_date, current_due date, done_on date)`. 5.1 uses it with `done_on = null`; 5.2's `complete_obligation` uses it with the completion date. Tested fully in 5.1.

- **Step:** `interval_count` units as a Postgres interval (`make_interval`). Months and years clamp to month end: 31 Jan + 1 month = 28 Feb (29 in a leap year).
- **No drift:** fixed dates are always `first_due_date + k × step`, never the previous due + step. So 31 Jan monthly gives 28 Feb, 31 Mar, 30 Apr, not 28 Feb, 28 Mar.
- **On insert or rule change** (`done_on` null):
  - no `last_done_date`: `first_due_date`;
  - `completion`: `last_done_date + step`;
  - `fixed`: the first slot after `last_done_date`.
- **On completion** (5.2, `done_on = D`) [O5]:
  - `completion`: `D + step`, early or late. Quarterly due 31 Mar, done 15 Apr → 15 Jul; done 17 Mar → 17 Jun.
  - `fixed`: the first slot after `greatest(D, current_due)`. Done early (17 Mar, due 31 Mar) → 30 Jun. Done late (15 Apr) → 30 Jun. Missed several (due 31 Mar, done 10 Sep) → 30 Sep: one completion clears the backlog; missed periods stay visible as overdue time in history.
- **Time zone:** due dates are calendar dates (`date`, like coverage). "Today" is `now() at time zone tenant.time_zone`, as `tenant_today()`.
- A rule edit (count, unit, anchor, first due) recomputes `next_due_date` by the "insert" rule. The audit row shows it.

## 4. Due soon setting

- `tenant.obligation_due_soon_days smallint not null default 30 check between 1 and 365`. 30 matches "Next 30 days" and "Due in 30 days" on the screens. The 7-day tile is a query, not a state.
- `update_tenant_settings` gains `p_obligation_due_soon_days smallint default null` (last, optional), dropped and recreated as 4.2 did. The Settings page gets one number field.
- **Queue on change:** a before-update trigger on `tenant` sets `obligation_refresh_after = '000…0'` when `obligation_due_soon_days` or `time_zone` changes (the 4.4 cursor, C15 as built). The job walks that tenant's obligations by id.

## 5. Stored state and the job [O6] [O8]

- **State**, in the tenant zone, N = `obligation_due_soon_days`:
  - `paused`: obligation inactive, or the asset's system status is `inactive` or `disposed` [O6];
  - `overdue`: `next_due_date < today` (due today is not overdue yet);
  - `due_soon`: `next_due_date <= today + N`;
  - else `scheduled`.
- **Until:** scheduled → `next_due_date - N`; due soon → `next_due_date + 1`; overdue, paused → null.
- **`private.refresh_obligation_state(p_ids uuid[], p_now timestamptz default now())`:** definer, set-wise, writes only rows whose state or until changes (the 4.4 shape). In the same statement it writes one outbox event per row that **enters** `due_soon` or `overdue`: `obligation.due_soon` / `obligation.overdue`, payload `{asset_id, name, next_due_date, from, to}`. A run that changes nothing writes nothing, so each change gives one event.
- **Event side (same transaction):** statement triggers on `obligation` insert and update; a row trigger on `asset` `after update of status, deleted_at` (when changed) refreshes that asset's obligations, so Retire pauses them and a reopen brings them back (overdue if the date passed; honest, and the event fires).
- **Calendar side:** `private.refresh_due_obligation_states(p_now, p_batch 10000, p_budget '4 minutes')`, the 4.4 loop: per tenant, rows whose `due_state_until <= today`, then a queued full refresh from the cursor. New `pg_cron` entry `assetly_obligation_state`, every 15 minutes [O8].
- **Backfill:** none needed (the table is new and empty).
- **BL-1:** this adds a second `pg_cron` job. BL-1's `job_run` log must cover both.

## 6. Permissions

- Domains exist (1.2 seed): `obligation` (view, create, update, complete), `service_record` (view, create, update, complete). Starter grid (1.6, kept by 3.1 and 3.6): Tenant Admin, Plant Manager, Planner everything; Technician `obligation` view, complete and `service_record` all; Auditor view. **No catalog or grid change in 5.1.**
- `complete` is used by 5.2 only. Defaults on the category: `category_config.manage`.
- `service_values` (5.2) is a new field domain seeded in 5.2.

## 7. UI (in the split, §9 O9)

- **Category form:** "Default warranty term" (Inherit · None · 3 … 60 months, with "Inherited from X") and "Default obligations" (Inherit, or own list: name, type, every N unit, anchor; type picks the default anchor).
- **Asset detail:** Obligations tab (the screens have it): list with name, rule ("Every 3 months · from last completion"), next due, state tag (overdue error, due soon warn, scheduled ok, paused neutral); add, edit, deactivate with `obligation.create`/`update`. "Record completion" is 5.2. The Overview card lists them as in the screens.
- **Add asset:** Term prefill (§2).
- **Settings:** due soon days.
- i18n, responsive, web tests.

## 8. Tests planned

- `obligation_next_due`: both anchors; late, early, missed periods; 31 Jan monthly, 29 Feb yearly; weeks and days; rule edit.
- State: each state at its boundary (due today, due tomorrow, today + N, today + N + 1); paused by inactive and by asset Disposed and Inactive; reopen; flips at the tenant midnight in two time zones; one event per entry, none on a no-change run.
- Job: nothing due does nothing; batch and budget; due-soon change and time-zone change queue the tenant and the job clears the cursor.
- Defaults: own, parent, grandparent, `[]` stops, each column inherited separately; check trigger refusals; copy on insert (definer, user without `obligation.create`); first due for an old asset; category change keeps rows; warranty default via `category_defaults`.
- Write rules: no grant on `next_due_date`, state, until; `last_done_date` insert only; state refresh writes no audit row.
- Permission steps (none, view, create, update, read-only tenant), `tests.cross_tenant`, EXPLAIN for the Maintenance tab query and the job query on the state indexes, tenancy guard green.

## 9. DECIDE

| # | Question | Options | Lean | Cost to reverse |
|---|---|---|---|---|
| O1 | Obligation type | **a)** 4 system codes (check), free `name` for the label. **b)** Tenant table mapped to the 4 codes (the 3.7 pattern) | a. The type drives the default anchor and later reports; the tenant's own words go in `name`. b is a table, policies and a screen for little gain. Note CLAUDE.md §8 says types are data: this is a fixed system list like asset status | Medium: b later is a table plus a backfill from the codes |
| O2 | Where category defaults live | **a)** `asset_category.default_obligations jsonb` and `default_warranty_months`, null = inherit (§2). **b)** Table `category_obligation_default` (1.4 pattern) plus the warranty column | a. Same as 3.7 `status_ids`: no table, policy or cross-tenant test; category audit covers it; tens of bytes per category | Low to medium: b later copies the arrays into rows |
| O3 | Override | **a)** Copy on asset insert by trigger; the asset owns its rows. **b)** Live link: asset reads category rules, stores per-field overrides | a. Each asset needs its own last done and next due anyway; b needs override flags per field and rules for every category edit | High once assets have rows: b later means re-linking every obligation |
| O4 | First due of a copied rule | **a)** First `base + k × interval` on or after today (base: in-service, purchase, today). **b)** `base + 1 interval`, even if in the past | a. b makes every old asset overdue on day one (imports in Goal 8) | Low: trigger body |
| O5 | Fixed anchor, completion | **a)** First slot after `greatest(done date, current due)`: early clears this period, late or missed clears all. **b)** One completion clears one period; backlog stays overdue | a. One machine serviced today is serviced; b keeps it overdue after the work | Low: function body (5.2 calls it) |
| O6 | Paused by asset status | **a)** Asset `inactive` or `disposed`, or obligation inactive. **b)** Also `in_stock`. **c)** Only obligation inactive (the user pauses by hand) | a. A spare in store still needs calibration or a certificate; a retired asset needs nothing. Derived, so a reopen restores it with no data change | Low: one `case` |
| O7 | Remove an obligation | **a)** Soft delete with `obligation.update` (no catalog change). **b)** Add a `delete` operation to `obligation` and the grid | a. Same groups get both today; deactivate covers pausing. b is a seed row and a grid change if the owner wants them apart | Low |
| O8 | Cron | **a)** Own job `assetly_obligation_state`, every 15 minutes, same loop as 4.4. **b)** One job calling both refreshes | a. Each has its own budget and failure; BL-1 logs them apart | None |
| O9 | Split | **a)** 5.1 database (§1 to §6), pgTAP, types, settings field and the 4.5 Term prefill; **5.1b** category form defaults and the asset Obligations tab. **b)** All in one PR | a. 3.7 and 4.1 precedent: the owner-review parts (RLS, two definer functions, the cron job) stay in a small PR. Until 5.1b, defaults and obligations are added by SQL (the demo note gives it) | None |

## 10. Build plan (after answers)

Migrations, one purpose each:
1. `5_1_obligation`: table, grants, triggers, policies, indexes, `obligation_next_due`, `set_obligation_next_due`.
2. `5_1_obligation_state`: `tenant.obligation_due_soon_days` and cursor, queue trigger, `refresh_obligation_state`, `refresh_due_obligation_states`, the obligation and asset triggers, events, cron entry, `update_tenant_settings` with the new argument.
3. `5_1_category_defaults`: the two category columns, check trigger, `category_defaults` (private and public), the asset insert copy trigger.

pgTAP `5_1_obligations.test.sql` (§8). Types regenerated. Web: Settings field, Term prefill, and (if O9 b) the §7 screens.

## 11. Not in 5.1

Completion and service records (5.2), Maintenance screen (5.3), Dashboard (5.4), meter-based rules, bulk "apply category defaults to existing assets", notifications (Goal 9), BOM (BL-2).

---

## 12. Story 5.2: Service completion record

**Status:** in review, 28 Oct 2026. The owner accepted every lean, S0 to S9, on 28 Oct 2026. 5.2 builds §12.1 to §12.5 and §12.7; attachments (§12.6) are story 5.2b. Built in migrations `5_2_service_values_domain`, `5_2_service_record`, `5_2_complete_obligation`; tests in `5_2_service_record.test.sql` (91), web `Service.tsx`.

**As built (differences from the design below):**
- **Undo works on any live record**, not only the latest advanced one. Both actions keep one invariant: `last_done_date` = the later of the baseline (the value before any record) and the latest live record's `done_on`. So undoing an older record changes nothing, undoing the latest puts the right date back, and no "undo the later one first" refusal is needed. Still no replay (S4 a, not b).
- The baseline is the least `prev_last_done_date` over the obligation's records (null if any is null), not "the first record by `created_at`": two completions in one transaction share `created_at`.
- `service_record_view` masks cost only. `service_history` (invoker) adds the obligation name, `done_by_name` (`member_name`) and `vendor_name`, so the vendor name shows only with `vendor_core.view`.
- The `service_record` audit row and its outbox event carry the whole row, cost included, as every audited table does (coverage contract value too). Only `obligation.completed` and `obligation.completion_undone` are cost-free by design.
- A correction sends only the fields the form shows, so a user without the vendor list or cost rights never clears those values.
- Record completion is a per-row button on the Obligations tab (not on paused rows); the Overview card's button opens that tab.

**Owner decisions already made (27 to 28 Oct 2026), not reopened:** cost behind its own field domain, masked like `coverage_values`; a Technician completes through `complete_obligation`, never open table writes; attachments reuse the 3.6 pattern with a second entity; outbox events now, alerts in Goal 9.

**Owner review (CLAUDE.md §9):** `complete_obligation` and `undo_completion` (definer), the `service_record` RLS, the `service_record_view` masking, the `service_values` grid seed, and (5.2b) the storage policy change.

**Screens:** Asset detail has a **Service history** tab (disabled today) and "Record completion" on the Obligations card. Maintenance has "Record completion" and a Completed tab (5.3). No dialog layout: the dialog follows the 4.3 coverage form style.

### 12.1 `service_record` (public, 1.4 pattern, domain `service_record`, 1.2 seed)

| Column | Type | Notes |
|---|---|---|
| id, tenant_id, std | | Standard, `unique (tenant_id, id)`, soft delete |
| obligation_id | uuid not null | `(tenant_id, obligation_id) → obligation` |
| asset_id | uuid not null | `(tenant_id, asset_id) → asset`. Copied from the obligation by the action, so history per asset needs no join |
| done_on | date not null | [S3] Not after tenant today; at most 366 days back |
| done_by_user_id | uuid null | [S1] Default the caller. Must be an active member of the tenant |
| vendor_id | uuid null | [S1] Contractor (4.1 vendor, same tenant, active). `(tenant_id, vendor_id) → vendor` |
| outcome | text null | [S6] `check in ('pass', 'fail')`. Null = not an inspection result |
| certificate_expiry | date null | [S7] Optional, any type. Shown in history |
| notes | text null | Max 2,000 |
| cost_amount | numeric(19,4) null | `>= 0`. Domain `service_values`, masked [S8] |
| cost_currency | char(3) null | ISO 4217 shape. Default tenant `currency_code` when an amount is given. `check (cost_amount is null or cost_currency is not null)` |
| prev_last_done_date | date null | [S4] What `last_done_date` was before this record moved it. System only |
| advanced | boolean not null | [S2] True when this record moved the obligation's dates. System only |

- **No insert grant.** Rows come only from `complete_obligation`. Update grant: `done_by_user_id, vendor_id, outcome, certificate_expiry, notes, cost_amount, cost_currency, updated_by` (correction, [S4]). `done_on`, `obligation_id`, `asset_id`, `prev_*`, `advanced`, `deleted_at`: no grant (undo is the action).
- **Select grant:** every column except `cost_amount, cost_currency` (as `coverage`). Reads with cost go through the view.
- **Triggers:** `set_updated_at`, `audit_row('data')`, `check_service_record()` (vendor live and same tenant, user active member, a change of cost needs `service_values.update`: the 4.2 `check_coverage` rule).
- **Policies:** select tenant + `service_record.view`; update tenant + `service_record.update` + `tenant_can_write()`; no insert, no delete policy (`revoke delete, truncate`). `tests.cross_tenant('public.service_record', ...)` (its insert step expects 42501, which the missing grant gives).
- **`public.service_record_view`** (owner-run, like `coverage_view`): live rows, `cost_amount` and `cost_currency` as `case when (select private.has_permission('service_values', 'view')) then ... end`, plus `done_by_name` via `private.member_name()` and `vendor_name`.
- **Indexes** (partial live, tenant first): `(tenant_id, asset_id, done_on desc, id)` for the tab; `(tenant_id, obligation_id, done_on desc, id)` for undo's "latest" lookup.
- 6.1: one scope clause on `asset_id`, as `asset_attachment`.

### 12.2 Domain `service_values` (new, as data)

`security_domain ('service_values', 'service', 'field', 'Service costs')` `on conflict do nothing`, operations `view`, `update`. Grid [S8]: new `seed_starter_groups` plus backfill for existing tenants (as 3.1 and 3.6 did); the 1.6 grid test gets the cells.

### 12.3 `public.complete_obligation(p_obligation_id, p_done_on, p_notes, p_cost, p_currency, p_outcome, p_vendor_id, p_done_by, p_certificate_expiry) returns uuid`

Definer, `set search_path = ''`, every name schema-qualified. Returns the new record id.

1. **Checks:** obligation in `current_tenant_id()`, live; `has_permission('obligation', 'complete')` [S5]; `tenant_can_write()`; `select ... for update` on the obligation (two people finishing at once queue; the second sees the first's dates). Refused when paused: obligation inactive, or the asset's system status `inactive` or `disposed` (the §5 rule read directly, not from `due_state`). `p_done_on` per S3. `p_cost` not null needs `service_values.update`, else refused (never silently dropped).
2. **Insert** the record (`asset_id` from the obligation, `cost_currency` default tenant currency, `done_by_user_id` default `auth.uid()`).
3. **Advance [S2]:** if `last_done_date is null or p_done_on >= last_done_date`: record gets `prev_last_done_date = last_done_date`, `advanced = true`; obligation gets `last_done_date = p_done_on`, `next_due_date = obligation_next_due(anchor, count, unit, first_due, last_done, next_due_date, p_done_on)` (O5). Else (back-dated before a later completion): history only, `advanced = false`, dates unchanged.
4. **State in the same transaction:** the 5.1 statement trigger on `obligation` update already calls `refresh_obligation_state`, so the stored state is right before the call returns. No wait for cron.
5. **Events, same transaction:** the audit triggers write the `service_record` insert and the `obligation` update audit rows and their outbox rows, as today. Plus one `obligation.completed` outbox event, payload `{asset_id, service_record_id, done_on, outcome, next_due_date, advanced}`. Cost is never in a payload.

The action runs as owner, so the 5.1 column grants (`next_due_date` none, `last_done_date` insert only) stay as they are.

### 12.4 Undo and correction [S4]

- **Correct** (wrong note, cost, vendor, outcome): plain update of the record, `service_record.update` (+ `service_values.update` for cost). Audited. Dates do not move.
- **Wrong date or wrong obligation:** undo, then record again.
- **`public.undo_completion(p_service_record_id)`** (definer; `service_record.update`, `tenant_can_write()`, locks the obligation): soft-deletes the record. If it was `advanced`, it must be the latest live advanced record of that obligation (else refused: undo the later one first); then `last_done_date = prev_last_done_date` and `next_due_date` recomputed by the insert rule (`done_on` null), which also respects a rule edit made after the completion. Writes `obligation.completion_undone`. A non-advanced (back-dated) record is only soft-deleted.

### 12.5 Reads

- **`public.service_history(p_asset_id uuid, p_obligation_id uuid default null)`**: invoker, reads `service_record_view`, newest `done_on` first, with the obligation name. No paging: an asset has tens of records over years. EXPLAIN test on `(tenant_id, asset_id, done_on desc)`.
- **5.3 Completed bucket:** tenant-wide, needs keyset paging and its own index. Designed in 5.3, not here.

### 12.6 Attachments (5.2b if S0 a) [S9]

- Path `<tenant>/service_record/<service_record_id>/<attachment_id>`. Same bucket, limits, 60 s signed URL, object first then row (Z6).
- New table `service_record_attachment` (copy of `asset_attachment` with `service_record_id`). Permissions: view `service_record.view`, upload `service_record.create`, remove `service_record.update`. No new domain.
- Storage: `can_upload_attachment` gets a second branch for `/service_record/` (live record in the tenant, `service_record.create`); `attachments_select` gets a second `exists` on `service_record_attachment`. `create or replace` in a new migration; the 3.6 one stays frozen. Tests on both entities: cross-tenant path, no permission, soft-deleted row, orphan, no update or delete; the asset branch still works.

### 12.7 UI (5.2)

- **Record completion dialog** (Obligations tab row action and the Overview card button, with `obligation.complete`; hidden on paused rows): done date (default tenant today, max today), outcome (inspection, calibration, certificate), done by me or contractor (vendor picker), certificate expiry (certificate type), notes, cost and currency (only with `service_values.update`). After save the row shows the new next due and state.
- **Service history tab** (enable the disabled tab, `service_record.view`): date, obligation, outcome, done by or vendor, cost (only with `service_values.view`), notes. Edit and Undo (confirm) with `service_record.update`.
- Obligations tab row: "Last done".
- i18n, responsive, web tests (gating, masked cost, dialog defaults, undo confirm).

### 12.8 Tests planned (`5_2_service_record.test.sql`)

Permission steps (none, `obligation.view` only, `complete`, `service_record.update`, read-only tenant); `tests.cross_tenant('public.service_record', ...)`; no insert grant, no `done_on` update. Next due: completion anchor early, on time, late; fixed early, on time, late, missed several; back-dated before the latest (no move); undo latest (both anchors, prior null and set), undo not-latest refused, undo after a rule edit. State refreshed in the same call (overdue to scheduled); one `obligation.completed` per call, none on a refused call. Cost masked without `service_values.view`, refused without `service_values.update`. Paused, inactive asset, Disposed, deleted obligation, future date, more than 366 days back refused. Vendor of another tenant or inactive refused. EXPLAIN `service_history`. Tenancy guard green. Grid cells for `service_values`.

### 12.9 DECIDE

| # | Question | Options | Lean | Cost to reverse |
|---|---|---|---|---|
| S0 | Split | **a)** 5.2: domain, table, view, two actions, dialog, Service history tab. **5.2b:** attachments (storage policy change, table, upload). **b)** All in one | a. Storage policies are owner review on their own (3.6 / 3.6b precedent); 5.2 alone is a full PR | None |
| S1 | Done by | **a)** `done_by_user_id` (default me) plus optional `vendor_id` for contractor work. **b)** User only. **c)** Free text | a. AMC work is done by the vendor; reports by vendor for free. c cannot be reported | Medium once data exists |
| S2 | Back-dated, out of order | **a)** Latest `done_on` wins: an older record is history only. **b)** Recompute from all live records each time | a. Same answer for the normal case, one row read; b replays O5 over history | Low (function body) |
| S3 | Date limits | **a)** Not after today; at most 366 days back (catches a wrong year); older history via import (Goal 8). **b)** No lower limit. Fiscal-year lock: none in Phase 1 (3.1 locks only the fiscal year **start**; no period close exists) | a | Low (one check) |
| S4 | Undo and correct | **a)** Correct by update; undo by action, latest advanced only, restores `prev_last_done_date`, recomputes. **b)** Undo any record, recompute from the rest. **c)** No undo, a correcting record only | a. Exact, small, audited. c leaves wrong next dues | Medium: b needs a replay |
| S5 | Permission to complete | **a)** `obligation.complete` only (the action's domain, §7.8). **b)** Also `service_record.create` | a. One gate per action; the grid gives both to the same groups, so nobody changes. `service_record.complete` stays unused | Low |
| S6 | Outcome | **a)** `pass`, `fail` or null; fail still advances (follow-up is Phase 2 incidents). **b)** Fail does not advance | a. A failed inspection still happened; b hides the real date | Low |
| S7 | Certificate expiry | **a)** Stored and shown only. **b)** When given, sets `next_due_date` (overrides the rule) | a. One math path (O5). b later is one branch in the action | Low |
| S8 | `service_values` grid | **a)** Tenant Admin, Plant Manager, Planner view + update; Technician none; Auditor view. **b)** Like `coverage_values` (Admin updates, Plant Manager views, Planner none) | a. Planners enter service invoices; Technicians do the work, not the money. Starter seed: owner review | Low (seed + backfill) |
| S9 | Attachment table (5.2b) | **a)** New `service_record_attachment`. **b)** Generalise `asset_attachment` with an entity column | a. 3.6 is frozen on staging; its generated path and policies stay; b rewrites both | Medium |

### 12.10 Build plan (after answers)

1. `5_2_service_values_domain`: domain row, operations, `seed_starter_groups` plus backfill.
2. `5_2_service_record`: table, grants, triggers, policies, indexes, `service_record_view`, `service_history`.
3. `5_2_complete_obligation`: `complete_obligation`, `undo_completion`.

pgTAP `5_2_service_record.test.sql`. Types. Web: dialog, Service history tab, "Last done".

### 12.11 Not in 5.2

Attachments (5.2b if S0 a), Maintenance screen and its Completed bucket (5.3), certificate expiry driving the due date (S7 b), failed-outcome follow-up (Phase 2), alerts (Goal 9).
