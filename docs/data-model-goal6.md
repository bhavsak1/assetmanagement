# Goal 6 data model: scope profiles and row scope (story 6.1), restricted fields (story 6.2)

**Status:** done, accepted by the owner 1 Nov 2026 (PR #49). The owner accepted every lean, S1 to S9, on 1 Nov 2026. Built in migrations `6_1_scope_profile`, `6_1_scope_helpers`, `6_1_scope_enforcement`; tests in `6_1_scope.test.sql` (66); bench in `scripts/spike-6-1/bench.sql`.

**As built (differences from the design below):**
- **S3 fell back for the asset table, as §8 allowed.** The id set alone missed the list target (one site: 156 / 181 ms; two profiles: 221 / 258 ms). The asset table (`asset` policies, `asset_view`, search) now matches its own columns: `location_id = any (scope_locations) or category_id = any (scope_categories) or id in (scope_mixed_ids)`. Profiles with one dimension go through the arrays; a profile with both goes through the id set of its intersection. So it stays exact across profiles, with no "one profile per grant" limit. Children still use `scope_asset_ids` on `asset_id`. Numbers are in §8.
- Scoped users do not see soft-deleted assets in the `asset` table, nor the child rows of soft-deleted assets (the id set holds live assets only). Tenant-wide users still do. `asset_history` uses a row check, so the history of an in-scope deleted asset still shows.
- `coverage_view` gets its own clause for the contract grant's scope (S2), in set form. `coverage_visible` is unchanged.
- `change_asset_status` checks scope after the permission check, so a missing grant still says "not allowed" (the 3.1 tests rely on it). Out of scope reads as "asset not found" everywhere. `transfer_asset` to a location outside scope raises `42501 location is outside your scope`.
- `allowed_asset_statuses` is empty for an asset outside the `asset_lifecycle` scope.
- Storage downloads need no change: the read policy goes through the attachment rows, whose RLS now carries the scope. Only `can_upload_attachment` changed.

**Goal:** a group can be assigned with a scope profile ("Plant Manager, scope = Pune plant and below"). The user then sees and changes only the assets in that scope, and the records that hang off those assets. No scope profile means tenant-wide, as today.

**Already decided, not reopened:**
1. D7 (data-model-goal1.md §2.10, §2.11): one rule row per value with a typed FK column per dimension (A), and `user_effective_permission` stores `scope_profile_id` (X). Rules on one dimension OR together, different dimensions AND together.
2. Spike 1.7 §6: the scope check must be **set form**, run once per statement. A per-row `in_scope(...)` helper is 100 to 1000 times slower and slows unscoped users too.
3. G2 (1.7): the rebuild is `select distinct`, and `scope_profile_id` must be part of the distinct.
4. Additive grants, no deny rules (CLAUDE.md §7.1). So a user's scope for a grant is the **union** of the scopes of every assignment that gives it.

**Reads with:** security-model.md §5, §6, §8.2; data-model-goal1.md §2.9 to §2.11, D7; spike-1-7-rls-performance.md §3, §6; data-model-goal2-locations.md (closure); data-model-goal3.md (asset_view, list, transfer); data-model-goal4.md (coverage_visible, OQ-26); data-model-goal5.md §13, §14 (invoker read paths).

**Open items used:** OQ-24, lean "no dimensions beyond location, category, vendor and criticality unless a pilot asks". 6.1 builds two of those four (S1). OQ-26 (a contract is visible if one covered asset is visible) is already built in `coverage_visible`; scope flows through it.

---

## 1. Tables

### 1.1 `scope_profile` (public, 1.4 pattern, domain `users_security`)

As data-model-goal1.md §2.10: `id`, `tenant_id`, `name` (1 to 80 chars), std columns. `unique (tenant_id, id)`, `unique (tenant_id, lower(name)) where deleted_at is null`.

### 1.2 `scope_profile_rule` (public, 1.4 pattern, domain `users_security`)

| Column | Type | Notes |
|---|---|---|
| `id`, `tenant_id`, std | | |
| `scope_profile_id` | uuid not null | FK `(tenant_id, scope_profile_id)` |
| `dimension` | text not null | `check in ('location','category')` in 6.1 [S1] |
| `location_id` | uuid null | FK `(tenant_id, location_id)` to `location`. Includes descendants (closure) |
| `category_id` | uuid null | FK `(tenant_id, category_id)` to `asset_category`. Includes child categories |

- `check ((dimension = 'location') = (location_id is not null) and (dimension = 'category') = (category_id is not null))`.
- Partial uniques `(tenant_id, scope_profile_id, location_id)` and `(..., category_id)` where `deleted_at is null`.
- Index `(tenant_id, scope_profile_id)`.
- A rule may point at an inactive location or category. It still scopes (the subtree is the subtree). The 2.x merge functions, when they come, repoint rule rows like any FK.

### 1.3 Link on the assignment

`user_group_assignment.scope_profile_id uuid null`, FK `(tenant_id, scope_profile_id)`. Null = tenant-wide. The existing row trigger already rebuilds the member on any assignment update, so setting or changing the profile rebuilds them.

### 1.4 `user_effective_permission.scope_profile_id`

Add the column (null = tenant-wide). The rebuild copies `a.scope_profile_id` and keeps it in the `distinct` (G2). A user who gets `asset_core.view` from two assignments, one Pune and one tenant-wide, holds two rows; the tenant-wide row wins (§3).

Profiles and rules are **not** copied into the derived table (D7 X). Editing a rule takes effect on the next statement with no rebuild and no `permission_version` bump: the JWT and the UI menus do not carry scope.

Index: none new. `has_permission()` keeps its `(tenant_id, user_id, domain_operation_id)` path, and the scope helpers read the same rows.

## 2. What "no scope" and "empty" mean [S4]

| Case | Meaning |
|---|---|
| Assignment with `scope_profile_id` null | Tenant-wide for every grant of that assignment |
| Profile with a location rule only | Those locations and below, any category |
| Profile with location and category rules | (location in L) **and** (category in C) |
| Profile with no live rules | Grants **nothing** (lean, default deny). D7's text says "a dimension with no rule is unrestricted"; that still holds inside a profile that has at least one rule |
| Profile soft-deleted while assigned | Refused: delete is blocked while a live assignment uses it |
| Asset with no location, profile has a location rule | Out of scope [S5] |

`has_permission()` does not change. It still answers "does the user hold this operation at all". Scope is a second, separate clause.

## 3. The set-form clause [S3]

Two helpers in `private`, `stable`, `security definer`, fixed `search_path`, reading only `user_effective_permission`, the rules, `location_closure` and `asset_category`:

- `private.scope_all(p_domain, p_operation) returns boolean`: true if the user holds the operation through at least one row with `scope_profile_id is null` (tenant-wide). The usual case, one index probe.
- `private.scope_asset_ids(p_domain, p_operation) returns setof uuid`: the live assets of the current tenant in the **union** of the user's profiles for that grant. Body, in outline:

```sql
with prof as (   -- one row per profile, locations expanded through the closure, categories through the tree
  select p.id,
         array(select c.descendant_id from rules r join private.location_closure c ...) as locs,  -- null if no location rule
         array(select ... recursive category subtree ...) as cats                             -- null if no category rule
  from <user's active uep rows for (domain, op) with a scope_profile_id> ... )
select a.id from public.asset a join prof p
  on (p.locs is null or a.location_id = any (p.locs))
 and (p.cats is null or a.category_id = any (p.cats))
where a.tenant_id = private.current_tenant_id() and a.deleted_at is null
```

Every read that is scoped then adds one clause, in the spike's shape (helpers inside `(select ...)`, so they run once):

```sql
and ((select private.scope_all('asset_core', 'view'))
     or a.id in (select private.scope_asset_ids('asset_core', 'view')))
```

- Unscoped users: `scope_all` is an InitPlan that returns true, the `or` short-cuts, the id set is never built. Cost about the same as `has_permission` (0.6 ms in the spike).
- Scoped users: one id set per statement (index scans on `asset_location_idx` and `asset_category_idx`), then a hashed semi-join. Children use the same clause on their `asset_id`.
- One helper for every surface means one place to review, and OR across profiles with AND inside a profile is exact (no over-grant).
- Option b in S3 (arrays of locations and categories matched on the row's own columns, as the spike measured) is faster for the asset table but cannot express two different profiles exactly; it would need the "one profile per grant" limit or a pairs table. Kept as the fallback if §8 fails.

## 4. Where the clause goes

Owner-run views and definer functions bypass table RLS, so each one gets the clause by hand. Invoker functions over those views get it for free.

| Surface | Kind | Clause on | Grant whose scope applies |
|---|---|---|---|
| `asset` select, update policies | RLS | `id` | `asset_core.view` / `.update` |
| `asset` insert policy | RLS | new row, see §6 | `asset_core.create` |
| `asset_view` | owner-run view | `a.id` | `asset_core.view` |
| `search_asset_ids`, `location_subtree_ids`, `category_subtree_ids` | definer | search adds it; the subtree helpers return ids only and are ANDed with `asset_view`, no change | `asset_core.view` |
| `list_assets`, `count_assets` | read `asset_view` | free | |
| `asset_history` | definer | its `exists (... public.asset ...)` | `asset_core.view` |
| `obligation` select, update, insert | RLS | `asset_id` | `obligation.*` |
| `service_record` select, update; `service_record_view` | RLS, owner-run view | `asset_id` | `service_record.*` |
| `coverage_asset` select, insert, update | RLS | `asset_id` | `coverage_contract.*` |
| `coverage_view` | owner-run view | already filtered by `coverage_visible`, which reads `asset_view`: free. OQ-26 holds: a contract shows if one covered asset is in scope, and a contract with no assets shows to every `coverage_contract.view` holder (4.2 rule) | |
| `asset_attachment`, `service_record_attachment` | RLS | `asset_id` (via the service record's asset) | their own domain |
| Storage upload and read helpers (3.6, 5.2b) | definer | their asset lookup | the attachment domain |
| `asset_coverage`, `asset_attachments`, `service_history`, `service_record_attachments`, `list_obligations`, `list_completions`, `maintenance_counts`, `location_asset_counts`, `location_status_counts` | invoker over the above | free | |
| `transfer_asset`, `change_asset_status`, `complete_obligation`, `undo_completion`, `create_asset_with_warranty` | actions | §6 | |

**Not scoped (lean, S7):** the location tree, categories, vendors and vendor contacts, contracts themselves (beyond OQ-26), `audit_log` (Auditor reads it tenant-wide; `asset_history` is scoped because it is reached from the asset), saved views, settings, security tables. The location tree still shows Mumbai to a Pune manager; its counts show 0 there.

## 5. Child records follow the asset [S2]

A child row (obligation, service record, coverage link, attachment) is in scope when its **asset** is in the scope of the child's own grant. So "obligation.view scoped to Pune" shows Pune obligations, whatever the user's `asset_core.view` scope. Screens that join `asset_view` (Maintenance, dashboard) show the intersection, which is what the user expects. Moving an asset (transfer) moves its children in and out of scope at once, with no rewrite: nothing is copied onto the children.

## 6. Writes [S6]

Lean: a scoped user can only leave a row **in** their scope.

- `asset` update: `using` checks the old row (id in scope for `asset_core.update`), `with check` checks the new location and category. The new row is not in the table yet, so `with check` cannot use the id set. It calls `private.in_scope(domain, op, location_id, category_id) returns boolean`, the same profile logic for one pair. Writes are single rows, so a per-row call is fine here (1 to 2 probes, inside the 7 ms write budget). Selects never call it.
- `asset` insert: `with check` uses `in_scope('asset_core','create', ...)`.
- `transfer_asset`: the asset must be in `asset_lifecycle.execute` scope before, and the target location must be in it after. So a Pune manager can move Pune to Pune, not Pune to Mumbai. A tenant-wide user (or an admin) does cross-plant moves.
- `change_asset_status`, `complete_obligation`, `undo_completion`: the asset in scope of their action grant. `create_asset_with_warranty` is invoker, so the insert policy covers it.
- Children insert (obligation, coverage link, attachment): `with check` uses the id set on `asset_id` (the asset exists already), so the set form works there.
- Refused writes raise the existing `42501` or read as "not found" (an out-of-scope id is treated like another tenant's id: no leak that it exists).

## 7. Admin and audit [S8]

- `scope_profile` and `scope_profile_rule`: view with `users_security.view`, create and update with `users_security.manage`, soft delete only. Audit rows are `category = 'security'` like the other security tables (D8).
- Setting a profile on an assignment is an update of `user_group_assignment`: already audited as security, already rebuilds the member.
- The UI to manage profiles and pick one on an assignment is the 6.3 Security screen [S9]. Until then, profiles are made by SQL (demo note).

## 8. Performance gate

Re-run the 1.7 spike scripts (`scripts/spike-1-7/`) against the real helpers, with 10% of the large tenant's users scoped to one site (20%) and to one area (0.1%), plus one user with two profiles. Targets from spike §2:

| Query | Target p95 | Spike 1.7 with arrays |
|---|---|---|
| List 50, site scope | 100 ms | 5 / 11 ms after F2 |
| List 50, area scope | 100 ms | 60 / 139 ms |
| Count, site scope | 200 ms | 225 / 260 ms |
| Unscoped list and count | no worse than today | |
| Two profiles | 100 ms list | not measured |

If the id-set form misses a target by a lot, switch the asset table (and only it) to S3 option b and keep the id set for children. Numbers go into this file as "As built".

**Measured, 1 Nov 2026** (`scripts/spike-6-1/bench.sql`, local Docker, one tenant of 200k assets over 5 sites > 4 buildings > 10 areas, p50 / p95 ms over 20 runs inside Postgres). Final form (as built):

| Scope | List 50 by name | Count | Search "pump 12" | Location tiles |
|---|---|---|---|---|
| Tenant-wide | 4.6 / 7.0 | 5.0 / 8.1 | 48 / 77 | 85 / 149 |
| One site (20%) | 8.9 / 21 | 11 / 122 | 42 / 49 | 119 / 149 |
| One area (0.5%) | 27 / 32 | 82 / 99 | 40 / 85 | 77 / 97 |
| Two profiles (site, plus site 2 AND one category) | 29 / 63 | 10 / 139 | 66 / 81 | 162 / 188 |

All within the targets. The first try (id set on the asset table too) missed: list 156 / 181 (site), 221 / 258 (two profiles); search 359 / 609 (site). Children (obligation, service record lists) for scoped users were not measured at volume: each builds the scoped id set once per statement.

## 9. Tests planned (`6_1_scope.test.sql`)

- `tests.cross_tenant` for `scope_profile` and `scope_profile_rule`, plus the 1.4 permission steps (`users_security` view, manage).
- Fixture: Pune (with a building and an area below) and Mumbai; assets in both; categories Pumps and Motors.
- **Pune manager cannot see Mumbai assets:** asset table, `asset_view`, `list_assets`, `count_assets`, search, `asset_history`, `location_asset_counts`, `location_status_counts`, `maintenance_counts`, `list_obligations`, `service_history`, `asset_coverage`, `coverage_view` (contract on Mumbai only is hidden, contract on both shows), both attachment tables and the storage helpers.
- Descendants: a Pune area asset is in scope.
- Category rule, and location AND category in one profile.
- Union: two profiles (Pune; Mumbai Pumps) see exactly Pune plus Mumbai Pumps, not Mumbai Motors.
- Scoped plus tenant-wide assignment = tenant-wide.
- Empty profile grants nothing; deleting an assigned profile is refused.
- No-location asset is out of scope for a location-scoped user.
- Per-grant scope: `obligation.view` scoped, `asset_core.view` tenant-wide.
- Writes: update a Pune asset to Mumbai refused; insert in Mumbai refused; `transfer_asset` Pune to Mumbai refused, Pune to Pune works; status change and completion on a Mumbai asset refused.
- Rule edit takes effect with no rebuild; assignment change rebuilds with `scope_profile_id`.
- Effective window: an expired scoped assignment gives nothing; an expired tenant-wide one no longer widens.
- The 1.3 and 1.7 rebuild tests still pass (row counts may change only by the new distinct key).

## 10. Build plan (after answers)

1. Migration `6_1_scope_profile`: the two tables, policies, triggers, the assignment FK, the UEP column, the rebuild.
2. Migration `6_1_scope_helpers`: `scope_all`, `scope_asset_ids`, `in_scope`.
3. Migration `6_1_scope_enforcement`: replace the policies, views and definer functions in §4 and §6 (`create or replace`, same signatures).
4. pgTAP `6_1_scope.test.sql`; regenerate types; spike re-run (§8).
5. Tracker 6.1 to In review, demo note, owner-review list.

## 11. DECIDE

| # | Question | Options | Lean | Cost to reverse |
|---|---|---|---|---|
| S1 | Dimensions in 6.1 | **a)** Location and category only (story title, security-model §10 M2). **b)** All four of D7 (also vendor, criticality) | a. OQ-24 lean: build only what a pilot needs; no pilot asked for vendor or criticality scope. Adding one later is a nullable column, a check change and one more `and` in the helpers | Low |
| S2 | Whose scope a child row follows | **a)** The child's own grant (obligation.view's profile), applied to the parent asset's location and category. **b)** Always the user's `asset_core.view` scope | a. D7 X already stores scope per grant; b throws that away and lets a "Pune obligations only" grant see Mumbai obligations if asset view is wide | Low: helper arguments |
| S3 | Set-form shape | **a)** One helper returning in-scope asset ids, `id in (select ...)`, with a `scope_all` short-cut, on every surface. **b)** Location and category arrays on the asset's own columns (the spike's shape), id set for children only | a. One clause, exact union across profiles. Gate in §8; fall back to b for the asset table if it misses. b needs "one profile per grant" or a pairs table to stay exact | Low: function bodies and policies, no schema |
| S4 | Profile with no rules | **a)** Grants nothing. **b)** Tenant-wide (D7 literal) | a. Deleting the last rule by mistake must not open every plant. Default deny | Low: one `exists` |
| S5 | Asset with no location, location-scoped user | **a)** Out of scope. **b)** In scope for everyone | a. Default deny. Admins see unlocated assets and place them | Low |
| S6 | Writes by a scoped user | **a)** The row must stay in scope: cannot create, update or transfer into another location or category outside scope. **b)** Check only the old row | a. Otherwise a Pune manager can push assets to Mumbai, losing them and touching Mumbai's data. Cross-plant moves need a tenant-wide user | Low: policies and action bodies |
| S7 | What is not scoped | **a)** Locations, categories, vendors, contracts beyond OQ-26, audit log, saved views stay tenant-wide. **b)** Also scope the location tree (hide Mumbai nodes) and vendors | a. They are master data shared across plants; hiding the tree breaks pickers. b can come later on its own | Low |
| S8 | Who manages profiles | **a)** `users_security.view` / `.manage`, security audit, no permission-version bump on rule edits. **b)** New domain `scope_profile` | a. Same people who assign groups; no catalog change | Low: a domain seed and policy swap |
| S9 | Split | **a)** 6.1 is database only (tables, helpers, enforcement, tests, types, spike re-run). Profile management and the assignment picker are 6.3. **b)** Add a small profiles screen now | a. 6.3 owns the Security screen; the review point (Pune manager in the UI) closes when 6.3 lands. Until then a demo SQL snippet makes the profile | None |

