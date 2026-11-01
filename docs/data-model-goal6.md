# Goal 6 data model: scope profiles and row scope (story 6.1), restricted fields (story 6.2), Security screen (story 6.3), change sets (story 6.4), explainer and access review (story 6.5)

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

**Status:** done, accepted by the owner 1 Nov 2026 (PR #50). The owner accepted every lean, R1 to R5, on 1 Nov 2026. Built in migrations `6_2_money_write_checks`, `6_2_audit_log_columns`; tests in `6_2_restricted_fields.test.sql` (52).

**As built (differences from the design below):**
- R1 is one generic trigger, `private.keep_masked_values(domain, columns...)`, on update of the money columns of `asset`, `coverage` and `service_record`, named `a_keep_masked_values` so it fires before the `check_*` triggers (before triggers run in name order). The three `check_*` functions are unchanged: they now see no change from a user without view. Four older tests that asserted the old raise (3.3 x2, 4.2, 5.2) now assert "passes, value unchanged".
- R2 replaces the table grant with a column list: a column revoke has no effect under a table-level grant. `select *` on `audit_log` is now refused for `authenticated`.
- Types did not change.

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

---

# Story 6.3: Security screen (design)

**Status:** done, accepted by the owner 1 Nov 2026 (PR #51). The owner accepted every lean, G1 to G8, on 1 Nov 2026. Built in migration `6_3_security_admin`; tests in `6_3_security_admin.test.sql` (29); UI `apps/web/src/Security.tsx` (Vitest `Security.test.tsx`, 8).

**As built (differences from the design below):**
- `set_group_policies` also checks manage, the tenant and `system` up front, so a refusal is an error instead of RLS's silent no-op on the update. RLS still decides.
- The 1.4 `rls_sample` domain is hidden from the grid (not business data; 1.6 leaves it out of every group).
- Assignment dates show as the UTC calendar date (shortcut noted in the code) until the shell holds the tenant's date format.

**Goal:** a security admin manages groups, each group's domain policies, assignments (with a scope profile) and scope profiles from one screen, with no SQL. Closes the Goal 6 review point: create a Pune-only Plant Manager in the UI and watch Mumbai assets disappear.

**Reads with:** data-model-goal1.md §2.5 to §2.11, D5, D6, D9; migrations `1_2_security_tables`, `1_3_*`, `1_5_audit_triggers`, `1_6_starter_groups`, `1_7_rebuild_triggers`, `6_1_scope_profile`; §1 to §7 above.

## 19. What already exists

| Change | Path today | Audit | Rebuild and version bump |
|---|---|---|---|
| Create, rename, soft delete group | `security_group` insert / update (RLS: `users_security.manage`, `tenant_can_write`, not `system`) | yes, `security` | on delete only (1.3 trigger on `deleted_at`) |
| Grant / revoke an operation | `group_domain_policy` insert / update of `deleted_at` (same RLS, not a `system` group) | yes | yes, once per statement (1.7 G1) |
| Assign, end, remove, set scope | `user_group_assignment` insert / update (RLS) | yes | yes, row trigger |
| Profiles and rules | `scope_profile`, `scope_profile_rule` insert / update (RLS) | yes | no bump (S8: the scope helpers read rules live) |
| Read the catalog | `security_domain`, `domain_operation` select with `users_security.view` | n/a | n/a |

So every write the screen needs is already guarded, audited and rebuilt. Missing: a member list with names (`user_profile` is own row only), the lock-out guard, and one write path for the grid that 6.4 can redirect.

## 20. Screen (matches Security.dc.html)

Route `/security`, sidebar Admin > Security. Shown with `users_security.view`; every control that writes needs `users_security.manage` (the Auditor sees it read-only). Header "Security", subtitle "Roles, domain policies and data scope". No "Review and activate", no draft banner, no "Why can this user see this?" (6.4, 6.5).

Tabs [G1]:
1. **Groups.** Left card: the group list and "New group". Right card: "<Group> · domain policies", the grid. One row per domain, its operations from `domain_operation` [G2]. Edits stay local until **Save** (one call) [G3]. A `system` group is read-only. Rename and Delete in the card header.
2. **Assignments.** Table: member, group, scope profile ("Tenant-wide" when null), from, to. "Add assignment": member, group, scope (profile picker), from, to. Row actions: change scope, end now, remove.
3. **Scope profiles.** Profile list; detail card as in the screen ("Locations ... and descendants", "Categories All", "Assigned to N users"), rules edited with the existing location tree and category pickers. New, rename, delete (the 6.1 in-use trigger already blocks deleting an assigned profile).

Labels: domain and operation names go through i18n (`security.domain.<code>`, `security.op.<code>`), falling back to `security_domain.description` and the raw code, so a new domain (a migration seed) shows with no code change (CLAUDE.md §7.10).

## 21. Database changes (migration `6_3_security_admin`)

1. **`public.security_members()`**: security definer, `stable`, fixed `search_path`. Returns `user_id, display_name, email, status` for the current tenant's live memberships; nothing without `users_security.view` [G4].
2. **`public.set_group_policies(p_group_id uuid, p_operation_ids uuid[])`**: security **invoker**, so RLS does the permission, tenant and `system` checks. One statement soft-deletes live rows not in the set, one inserts the missing ones. Unchanged grants keep their row. One save rebuilds each member at most twice (1.7 G1); audit is row by row as today. **6.4 hook:** this is the only grid write path, and 6.4 changes its body to write a draft change set. Nothing else is added for 6.4.
3. **Lock-out guard** `private.check_security_admin_left()`: constraint trigger, `deferrable initially deferred`, after update or delete on `group_domain_policy`, `user_group_assignment`, `security_group`, `tenant_membership`. At commit (the rebuild has run) it raises `42501 last security admin` when the tenant has no row in `user_effective_permission` for `users_security.manage` with `effective_from <= now()` and `effective_to is null` [G5] (the rebuild only writes rows for active members). Inserts never remove a manager, so they are not watched and provisioning (seed groups, then assign) passes. It applies only when `auth.uid()` is not null [G6].
4. **Group delete with live assignments** blocked by a `before update of deleted_at` trigger, as for scope profiles in 6.1 [G7].
5. No policy changes, no new domain.

New group: the client inserts `security_group` (code derived from the name), then, if "Copy from" is picked, calls `set_group_policies` with the source group's operation ids [G8]. No new function.

## 22. Tests (`6_3_security_admin.test.sql`)

- `security_members`: no grant returns nothing; view returns this tenant's members only.
- `set_group_policies`: refused without manage; adds and removes the right rows; unchanged grants keep their row id; the member's effective permissions and `permission_version` move; refused for a `system` group and for another tenant's group; idempotent.
- Lock-out: each way to lose the last manager raises, and passes when a second manager exists: revoke `users_security.manage`, remove the assignment, set its `effective_to`, disable or delete the membership, delete the group. Postgres (no `auth.uid()`) is not blocked. Provisioning inserts pass.
- Group delete: refused with live assignments, allowed without.
- `tests.cross_tenant` already covers the five security tables.
- Review point in SQL: a Pune-scoped Plant Manager made only through the paths the UI uses sees no Mumbai asset.
- Vitest: the grid sends the right set on Save, read-only for view-only users, the scope picker on an assignment.

## 23. DECIDE

| # | Question | Options | Lean | Cost to reverse |
|---|---|---|---|---|
| G1 | Tabs | **a)** Groups, Assignments, Scope profiles. Access review, Change sets and Audit hidden until 6.4, 6.5 and an audit screen. **b)** All five as in the screen, the later ones empty | a. No dead tabs. Scope profiles need their own tab: scope is per assignment, not per group as the screen's card suggests | None |
| G2 | Grid columns | **a)** One row per domain with its own operations inline as labelled checkboxes. **b)** Fixed View / Create / Update / Delete as in the screen, plus an "Other" column for execute, manage, run, review, commit, undo, complete, ask, save, share. **c)** One column per distinct operation (about 15, mostly blank) | a. Domains have different operation sets; a renders "from each domain's operations" with no gaps and no code change for a new operation. CRUD domains still look like the screen | Low: UI only |
| G3 | Grid save | **a)** Local edits, one Save calls `set_group_policies` (one transaction). **b)** Each checkbox writes at once | a. One rebuild per save, one lock-out check, one place for 6.4 to turn into a draft | Low |
| G4 | Member names | **a)** Definer `security_members()` gated by `users_security.view`. **b)** A co-member `user_profile` select policy with `users_security.view` | a. Exposes four columns for the current tenant only. b adds a cross-table check to every `user_profile` read | Low |
| G5 | Who counts as "can manage security" for the guard | **a)** Active member holding `users_security.manage` now and open-ended (`effective_to is null`). **b)** Holding it now, any end date | a. With b, an admin can end their only assignment tomorrow and the tenant locks itself out with no further change. Scoped grants count (scope does not limit `users_security`) | Low: one condition |
| G6 | Guard for system jobs | **a)** Only user-driven changes (`auth.uid()` not null). **b)** Always | a. Provisioning and support scripts (postgres) must be able to repair a tenant; they bypass RLS anyway | Low |
| G7 | Delete a group with live assignments | **a)** Blocked: "remove its assignments first", as scope profiles. **b)** Allowed: members lose the grants at once | a. A misclick would silently strip access from every member | Low: one trigger |
| G8 | "New group from template" | **a)** "New group" with an optional "Copy from" any group (the starters are already each tenant's templates). **b)** Re-seed from the 1.6 starter templates (new function; `seed_starter_groups` skips templates already used) | a. No new function. Industry templates are 7.1 | Low |

## 24. Build plan (after answers)

1. Migration `6_3_security_admin` (§21), pgTAP `6_3_security_admin.test.sql` (§22), regenerate types.
2. `apps/web/src/Security.tsx` (three tabs), route, i18n keys, tokens only. Vitest. Browser check on the local seed.
3. Tracker 6.3 to In review, demo note, owner-review list (lock-out trigger, `security_members`, `set_group_policies`, group delete trigger).

## 25. Not in 6.3

- Drafts, review and activate, change sets, OQ-22 (6.4). The explainer and access review (6.5). An audit log reader (6.2 R2).
- Inviting or creating users and disabling members (provisioning, OQ-16). Segregation of duties.

---

# Story 6.4: Draft, review, activate change sets (design)

**Status:** done, accepted by the owner 1 Nov 2026 (PR #52). The owner accepted every lean, C1 to C8, on 1 Nov 2026. Built in migration `6_4_change_sets`; tests in `6_4_change_sets.test.sql` (68); UI `apps/web/src/Security.tsx` (Vitest `Security.test.tsx`, 11).

**As built (differences from the design below):**
- The live table keeps its grants: with no write policy a direct insert is refused (42501) and a direct update touches no row, as for the Auditor today. A revoke would have turned the 1.6 "Auditor cannot update" checks into errors for no gain.
- One shared check helper `private.check_security_manage()` (manage and `tenant_can_write`), not callable by clients.
- Tests changed because of C2: 1.3 "admin grants an operation" now expects the refusal; 6.3 saves through draft then activate; 1.6 seeds a change set row for the tenant B coverage check.
- The grid hint under Save says saved changes go to the draft.

**Goal:** group policy edits are drafted, reviewed as a diff and activated together, in one transaction, with audit (security-model.md §2.6, §9). Nothing applies until activated.

**Reads with:** security-model.md §2.6, §7 (`policy_change_set`), §9; data-model-goal1.md D9 (no status column on the live rows); §19 to §25 above; migration `6_3_security_admin`.

**Open items used:** OQ-22, lean "single approver for pilots" (C3). Not settled here.

## 26. What 6.3 already gives us

- `set_group_policies(group, operation_ids)` is the only grid write path. It was left as the 6.4 hook.
- The live writes on `group_domain_policy` already rebuild `user_effective_permission`, bump `permission_version`, write the `security` audit row, and run the deferred lock-out guard at commit.

So activation can **replay the draft through the same live writes**. Rebuild, version bump, row audit and the lock-out guard come for free. 6.4 adds a place to hold the draft, the diff, and the activate and discard actions.

## 27. Design

1. **Tables** (standard columns, RLS, audit trigger `security`):
   - `policy_change_set`: `status` (`draft`, `activated`, `discarded`), `activated_by`, `activated_at`. Partial unique: one `draft` per tenant [C4].
   - `policy_change_set_item`: `policy_change_set_id`, `security_group_id`, `operation_ids uuid[]` (the group's wanted set), `before_ids uuid[]` (filled at activation, for history) [C5, C8]. Unique `(policy_change_set_id, security_group_id)`. Composite FKs.
   - Select with `users_security.view`. No insert, update or delete policies: writes go through the functions below [C2].
2. **`set_group_policies`** keeps its signature, so the UI call does not change. New body: open the tenant's draft if none, then upsert the item for the group. If the wanted set equals the live set, the item is removed (this is also "revert this group"). Same checks as 6.3 (manage, `tenant_can_write`, group live, not `system`). Becomes security definer, because tenants can no longer write the draft tables directly.
3. **`activate_change_set(p_id)`**: definer, checks manage and `tenant_can_write`, locks the draft row (`for update`). For each item whose group is still live [C6]: store `before_ids`, then run the 6.3 diff (soft-delete removed grants, insert added ones). Set `activated`, `activated_by`, `activated_at`. One transaction. At commit the 6.3 guard raises `last security admin` if the result locks the tenant out, and the whole activation rolls back; the draft stays.
4. **`discard_change_set(p_id)`**: sets `discarded`. Any manager.
5. **Live table locked** [C2]: drop the `insert` and `update` policies on `group_domain_policy`. Only `activate_change_set` (definer) and postgres write live grants. Group create, rename and delete stay direct (a new group has no grants; delete is blocked while assigned, G7).
6. **`change_set_diff(p_id)`**: invoker, `stable`. Rows of `group, domain, operation, change ('add' | 'remove')`: wanted vs live for a draft, wanted vs `before_ids` for history. One function for the review screen and the history.

## 28. Screen (matches Security in assetly-screens.html)

- Header gets **Review and activate** (primary, manage only, shown when the draft has items).
- Banner under the header: "N draft policy changes pending. Nothing applies until activated." N = diff rows.
- Groups tab: the grid loads the draft set for the group when there is one, with a "Draft" tag by the title (the screen's "Version 4 · draft", without a version number [C7]). Save writes to the draft. A "Revert" button sets the group back to live.
- New **Change sets** tab [C7]: the open draft's diff grouped by group (`+ Asset core · Create`, `− Vendor core · Delete`), Activate and Discard; then a history list (date, drafted by, activated by, groups changed), each row expands to its diff [C8]. Activate asks for a confirm.
- "Copy from" on a new group now drafts the copy; the new group's grants apply on activation.

## 29. DECIDE

| # | Question | Options | Lean | Cost to reverse |
|---|---|---|---|---|
| C1 | Which edits go through a change set | **a)** Group policies only (the grid). Assignments, scope profiles and rules stay direct. **b)** Policies and assignments. **c)** Everything on the screen | a. "Policy change set" is about policies, and the screen drafts only the grid. Assignments are daily work (a new technician should not wait for an activation). Known gap: assignment and scope edits still change access at once. They stay audited, and the lock-out guard still covers them | Medium: b or c add item kinds and diff code, and lock more tables |
| C2 | Block direct writes to `group_domain_policy` | **a)** Yes: drop its insert and update policies; only activation writes. **b)** No: the draft is a UI convention | a. Enforce in the database (CLAUDE.md §7.2). With b, any manager can skip review through the REST API | Low: re-add two policies |
| C3 | Can the drafter activate their own draft (OQ-22) | **a)** Yes. Any manager activates after reviewing the diff; drafter and activator are both recorded. **b)** No: a different manager must activate. **c)** A tenant setting choosing a or b | a. OQ-22 lean is single approver for pilots, and a pilot often has one admin; b would block every change for them. c when a customer asks | Low: one check, later a setting |
| C4 | How many drafts | **a)** One shared draft per tenant; any manager adds to it. **b)** Many drafts, one per author, with a conflict check at activation (refuse when a group changed since the draft read it) | a. No conflicts to handle: two managers editing the same group edit the same item, last save wins, and the diff shows the result before anyone activates. Matches the screen's single banner. b needs a base snapshot, a conflict error and a draft picker | Medium: a column, a check and UI |
| C5 | Draft item shape | **a)** The group's whole wanted set (`uuid[]`), diff computed against live. **b)** One row per add or remove | a. Same input as `set_group_policies` today; no stale add/remove rows; diff is one query | Low |
| C6 | Draft item for a group deleted before activation | **a)** Skipped at activation and hidden from the diff. **b)** Activation fails until it is removed | a. The group is gone; nothing to apply. Delete is already blocked while the group is assigned | Low |
| C7 | Review UI | **a)** Change sets tab with a grouped add/remove list, banner, Review and activate button, Draft tag on the grid; no version numbers. **b)** Also a side-by-side before/after grid. **c)** Version numbers per group | a. The list is what the banner counts; b and c are more UI for little gain at pilot size | Low: UI only |
| C8 | Keep history of activated and discarded sets | **a)** Yes: rows stay, `before_ids` stored at activation, history list on the tab. **b)** Only the row-level audit log | a. One column; shows "what changed in set X" without the audit log, which has no reader yet | Low |