## 12. Not in 6.1

- Vendor and criticality dimensions (S1 b), scoping master data (S7 b).
- Any UI (6.3), secure field views beyond what exists (6.2), the explainer (6.5).
- Staged activation of profile changes (6.4).

---

# Story 6.2: restricted fields (gap audit and design)

**Status:** design, 1 Nov 2026. Waiting on the owner for R1 to R5.

**Goal:** a restricted field (CLAUDE.md §7.7) never reaches a user who lacks its field domain, on any path. Most of this was built in 3.1, 4.1, 4.2 and 5.2. 6.2 audits it, closes the gaps and adds one test file that covers every field on every surface.

## 13. Restricted fields

| Field | Domain | Stored in | Read through |
|---|---|---|---|
| Asset purchase value, currency | `asset_financials` | `asset.purchase_value`, `purchase_currency` | `asset_view` (masked), `asset_history` (masked) |
| Contract value, currency | `coverage_values` | `coverage.contract_value`, `contract_currency` | `coverage_view` (masked), `asset_coverage` (invoker over it) |
| Service cost, currency | `service_values` | `service_record.cost_amount`, `cost_currency` | `service_record_view` (masked), `service_history` (invoker over it) |
| Vendor tax IDs (GSTIN, PAN) | `vendor_tax_ids` | `vendor.custom_values` keys whose `field_definition` has that domain | `vendor_view` (`hidden_field_keys('vendor')`) |
| Asset custom fields behind any domain | the field's domain | `asset.custom_values` | `asset_view`, `asset_history` (`hidden_field_keys('asset')`) |