Fixed, not a choice: activation is one transaction; rebuild, version bump, row audit and the lock-out guard are the existing triggers; a lock-out rolls the whole activation back and keeps the draft.

## 30. Tests (`6_4_change_sets.test.sql`)

- `set_group_policies`: refused without manage, for a `system` group and another tenant's group; opens one draft; live grants and `permission_version` unchanged; saving the live set removes the item.
- Direct insert or update on `group_domain_policy` refused for a manager.
- `change_set_diff`: right adds and removes; deleted group hidden.
- `activate_change_set`: refused without manage and on a read-only tenant; applies every item; members' effective permissions and `permission_version` move; status, `activated_by`, `before_ids` set; second activate refused; drafter can activate (C3 a).
- Lock-out: a draft that revokes the last manager's `users_security.manage` fails at commit; the draft stays open.
- `discard_change_set`: status set; nothing applied; the next save opens a fresh draft.
- One draft per tenant; `tests.cross_tenant` for both new tables.
- The 6.3 tests that wrote live grants through `set_group_policies` now activate after.
- Vitest: Save writes the draft; banner count; Activate and Discard; read-only for view users.

## 31. Build plan (after answers)

1. Migration `6_4_change_sets` (§27), pgTAP (§30), regenerate types.
2. `Security.tsx`: banner, Review and activate, Draft tag, Revert, Change sets tab; i18n; tokens. Vitest. Browser check on the local seed.
3. Tracker 6.4 to In review, OQ-22 note, demo note, owner-review list.