## 14. Audit: path by path

| Path | State | Notes |
|---|---|---|
| Base table select | **Safe** | Column grants: `asset`, `vendor`, `coverage`, `service_record` grant select without the money and `custom_values` columns. A `where` or `returning` on them is refused for the same reason |
| Masked views | **Safe** | The four views mask with `has_permission(<field domain>, 'view')`, once per statement. Custom keys go through `hidden_field_keys` |
| 6.1 row scope on the views | **Safe** | `asset_view` and `service_record_view` carry the scope clause; `coverage_view` through `coverage_visible`. `vendor_view` is not scoped (S7, master data). Masking and scope are independent: a scoped user with the field domain sees the value only on in-scope rows |
| Invoker functions (`list_assets`, `count_assets`, `asset_coverage`, `service_history`, `list_completions`, dashboard counts) | **Safe** | All read the masked views. No function sums or sorts by a restricted field |
| Definer functions | **Safe** | None returns a restricted value. `asset_history` masks (`mask_asset_data`). `category_vendors` returns ids; `merge_vendor`, `complete_obligation`, `undo_completion` return void. `complete_obligation` inserts the cost through the table, so the trigger checks it |
| Search | **Safe** | Trigram on name, tag and serial only. No restricted field is searchable |
| Sort and filter on the views (PostgREST) | **Safe** | The column is the masked expression, so a filter on it sees null |
| **Write triggers, money columns** | **Gap G1** | See §15 |
| Write triggers, hidden custom keys | **Safe** | Hidden keys are restored from the old row before any check, so a guessed value changes nothing and raises nothing |
| **`audit_log` (direct select)** | **Gap G2** | See §15 |
| `asset_history` (Audit tab) | **Safe** | Definer, masks money and hidden keys, marks them hidden |
| **Outbox payloads** | **Gap G3 (dormant)** | See §15 |
| Exports | **None exist** | Excel import (Goal 8) and any export must read the masked views |
| Storage | **Not a field path** | Attachments have their own entity domains; 6.1 scope applies |
| UI | **Safe** | Asset detail and form, coverage and service screens show "Hidden" and never send a masked field (`canMoney`). No UI change needed |
| Tax IDs as config | **Note** | Masked only if the tenant's GSTIN or PAN field uses `vendor_tax_ids`. The FK `(security_domain_id, entity)` allows `vendor_core` too. The demo tenant uses `vendor_tax_ids`. Template seeding is 7.1 |