## 32. Not in 6.4

- Drafting assignments and scope profiles (C1 b, c). A separate approver or segregation of duties (C3 b, c). Many drafts (C4 b). Scheduled activation. Rollback of an activated set (draft the old grid again instead).

---

# Story 6.5: "Why can this user see this?" explainer and access review report (design)

**Status:** in review, 1 Nov 2026. The owner accepted every lean, E1 to E9, on 1 Nov 2026. Built in migration `6_5_explain_access`; tests in `6_5_explain_access.test.sql` (29); UI `apps/web/src/Security.tsx` (Vitest `Security.test.tsx`, 15).

**As built (differences from the design below):**
- `group_deleted` is not an outcome: a deleted group's assignments are left out (they grant nothing and the screen does not list them).
- An asset id is checked against the caller's `asset_view` for every domain, not only scoped ones, so the rule is the same everywhere.
- The explainer's asset field is a tag box (looked up in `asset_view`), not a search picker; no picker component exists to reuse.
- The sensitive-domain list is read from `security_domain.kind = 'field'`, not hard-coded.
- CSV cells starting with `= + - @` get a leading quote, so a spreadsheet does not run a group or member name as a formula.

**Goal:** a security admin or auditor answers two questions with no SQL. (1) For one user, a domain and operation, and optionally one asset: does the user have access, and which assignment, group, policy and scope profile gives or blocks it? (2) Who holds which groups and scopes, filtered by a sensitive domain, as a file to hand to an auditor (security-model.md §3, §9).

**Read-only.** No new table, no new write path, no policy change.

**Reads with:** security-model.md §3, §9; §1 to §7 (scope), §13 (field domains), §19 to §21 (`security_members`, the screen), §27 (change sets) above.

## 33. What already exists

- `users_security.view` already reads every group, live policy, assignment, scope profile and rule, the open draft (`change_set_diff`), and member names (`security_members`). The Security screen loads most of it.
- The scope helpers (`scope_rules` and the others) work for **the caller only** (`auth.uid()`). Nothing evaluates another user's scope.
- `user_effective_permission` is `private`: the client cannot read another user's derived rows.

So the access review needs no new database code if the browser joins what it already reads (E5 b). The explainer needs one function: another user's scope and the asset check must be worked out in the database.

## 34. Explainer: `public.explain_access(p_user_id, p_domain, p_operation, p_asset_id default null)`

Security definer, `stable`, fixed `search_path`, in a new migration `6_5_explain_access`.

**Who may run it [E1]:** the caller needs `users_security.view`, and the target must be a member of the caller's current tenant. Otherwise it returns no rows (as `security_members`).

**What it returns:** one row per live assignment of the target in the current tenant, plus one summary row:

| Column | Meaning |
|---|---|
| `security_group_id`, `group_name`, `scope_profile_id`, `scope_profile_name`, `effective_from`, `effective_to` | The assignment |
| `outcome` | `grants`, `no_policy` (the group does not hold the operation), `not_effective` (dates), `out_of_scope` (asset given, outside the profile), `empty_profile` (S4), `member_inactive` |
| `draft` | `add` or `remove` when the open change set would change this group's grant for the operation, else null [E4] |