## 15. Gaps

**G1. Equality oracle in the money write checks.** `check_asset_values`, `check_coverage` and `check_service_record` raise 42501 when a user without the field's view **changes** the value. So a user without view can send a guess: same as stored, the update passes; different, it fails. Sending null tells whether any value is stored. Starter groups that can do this today: Planner (purchase value, contract value), Technician (service cost). Equality only, but purchase values are often round numbers.

**G2. `audit_log` returns raw rows.** `old_data` and `new_data` hold the full row: money, costs, every custom key. RLS gives data rows to `audit_log.view`. In the starter groups every holder of `audit_log.view` also holds all four field domains, so nobody leaks today. A tenant group such as "Compliance: audit log only" would see every purchase value and tax ID. Nothing in the app reads `audit_log` directly (the Audit tab uses `asset_history`).

**G3. Outbox payloads carry raw rows.** `audit_row` writes `old` and `new` into `private.outbox_event`. Not reachable by any API role; no consumer until webhooks (9.3). `complete_obligation` leaves cost out of its own event, but the generic trigger on `service_record` still puts it in.

## 16. Design

**G1 fix [R1].** In the three triggers, split the check:
- No field **view**: on update, keep the old value silently (`new.x := old.x`), the way hidden custom keys are kept. No error, so no oracle. On insert, a non-null value still raises (no stored value to probe).
- View but no **update**: a changed value raises 42501, as today (they can see it, so nothing leaks).