Summary row (`security_group_id` null): `grants` if any assignment grants, else `denied`. Plus a `note`: tenant read-only (writes refused by `tenant_can_write`), or "scope does not apply to this domain" [E3].

**How it decides:** from the raw graph (assignment, group, live `group_domain_policy`, membership, profile rules), per assignment, so it can say *why*. The summary is cross-checked against the target's rows in `user_effective_permission` (what enforcement reads). If they disagree, the summary says `denied` with note `rebuild_mismatch`, so a rebuild bug shows instead of a false "yes" [E2].

**Scope for another user:** a new private helper `private.profile_scope(p_profile_id) returns table (locs uuid[], cats uuid[])`, the per-profile half of `scope_rules` (closure for locations, tree for categories, null when a dimension has no rule, no row when the profile has no live rule). The 6.1 hot-path helpers are **not** changed [E6].

**The asker's own limits [E1]:**
- Asset given: the function first checks that the **caller** sees the asset (`exists (select 1 from public.asset_view where id = p_asset_id)`, which runs the caller's own `asset_core.view` and scope). If not, it raises `asset not found`, as everywhere else (6.1 §6). So nobody learns that an asset outside their own scope exists, or where it is.
- It returns only ids and names the caller already reads on the Security screen (groups, profiles, dates) and a yes or no. Never an asset field, never a restricted value.

**Which domains scope applies to [E3]:** a fixed list in the function, the same as 6.1 §4: `asset_core`, `asset_lifecycle`, `obligation`, `service_record`, `coverage_contract` and the two attachment domains. For other domains an asset id is ignored and the note says scope does not apply.

## 35. Access review report

New tab **Access review** on the Security screen (the screen's tab list already shows it).

- One row per live assignment: member, email, member status, group, scope profile ("Tenant-wide"), from, to, state (`active`, `future`, `ended`), and the sensitive domains the group grants (the field domains of §13: `asset_financials`, `coverage_values`, `service_values`, `vendor_tax_ids`) [E7].
- Filters: domain (any can be picked; the four field domains first) [E7], group, and "current only" (default on).
- Live grants only; the draft banner already says what is pending [E4].
- **Export CSV**: builds the CSV in the browser from the filtered rows (a `Blob` and a download link). No dependency, no server, and the file holds only what is on screen [E8].
- Shown with `users_security.view`, so the Auditor can run it.

## 36. Explainer UI

The header button **Why can this user see this?** (as in the screen) opens a panel: member, domain, operation (from the domain's operations), optional asset (the existing asset search, which only offers assets the caller sees). Result: a verdict line ("Asha can view Asset core on PMP-0042" or "cannot"), then the assignments with their outcome in plain words ("Plant Manager, scope Pune: grants", "Technician: group does not hold Update"), plus draft marks and notes. Shown with `users_security.view`.

## 37. DECIDE

| # | Question | Options | Lean | Cost to reverse |
|---|---|---|---|---|
| E1 | Who may run the explainer, and on what | **a)** `users_security.view` holders, for any member of the tenant; an asset only if the caller sees it (else "asset not found"). **b)** Also any user for **themselves** ("why can't I see this?"). **c)** `users_security.manage` only | a. View holders already read every group, policy and assignment, so the only new fact is "this asset is in that user's scope", gated by the caller's own sight of the asset. b is a later add (one `or p_user_id = auth.uid()`) but shows a scoped user the shape of their scope. c locks out the Auditor, the main reader | Low: one condition |
| E2 | Source of the verdict | **a)** Per-assignment reasons from the raw graph, summary checked against `user_effective_permission`; a mismatch shows as denied with a note. **b)** Graph only. **c)** Derived table only (no reasons) | a. Reasons need the graph; the truth is what enforcement reads. A mismatch is a rebuild bug and must show | Low: function body |
| E3 | Where "scope applies to this domain" lives | **a)** A fixed list in the function, matching where 6.1 put the clause. **b)** A new column on `security_domain` | a. The clause is in policies (code), not data, so a column would claim config that drives nothing | Low |
| E4 | Pending draft changes | **a)** Explainer marks each group the open draft would change for the operation; verdict stays live. Access review shows live only. **b)** Ignore drafts. **c)** Also a "verdict after activation" | a. One read of the draft item per group answers "will activating fix it?" with no second verdict to test | Low |
| E5 | Access review data | **a)** A new invoker SQL function `access_review()`. **b)** The browser joins what the screen already reads (assignments, groups, live policies, profiles, `security_members`) | b. No new database surface to review; RLS already gates every read with `users_security.view`. a when the public API (Goal 9) needs the report | Low: add the function later |
| E6 | Another user's scope | **a)** New `private.profile_scope(profile_id)`, used only by the explainer; 6.1 helpers unchanged. **b)** Rewrite `scope_rules` over it, one copy | a. The 6.1 helpers are on every read path and were benchmarked; changing them for a read-only tool means a new bench. Cost: the rule expansion exists twice (a test asserts they agree) | Low |
| E7 | Sensitive-domain filter | **a)** Any domain; the four field domains listed first and shown as columns. **b)** The four field domains only | a. Same code; auditors also ask "who can manage security" | None: UI |
| E8 | Export format | **a)** CSV built in the browser from the filtered rows. **b)** Excel `.xlsx` (needs a library). **c)** Server-side export | a. No dependency, opens in Excel, nothing new on the server; no custom service until Goal 8 | Low |
| E9 | Audit explainer runs and exports | **a)** No: read-only, returns nothing the caller cannot already read. **b)** A `security` audit row per run or export | a. security-model §9 audits reads of restricted domains; neither tool returns a restricted value. b adds a write path to a read-only story | Low |