The UI never sends a masked field, so no screen changes. The error text for view-but-no-update stays the same, so `fieldErrors` keeps working.

**G2 fix [R2].** Revoke `select (old_data, new_data)` on `public.audit_log` from `authenticated`; keep the other columns (who did what, when, to which record). Reads of the data go through definer functions that mask, as `asset_history` does. A masked tenant-wide reader comes with the story that builds an audit screen (6.5 access review, or later).

**G3 [R3].** No change in 6.2. Write into story 9.3: webhook delivery resolves the subscriber to an identity and masks payloads with the same domains (CLAUDE.md §7.3).

**Tests [R4].** New `6_2_restricted_fields.test.sql`:
- For each field (purchase value, contract value, service cost, GSTIN, a restricted asset custom key): no grant reads null or no key, grant reads the value, on the base table (column refused), the masked view, and each invoker or definer reader over it.
- G1: without view, an update with the right guess and with a wrong guess both pass and leave the value unchanged; with view and no update, a change raises.
- G2: `select old_data from audit_log` refused for `authenticated`; other columns still readable.
- 6.1 scope: a Pune-scoped user with the field domain sees the value on a Pune row, not on a Mumbai row.
- `tests.cross_tenant` already runs for `asset`, `vendor`, `coverage`, `service_record` in their stories. 6.2 adds a check that another tenant's row never shows in any of the four views, with every grant held.