## 38. Tests (`6_5_explain_access.test.sql`)

- No rows without `users_security.view`; another tenant's user gives no rows.
- Each outcome: grants, no_policy, not_effective (future and ended), out_of_scope (Pune manager, Mumbai asset), empty_profile, member_inactive.
- Union: a scoped and a tenant-wide assignment, summary grants.
- An asset the caller cannot see raises `asset not found` (a Pune-scoped auditor asking about a Mumbai asset).
- Draft: a drafted revoke shows `remove`, a drafted grant `add`; verdict unchanged until activation.
- Summary matches what the target really sees (`tests.act_as` the target, look for the asset in `asset_view`).
- `profile_scope` agrees with `scope_rules` on the fixture profiles.
- Vitest: explainer outcomes render; access review filters by domain; CSV has the header and filtered rows (quotes escaped).

## 39. Build plan (after answers)

1. Migration `6_5_explain_access` (`profile_scope`, `explain_access`), pgTAP, regenerate types.
2. `Security.tsx`: header button and panel, Access review tab, CSV export; i18n; tokens. Vitest. Browser check on the local seed.
3. Tracker 6.5 to In review, demo note, owner-review list (`explain_access`, `profile_scope`).

## 40. Not in 6.5

- Self-service "why can't I see this?" (E1 b), an `access_review()` SQL function (E5 a), Excel or server export (E8 b, c), audit of runs (E9 b).
- Periodic access certification, segregation of duties (security-model §10, later).
- An audit log reader (6.2 R2), the screen's Audit tab.