**Migrations:** `6_2_money_write_checks` (three trigger functions, `create or replace`) and `6_2_audit_log_columns` (one revoke). No view or column changes, so types should not change; regenerated to confirm.

## 17. DECIDE

| # | Question | Options | Lean | Cost to reverse |
|---|---|---|---|---|
| R1 | Money write check without view | **a)** Keep old value silently (as custom keys). **b)** Raise whenever the value is in the update, even if unchanged (breaks forms that send the whole row; ours do not). **c)** Leave as is, document | a. Closes the oracle, matches the custom-field rule, no UI change | Low: three trigger bodies |
| R2 | `audit_log` raw data | **a)** Revoke the two data columns now; masked reader later with an audit screen. **b)** Build a masked `audit_log_view` now (per-table column map plus `hidden_field_keys`). **c)** Leave; document "grant `audit_log.view` only with the field domains" and test the starter grid | a. Default deny, one line, nothing in the app uses it. b builds a reader with no screen. c leaves the leak one custom group away | Low: a grant |
| R3 | Outbox payloads | **a)** Defer to 9.3, written into the story. **b)** Strip restricted fields from every payload now | a. No consumer exists; the right mask depends on the subscriber's identity, which 9.3 defines | Low |
| R4 | Test scope | **a)** One consolidated 6.2 file as §16. **b)** Gap tests only | a. The story's point is proof on every path | None |
| R5 | Tax ID fields per tenant | **a)** Leave as tenant config; 7.1 templates seed GSTIN and PAN with `vendor_tax_ids`. **b)** Seed GSTIN and PAN definitions for every tenant now | a. CLAUDE.md §8: optional configurable fields, do not hard-code India | Low |

## 18. Not in 6.2

- A masked audit log reader or screen (R2 a), webhook payload masking (9.3), export paths (none yet).
- Scoping vendors or the audit log (6.1 S7).
