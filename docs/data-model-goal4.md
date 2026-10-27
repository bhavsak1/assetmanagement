# Goal 4 data model: vendors (story 4.1)

**Status:** done, 24 Oct 2026. Owner accepted every lean, V1 to V7, on 24 Oct 2026. Built in the `4_1_*` migrations; 4.1b (section 7) is a separate story.

**Reads with:** CLAUDE.md §6 to §8, `security-model.md` §4, knowledge base §2, §5, §6.2, §12, [data-model-goal2.md](data-model-goal2.md) §1.2 and §2 (field definitions, per-key masking), [data-model-goal3.md](data-model-goal3.md) §4, §5, §8, §13, A5, [data-model-goal2-locations.md](data-model-goal2-locations.md) L2 (deactivate versus soft delete), [spike-1-7-rls-performance.md](spike-1-7-rls-performance.md) §6.

**Open items used (current lean, not settled):** OQ-06 (OEM and O&M pickers limited to vendors tagged to the category; admin override later). It shapes 4.1b, not 4.1.

**Already in the catalog (1.2 seed, 1.6 grid):** `vendor_core` (entity: view, create, update, delete) "Vendor records and contacts", and `vendor_tax_ids` (field: view, update). `field_definition.entity` already allows `'vendor'`. No new domain or operation is needed for 4.1.

---

## 1. `vendor` (public, 1.4 RLS pattern)

| Column | Type | Notes |
|---|---|---|
| id, tenant_id, std | | Standard columns, `unique (tenant_id, id)` |
| name | text not null | 1 to 200 chars, trimmed. **Unique per tenant, case-insensitive, among rows with `deleted_at is null`** (same as `asset_category`). A deactivated vendor still holds its name, so no near-duplicate can be added beside it |
| code | text null | Optional short code (for imports and ERP). Unique per tenant, upper-cased, where set and `deleted_at is null`. Same rule as `location.code` |
| roles | text[] not null default `'{}'` | [V3] Subset of `{oem, om, supplier}`. Check: `roles <@ array['oem','om','supplier']` and no duplicates. Empty is allowed (a vendor being set up) |
| phone, email, website | text null | Company-level contact basics. Light checks: email has an `@`, max lengths. No country-specific format |
| address | text null | One free multi-line field. No India-only parts (state, PIN). Structured address waits until a story needs it |
| notes | text null | |
| is_active | boolean not null default true | Deactivate, never delete (CLAUDE.md §8, L2 a). `deleted_at` is kept for the 4.1b merge and for rows entered by mistake |
| custom_values | jsonb not null default `'{}'` | Vendor custom fields [V1], GSTIN and PAN among them. Same rules as asset (data-model-goal2 §2) |

- Triggers: `set_updated_at`, `check_soft_delete('vendor_core', 'delete')`, `audit_row('data')`, and `private.check_vendor_values()` (section 3).
- Indexes, all partial `where deleted_at is null`, tenant first: unique `(tenant_id, lower(name))`, unique `(tenant_id, code) where code is not null`, list `(tenant_id, name, id)`.
- Not in 4.1: row scope by vendor (6.1), vendor attachments, vendor portal login (KB §12 hook: vendors and contacts are their own rows, so a login can be added later), "has active coverage" filter and "Active coverages" column (4.2).

## 2. `vendor_contact` (public, 1.4 RLS pattern)

| Column | Type | Notes |
|---|---|---|
| id, tenant_id, std | | Standard |
| vendor_id | uuid not null | Composite FK `(tenant_id, vendor_id) → vendor (tenant_id, id)` |
| name | text not null | 1 to 200 chars |
| title | text null | Role or note: "Service engineer, west zone" |
| phone, email | text null | Both optional; only name is required (keep mandatory fields minimal, CLAUDE.md §10.3) |
| is_primary | boolean not null default false | At most one live primary per vendor: partial unique `(tenant_id, vendor_id) where is_primary and deleted_at is null`. Setting a new primary clears the old one in the same transaction (trigger), so the UI does one write |

- Index `(tenant_id, vendor_id) where deleted_at is null`.
- [V4] Who sees contacts. Removal is a soft delete (`deleted_at`), checked against `vendor_core.update`, not `delete` (removing a contact is editing the vendor; Plant Manager has update but not delete). Lean below.
- Personal data. A hard erase on request (DPDP) is a later admin action, noted for the owner, not built.

## 3. Custom values on vendor [V1] [V2]

GSTIN and PAN are **vendor custom fields**: `field_definition` rows with `entity = 'vendor'`, `category_id` null (vendors have no category), type `text`, domain `vendor_tax_ids`. Nothing in core knows the words GSTIN or PAN.

- **Read:** `public.vendor_view` (owner-run, like `asset_view`, and not `security_barrier` for the same reason: a barrier view cannot use the list index): repeats the base select policy (tenant, `vendor_core.view`, `deleted_at is null`) and returns `custom_values - (select private.hidden_field_keys('vendor'))`. The 3.1 helper already takes the entity. The base table grants `select` on every column except `custom_values`.
- **Write:** `private.check_vendor_values()` before insert or update, the same rules as asset §4.1 checks 2 to 4 and 6: hidden keys kept as stored, changed keys need an active definition, the right type (`private.custom_value_ok`), and `update` on the field's domain; unknown keys refused; `is_required` checked on insert and on data changes. No category line (every vendor field applies to every vendor).
- **Format check** [V2]: only if the tenant set one on the field. `field_definition.pattern` (text fields only; the check constraint compiles the regex), checked on changed values by `private.validate_field_pattern()` on both `asset` and `vendor`.
- **Defining the fields:** a "Vendor fields" card on the Vendors page, reusing the 2.2 `FieldForm` (export it from `Categories.tsx`), shown to `category_config.manage` (the existing `field_definition` policies; no policy change). A tenant outside India just never adds them. Not seeded locally: the SQL tests assume tenant A starts empty (as in every earlier story), so the demo adds GSTIN and PAN through the card.
- **List column:** the screen shows a GSTIN column. With fields as data, the list shows the **first vendor field in `vendor_tax_ids` by sort order** as that column, labelled with its own label, and "Hidden" without `vendor_tax_ids.view`. No column if the tenant has none.

## 4. Policies (1.4 template)

| Table | select | insert | update | soft delete |
|---|---|---|---|---|
| vendor | tenant, `vendor_core.view` | `vendor_core.create`, `tenant_can_write()` | `vendor_core.update`, `tenant_can_write()` (includes deactivate and roles) | `vendor_core.delete` |
| vendor_contact | tenant, `vendor_core.view` | `vendor_core.update`, `tenant_can_write()` | `vendor_core.update`, `tenant_can_write()` | `vendor_core.update` |

- No delete policy; `delete` and `truncate` revoked on both.
- Contact insert uses `update`, not `create`: adding a contact edits an existing vendor. Plant Manager (view, create, update) can then do everything on the screen except soft delete a vendor.
- Starter grid unchanged: Tenant Admin all four plus tax IDs view and update; Plant Manager view, create, update plus tax IDs view; Maintenance Planner, Technician view; Finance Viewer view plus tax IDs view.

## 5. Read path and search [V5]

- The Vendors list reads `vendor_view` through PostgREST: `order=name,id`, 50 rows then "Show more" (a growing limit, not keyset: names inside a PostgREST `or()` cursor need escaping, and V5 assumes small lists), role filter `roles=cs.{oem}`, active filter.
- Primary contact for the list: one extra query `vendor_contact?is_primary=eq.true&vendor_id=in.(...)` for the page's ids.
- Search: lean is plain `ilike` on name and code (section 6, V5). The test proves the list walks `(tenant_id, name, id)` with a limit (EXPLAIN), as 3.1 did for assets.

## 6. Owner decisions (DECIDE)

### V1. GSTIN and PAN: custom fields or columns

| | Option |
|---|---|
| A | Vendor custom fields in `vendor_tax_ids`, masked per key by `hidden_field_keys('vendor')` in `vendor_view` |
| B | Columns `gstin`, `pan` (or `tax_id_1`, `tax_id_2`) masked by `case when has_permission('vendor_tax_ids','view')` in the view |

**Lean: A.** CLAUDE.md §8 and KB §6.2 say "configurable fields, not columns", G6 already ties `vendor_tax_ids` to vendor fields, and the masking and write checks exist. Also gives tenants other vendor fields for free. **Cost to reverse:** medium (data copy from JSONB to columns, or back).

### V2. Format check on a field

| | Option |
|---|---|
| A | None in 4.1. Any text is accepted |
| B | New nullable `field_definition.pattern` (a regex, `text` fields only), checked on write with one message; set in the field form. Applies to asset fields too |

**Lean: B.** One column, one check line, one form input, and it is what "format checks only if configured" asks for. The regex for GSTIN lives in tenant data, not code. **Cost to reverse:** low (additive column).

### V3. Roles: fixed list in an array, join table, or tenant data

| | Option |
|---|---|
| A | Fixed system codes `oem`, `om`, `supplier` in `vendor.roles text[]` with a check. Labels from i18n |
| B | Fixed codes in a `vendor_role (tenant_id, vendor_id, role)` join table |
| C | Tenant-defined role table |

**Lean: A.** Roles drive logic (OEM and O&M pickers in 4.1b, coverage vendor in 4.2), so they are a system list like the 5 system statuses, not tenant data. A vendor holds few roles and nothing hangs off a role row, so an array is enough; `roles @> '{oem}'` filters it. **Cost to reverse:** low to medium (A to B is a one-statement copy).

### V4. Who sees contacts

| | Option |
|---|---|
| A | Anyone with `vendor_core.view` (the domain is "Vendor records and contacts") |
| B | New domain `vendor_contacts` (view, update), seeded as data, granted to Tenant Admin, Plant Manager, Maintenance Planner, Technician |

**Lean: A.** Technicians need the service engineer's phone; every starter group with vendor view would get B anyway. B is additive later (a domain row plus a policy change). **Cost to reverse:** low.

### V5. Search

| | Option |
|---|---|
| A | Plain `ilike` on name and code over `vendor_view` |
| B | The 3.2 approach: trigram GIN plus an id-only `security definer` helper and a `list_vendors()` function |

**Lean: A.** An SME has tens to a few thousand vendors; reading a tenant's vendors is a few ms. B is about 60 lines and a second index for no gain yet. Upgrade is additive (helper plus index, the screen keeps the same call shape if it goes through an rpc later). **Cost to reverse:** low.

### V6. Split [CLAUDE.md §5.4]

| | Option |
|---|---|
| A | **4.1:** vendor, roles, contacts, vendor fields (tax IDs) and masking, Vendors screen. **4.1b:** category tagging tab, `asset.oem_vendor_id` and `om_vendor_id`, write rules, form pickers and overview, list helper change, `merge_vendor` |
| B | One story for all of it |

**Lean: A.** 4.1 alone is two tables, a view, a write trigger and a new screen with owner-review items (RLS, masking). 4.1b touches the asset table and the asset screens. **Cost to reverse:** none.

### V7. Contact removal permission

| | Option |
|---|---|
| A | `vendor_core.update` (editing the vendor) |
| B | `vendor_core.delete` (1.4 default) |

**Lean: A.** Plant Manager keeps contacts current without holding vendor delete. **Cost to reverse:** low (trigger argument).

## 7. 4.1b preview (decided in 4.1b, listed so 4.1 does not block it)

- **Category tagging (OQ-06 lean):** `category_vendor (tenant_id, category_id, vendor_id)`, 1.4 pattern, `category_config.manage`. Inherited from every ancestor (union, like field definitions G3), not nearest-set like statuses. The role comes from `vendor.roles`, not the tag.
- **Asset links (A5):** new migration, `asset.oem_vendor_id`, `asset.om_vendor_id`, nullable, composite FKs. Write rule on change: vendor active, holds the role, tagged to the asset's category line. Unchanged values stay valid after a vendor is deactivated or untagged. `asset_view` and the list helper gain the two columns; 3.3 form pickers and 3.4 overview fill in.
- **Merge:** `public.merge_vendor(p_from_id, p_into_id)`: union of roles, contacts moved, asset OEM and O&M repointed (and coverage after 4.2), source soft-deleted (`deleted_at`), one audit entry. Needs `vendor_core.delete`. Lives in 4.1b because there is nothing to repoint before the asset columns exist.

## 8. Build plan for 4.1 (after answers)

1. `4_1_vendor`: table, indexes, triggers, policies, grants, `vendor_view`, `check_vendor_values()`.
2. `4_1_vendor_contact`: table, primary-flag trigger, policies.
3. `4_1_field_pattern` (only if V2 b): column, check in the asset and vendor value checks.
4. pgTAP `4_1_vendor.test.sql`: permission steps, `tests.cross_tenant` for both tables, tax keys hidden without `vendor_tax_ids.view` and kept on save, contact visibility, one primary, deactivate (update) works and hard delete is refused, EXPLAIN on the list, unique names.
5. Seed: GSTIN and PAN definitions and a few vendors on the demo tenant.
6. Web: `Vendors.tsx` (list, search, role and active filters, add and edit drawer with contacts, deactivate, vendor fields card), route and nav, i18n, tests. Types regenerated.

## 9. Not in 4.1

Coverage (4.2), "has active coverage" filter and column (4.2), category tagging, asset vendor columns, merge (4.1b), vendor import (import story), vendor row scope (6.1), contact erase action, vendor attachments, saved views on vendors.

---

# Story 4.1b: vendor links (category tags, asset OEM and O&M, merge)

**Status:** done, 24 Oct 2026. Owner accepted every lean on 24 Oct 2026 except B6: the Assets list gets a vendor filter (B6 b). Built in the `4_1b_*` migrations.

**As built (differences from the design below):**
- Another tenant's vendor id fails the asset rule (`23514`, it only finds the current tenant's vendors) before the composite FK.
- The merge drops a stale tag (the source no longer holds the role) instead of repointing it, since `into` may not hold that role.
- The merge's role update on `into` runs the 4.1 vendor checks, so a missing mandatory **vendor** field on `into` blocks the merge with that message (fill it first). Mandatory **asset** fields do not block it.
- The category form sends `oem_vendor_ids` and `om_vendor_ids` only when they changed.
- `/vendors?id=<id>` opens that vendor's panel (the overview link).

**Open items used (lean):** OQ-06: the OEM and O&M pickers offer only vendors tagged to the asset's category line. Admin override later (not built).

**Screen:** `assetly-screens.html` has no tagging tab, no vendor picker and no merge dialog. The Asset detail Coverage card shows "Vendor: [OEM vendor]" (that card is 4.3). New UI follows the 3.7b status picker and the 2.2 card style.

## 10. Category tags [B1] [B2]

- **Storage (lean B1 a):** two arrays on `asset_category`: `oem_vendor_ids uuid[] not null default '{}'` and `om_vendor_ids uuid[] not null default '{}'`. Same reasons as R1 (3.7 status sets): the category policy (`category_config.manage`, `tenant_can_write()`) and its audit trigger already cover writes. No new table or policy. Order means nothing.
- **Check trigger** `private.check_category_vendors()` (definer, fixed `search_path`) when an array changes: no duplicates; every **added** id is a live, active vendor of the same tenant holding that role (`oem` or `om`). Ids already there stay, even after the vendor is deactivated or drops the role (B4).
- **Inheritance (lean B2 a): union up the tree**, like field definitions (G3). A tag on "Electrical" applies to every child. A child cannot remove a parent's tag.
- **Helper:** `private.allowed_vendor_ids(p_tenant_id, p_category_id, p_role) returns uuid[]`, `stable`, definer. One recursive walk up `parent_id` (as `effective_status_ids`), then keeps vendors that are live, active and hold the role. Called once per asset write that changes a vendor, never by the list.
- **Read for the app:** `public.category_vendors(p_category_id, p_role) returns setof uuid` (the helper for the current tenant, needs `category_config.view`), as `category_statuses` in 3.7. The asset form uses it.

## 11. Asset columns and write rules [B3] [B4]

- New migration: `asset.oem_vendor_id uuid null`, `asset.om_vendor_id uuid null`, FKs `(tenant_id, oem_vendor_id) → vendor (tenant_id, id)` (same for O&M). Null default, so staging assets need no backfill. Partial indexes `(tenant_id, oem_vendor_id) where oem_vendor_id is not null and deleted_at is null` (and O&M) for the merge and the "in use" counts.
- Grants: both join the asset **insert and update** grants (plain form fields, like `parent_asset_id`).
- **Rule trigger** `private.check_asset_vendors()`, before insert or update of the two columns, definer. For each column whose value is **new or changed** (not null):
  1. the vendor is live and active,
  2. it holds the column's role: `oem_vendor_id` needs `oem`, `om_vendor_id` needs `om` (lean B3 a),
  3. it is in `allowed_vendor_ids(asset's category, role)` (OQ-06).
  Error `23514`, mapped to the field by the form. Runs for every writer (UI, API, later imports), user or not: data rules, not permission rules. A cross-tenant id already fails the composite FK.
- **Unchanged values stay valid (lean B4 a):** a category change, a removed tag, a deactivated vendor or a dropped role keeps existing links. Same rule as custom values (§4.1.4 of goal 3, G4). The form shows the current vendor as an extra option marked "Not tagged" or "Inactive"; picking another must pass the rules. Staging has no links yet, so B4 is cheap to change.
- **Mandatory (2.5):** vendor columns do not join `required_asset_fields` in 4.1b.
- **Soft delete guard:** a vendor soft delete is refused at commit while a live asset links to it (deferred constraint trigger; use `merge_vendor`). Deactivate is not affected. The Vendors screen has no delete button today.

## 12. Reads [B5] [B6]

| Where | Change |
|---|---|
| `asset_view` | Appends `oem_vendor_id`, `om_vendor_id` (ids only, lean B5 a). No join, so the list plan stays the same |
| Names | The app reads `vendor_view?id=in.(...)`, so `vendor_core.view` applies; without it the overview shows "Hidden" |
| `list_assets`, `count_assets` | New last argument `p_vendor_id uuid default null` (owner chose B6 b): `v.oem_vendor_id = X or v.om_vendor_id = X`. Dropped and recreated (signature change, as 3.7). Assets list gets a Vendor filter select; saved views keep `vendor_id` in `filters` |
| 3.3 form | OEM and O&M selects: ids from `category_vendors(category, role)`, names from `vendor_view`, plus "None". Refreshed when the category changes; the current value is kept and marked (B4) |
| 3.4 overview | Vendor names linked to the Vendors screen (opens that vendor's drawer). "Inactive" tag when inactive |
| Audit tab | `oem_vendor_id` and `om_vendor_id` lines show vendor names; an id not in `vendor_view` shows "Former vendor" |
| Category form | A "Vendors" section below Statuses: two multi-selects, OEM and O&M, each listing active vendors with that role. Under each, read-only "Inherited from <parent>: names" |

## 13. `public.merge_vendor(p_from_id uuid, p_into_id uuid)` [B7] [B8]

`security definer`, plpgsql, `search_path = ''`. One transaction, in this order:

1. **Checks:** both ids in the current tenant, live, different; `into` active; `vendor_core.delete` (lean B7 a); `tenant_can_write()`. Both rows locked `for update`. Else `42501` (permission) or `22023`.
2. `into.roles` = union of both roles.
3. `from` soft-deleted (`deleted_at`, `updated_by`).
4. Contacts: `vendor_id` set to `into`; a moved primary loses `is_primary` when `into` has one.
5. Category tags: in both arrays `from` is replaced by `into`, duplicates removed (one update).
6. Assets: `oem_vendor_id` and `om_vendor_id` from `from` to `into`.
7. **4.2 hook:** the coverage repoint goes here as one more `update ... set vendor_id = p_into_id where vendor_id = p_from_id`.
8. One `audit_log` row: `action = 'merge'`, `table_name = 'vendor'`, `record_id = from`, `new_data = {into_id, contacts, categories, assets}` (counts), and one outbox event `vendor.merged`. The row triggers also write their rows, same `transaction_id`.

- **Rules during the merge:** the asset rule (§11) treats a change **away from a soft-deleted vendor** as the merge repoint and checks only that the new vendor is live and active (role and tag hold by steps 2 and 5; a stale link stays stale, as B4). The 2.5 mandatory check skips the same case, so an asset missing a mandatory field cannot block a merge. Only the merge can create that state: step 3 runs before step 6, and the soft-delete guard (§11) blocks it anywhere else. `check_asset_values` is replaced with that one condition added, as 3.5 and 3.7 did. The soft-delete guard is a **deferred** constraint trigger (checked at commit), so step 3 passes: by commit, step 6 has repointed every asset.
- **What `into` keeps (lean B8 a):** its own name, code, contact basics and custom values. `from`'s values stay on the soft-deleted row and in the audit log.
- **Merge dialog** (Vendors drawer, shown with `vendor_core.delete`): pick the active vendor to merge into, then a confirm that lists what moves: roles added, N contacts, N categories, N assets (head counts read by the app). One "Merge" button.

## 14. Permissions [B9]

- Tags: `category_config.manage` (lean B9 a).
- Pickers: whoever can write the asset (`asset_core.create` or `update`), reading with `category_config.view` and `vendor_core.view` (every starter group has both).
- Merge: `vendor_core.delete` (Tenant Admin in the starter grid).
- No new domain or operation. No starter grid change.

## 15. DECIDE

| # | Question | Options | Lean | Cost to reverse |
|---|---|---|---|---|
| B1 | Where tags live | **a)** Two arrays on `asset_category` (`oem_vendor_ids`, `om_vendor_ids`). **b)** Link table `category_vendor (tenant_id, category_id, vendor_id, role)`, 1.4 pattern, own policies and `tests.cross_tenant`. **c)** Link table without role (role read from `vendor.roles`, the §7 preview) | a. R1 precedent: no table, policy or cross-tenant test; category audit covers it; merge is one update. Per-role tags let Siemens be OEM for motors and O&M for compressors | Medium: a to b is a data copy |
| B2 | Inheritance | **a)** Union up the tree (G3, §7 preview). **b)** Nearest set, like statuses (own tags replace the parent's). **c)** Own category only | a. Tag once on a parent; children rarely need fewer vendors | Low: one helper body |
| B3 | Roles per column | **a)** OEM column needs `oem`, O&M column needs `om`. **b)** Any role in either | a. That is what the roles are for (V3) | Low |
| B4 | Category change, tag removed, vendor deactivated, role dropped | **a)** Keep the link; the form marks it. **b)** Refuse the change while linked. **c)** Clear the link | a. Edits never fail on an old link; history stays true; same as G4 | Low (no links on staging yet) |
| B5 | Vendor name in `asset_view` | **a)** Ids only; the app reads names from `vendor_view`. **b)** Names joined in the view | a. List plan unchanged; names stay under `vendor_core.view` | Low |
| B6 (chose b) | Vendor filter on the Assets list | **a)** Not now. **b)** `p_vendor_id` in `list_assets` | a. Not asked; 4.4 adds the coverage column | Low (additive argument) |
| B7 | Who may merge | **a)** `vendor_core.delete`. **b)** New operation `vendor_core.merge`, Tenant Admin | a. Merge ends in a soft delete; same people | Low (seed row plus one check) |
| B8 | Values on merge | **a)** `into` keeps its own; `from`'s stay on the soft-deleted row. **b)** Fill `into`'s empty fields and custom keys from `from` | a. No guessing which value is right; nothing lost | Low |
| B9 | Who tags | **a)** `category_config.manage`. **b)** `vendor_core.update` | a. Tags sit on the category row, like statuses | Low (policy) |
| B10 | Split | **a)** One story, one PR. **b)** 4.1b tags, columns, pickers, overview; 4.1c merge and dialog | a. 3 migrations, one test file, four small UI changes; merge design is settled here | None |

## 16. Build plan (after answers)

Migrations:
1. `4_1b_category_vendors`: the two arrays, `check_category_vendors()`, `allowed_vendor_ids()`, `category_vendors()`.
2. `4_1b_asset_vendors`: columns, FKs, indexes, grants, `check_asset_vendors()`, the soft-delete guard, `asset_view` columns, the `check_asset_values` merge condition.
3. `4_1b_merge_vendor`: the function.

pgTAP `4_1b_vendor_links.test.sql`: tag check (other tenant, inactive, wrong role, duplicate) and permission (view only, manage, read-only tenant); inheritance (own, parent, grandparent, sibling not); asset rules refuse wrong role, inactive, untagged, cross-tenant (FK), on insert and on a plain update; unchanged link kept after category change, untag and deactivate; hidden custom keys kept on a vendor-only save; vendor soft delete refused while linked; merge: roles, contacts (primary), tags deduplicated, assets repointed, source soft-deleted, merge audit row and outbox; refused cross-tenant, without `vendor_core.delete`, on a read-only tenant, into inactive, from = into; an asset missing a mandatory field does not block a merge; EXPLAIN `list_assets` by name still walks the keyset index; tenancy guard green.

Web: category form Vendors section, asset form pickers, overview names and links, audit labels, Merge dialog, i18n, tests. Types regenerated.

## 17. Not in 4.1b

Admin override of the tag rule (OQ-06 later), supplier column on asset, mandatory vendor fields, a "tagged in" list on the Vendors screen, coverage (4.2).

---

# Story 4.2: coverage table and status derivation

**Status:** done (owner accepted, 27 Oct 2026). Owner accepted every lean, C1 to C10, on 24 Oct 2026. Built in the `4_2_*` migrations, tests in `4_2_coverage.test.sql`.

**As built (differences from the design below):**
- The OQ-26 rule lives in one definer helper, `private.coverage_visible(coverage_id)`, used by the `coverage` select and update policies, the `coverage_asset` insert policy and `coverage_view`. Definer because the "no assets yet" half must count links the user cannot see. It runs per contract row (one or two index probes); inline it in `coverage_view` if the Coverage page counts get slow.
- `asset_coverage()` starts from a materialized list of the page's links (asset index), then reads `coverage_view` by id, so it never walks every contract of the tenant. It has no `set search_path` so Postgres can inline it (4.4 joins it into the list); every name is schema-qualified.
- `coverage_asset` rows are insert and soft delete only (update grant: `deleted_at`, `updated_by`). A link needs a live asset and a live contract (trigger, every writer).
- **C3 makes open-items §5 out of date:** "contracts have scope lines ... with no per-asset rows" no longer holds for Phase 1.

**Reads with:** KB §2 (glossary: "out of warranty" = no active warranty-type coverage today), §5 (coverage as its own entity), §6.6, §12; `security-model.md` §4; OQ-05, OQ-26, OQ-27, doc changes #5 and #8; [data-model-goal3.md](data-model-goal3.md) §5, §6, §13, §17; spike §6; §13 above (merge).

**Open items used (lean):** OQ-05 (no exclusions), OQ-26 (see a contract if you see one covered asset), OQ-27 (hook only).

**Already in the catalog (1.2 seed, 1.6 grid):** `coverage_contract` (entity: view, create, update, delete) and `coverage_values` (field: view, update). `field_definition.entity` already allows `'coverage'`. Grid: Tenant Admin all, plus values view and update; Plant Manager view, create, update, plus values view; Planner view, create, update; Technician view; Auditor view, plus values view. **No new domain, operation or grid change.** Contract values are hidden from Planner and Technician.

**Screens (built in 4.3 and 4.4):** Coverage page: cards Active, Expiring in 60 days, Expired; tabs All, Warranty, AMC, Expiring; columns Type, Asset, Vendor, Start, End, Status ("Expires in 24 d"); doc change #5 adds Scope. Asset detail card: "Warranty Active to [End]", "AMC None", "Vendor". Assets list column: "Warranty · 8 mo", "AMC · 24 d", "Out of coverage", "None".

## 18. `coverage` (public, 1.4 pattern)

| Column | Type | Notes |
|---|---|---|
| id, tenant_id, std | | Standard, `unique (tenant_id, id)` |
| coverage_type | text not null | [C1] `check in ('warranty', 'extended_warranty', 'amc', 'other')`. Labels from i18n |
| vendor_id | uuid not null | Composite FK `(tenant_id, vendor_id) → vendor`. Rule on change [C2] |
| reference | text null | Contract or warranty card number, 1 to 100 chars |
| start_date, end_date | date not null | `check (end_date >= start_date)`. Both days are covered (inclusive). Plain dates; "today" is the tenant's (§21) |
| contract_value | numeric(19, 4) null | `>= 0`. Domain `coverage_values`, masked (§20) |
| contract_currency | text null | ISO 4217 shape. `check (contract_value is null or contract_currency is not null)`, as asset purchase value. No conversion |
| renews_coverage_id | uuid null | [C5] Composite FK → `coverage`, not itself. A renewal is a new row |
| notes | text null | |

- Triggers: `set_updated_at`, `check_soft_delete('coverage_contract', 'delete')`, `audit_row('data')`, `private.check_coverage()`: vendor rule (C2), and a change of value or currency needs `coverage_values.update` (as 3.3 does for purchase value).
- Indexes, partial `where deleted_at is null`, tenant first: `(tenant_id, end_date, id)` (Coverage page sort, expiring), `(tenant_id, vendor_id)` (merge, vendor counts).
- Not on the row: custom values (the entity is allowed; the column and check come when a tenant needs a field), attachments [C8], exclusions (OQ-05).

## 19. Scope: `coverage_asset` [C3]

| Column | Type | Notes |
|---|---|---|
| id, tenant_id, std | | Standard |
| coverage_id | uuid not null | Composite FK → `coverage` |
| asset_id | uuid not null | Composite FK → `asset`. The asset must be live when added |

- Unique `(tenant_id, coverage_id, asset_id) where deleted_at is null`; index `(tenant_id, asset_id) where deleted_at is null` (the per-asset lookup).
- Adding or removing an asset edits the contract: insert, update and soft delete need `coverage_contract.update` and `tenant_can_write()` (like V7 contacts). The writer must see the asset (`with check` exists in `asset_view`), because FK checks ignore RLS.
- Rows, not an array on `coverage`: one AMC can list hundreds of assets, and "coverages of asset X" needs an index on the asset.
- No cascade to child assets (OQ-07 lean).

## 20. Visibility (OQ-26) and masking

- **Rule:** a user sees a coverage row when they hold `coverage_contract.view` and **either** at least one of its live assets is in `asset_view` for them, **or** it has no live assets yet (a contract being set up; it shows no asset data) [C4].
- **Through `asset_view`**, not the asset table: `exists (select 1 from coverage_asset ca join asset_view av on av.id = ca.asset_id where ca.tenant_id = c.tenant_id and ca.coverage_id = c.id and ca.deleted_at is null)`. `asset_view` already holds the tenant, `asset_core.view` and live-row checks, and 6.1 adds its scope clause there once; coverage follows with no change.
- The same clause is in the `coverage` select policy (so updates and `returning` agree) and in `coverage_view`. `coverage_asset` select: tenant, `coverage_contract.view`, and its asset in `asset_view`.
- **Cost:** one index probe on `(tenant_id, coverage_id)` per coverage row, stopping at the first visible asset (primary key lookup). Thousands of contracts per tenant read in a few ms. Worst case: a contract with many assets of which none is visible (narrow 6.1 scope) probes all of them. Measure in 6.1 with the spike data (spike §6). A set form (`id = any (visible_coverage_ids())`) would read every contract of the tenant on every query, so it is worse here.
- **`public.coverage_view`** (owner-run, not `security_barrier`, like `asset_view`): the rule above, live rows only, `contract_value` and `contract_currency` as `case when (select private.has_permission('coverage_values', 'view')) then ... end`, plus a computed `status` (§21). The base table grants `select` on every column except the two value columns. Writes go to the base table.

## 21. Status derivation (live, nothing stored) [C6] [C7]

- **Today:** `private.tenant_today()`, stable: `(now() at time zone tenant.time_zone)::date` for the current tenant. Used as `(select private.tenant_today())`, once per statement.
- **N days:** `tenant.coverage_expiring_days smallint not null default 60 check (between 1 and 365)`. `update_tenant_settings` gets one more argument (last, default null = keep). The settings screen field is 4.3.
- **Per coverage** (`coverage_view.status`):

| Status | Rule |
|---|---|
| `future` | `start_date > today` |
| `active` | `start_date <= today and end_date >= today + N` |
| `expiring` | `start_date <= today and end_date between today and today + N - 1` |
| `expired` | `end_date < today` |

  Start today is active. End today is still covered (expiring). End yesterday is expired.
- **Per asset, per group** [C6]. Groups: `warranty` (warranty and extended warranty: the KB "warranty-type"), `amc`, `other`. `public.asset_coverage(p_asset_ids uuid[])`: invoker, stable, reads `coverage_view` joined to `coverage_asset` with `ca.asset_id = any (p_asset_ids)`. One row per asset and group: `asset_id, coverage_group, status, coverage_id, vendor_id, start_date, end_date`. Best row wins: active, then expiring, then future, then expired; among equals the latest end (future: the earliest start).
  - **Never covered** (doc change #8): no row comes back for that asset and group, because no live coverage of that group was ever linked. **Expired:** rows exist, none active, expiring or future today. **Future:** only contracts not started yet.
  - 4.3 (detail card) and 4.4 (list column) call it once per page with the page's ids. 4.4 picks the line it shows from the groups and adds the list filter (a set-form id helper in `asset_list_where`, like search).
  - **Responsible vendor (review point):** the `vendor_id` of the best row. OQ-27 precedence (most specific scope) is a Phase 2 hook: with asset-wise rows every row is equally specific.
- Live, not stored: no `pg_cron`, plain SQL, right at midnight in each tenant's zone. A stored daily status needs a job per time zone and is stale between runs.

## 22. Events [C9]

- `coverage.*` and `coverage_asset.*` row events come from the existing audit trigger, in the same transaction.
- `coverage.expiring` and `coverage.expired` (KB §6.6) need a daily job and have no reader before the notifications goal. Hook: a `pg_cron` job then writes one event per coverage per threshold (dedupe on `coverage_id, status, end_date`). Not built.

## 23. Vendor merge and vendor delete

- `merge_vendor` (§13 step 7): `create or replace` in a new migration with one added `update public.coverage set vendor_id = p_into_id, updated_by = auth.uid() where tenant_id = v_tenant_id and vendor_id = p_from_id` (soft-deleted coverages too, like assets), and `coverages` in the audit and outbox payloads. The C2 rule passes: `into` is live and active.
- The 4.1b soft-delete guard (`check_vendor_unlinked`, deferred) also refuses while a live coverage points at the vendor.

## 24. DECIDE

| # | Question | Options | Lean | Cost to reverse |
|---|---|---|---|---|
| C1 | Coverage types | **a)** System codes `warranty, extended_warranty, amc, other`, text with check. **b)** Tenant data table | a. Types drive logic ("out of warranty" = the warranty group), like vendor roles (V3) | Medium once data exists |
| C2 | Vendor rule | **a)** Vendor required, live and active when set or changed; no role or tag rule. **b)** Role by type: warranty needs `oem`, AMC needs `om`. **c)** b plus the 4.1b category tag for every covered asset | a. Dealers give warranties, third parties sell extended warranties; a wrong refusal blocks real data. The tag rule does not fit a contract over many categories. b is one trigger line later | Low |
| C3 | Scope | **a)** Asset-wise rows only (`coverage_asset`). **b)** Scope lines (asset, category, location subtree, company) resolved live through the closure and the category walk. **c)** b, expanded into asset rows by triggers | a. Indian AMCs list machines by serial; visibility, status and the list filter stay one index probe. **Note:** open-items §5 says "contracts have scope lines ... with no per-asset rows" (section A). a reverses that for Phase 1; b can come later as a second table feeding the same `asset_coverage()` | High once scope lines hold data; low the other way |
| C4 | Contract with no assets | **a)** Visible to `coverage_contract.view`. **b)** Hidden until an asset is linked (the creator loses it after insert). **c)** At least one asset required (deferred check; create through an rpc) | a. Plain table writes keep working; the row shows no asset data | Low |
| C5 | Renewal | **a)** New row with `renews_coverage_id`. **b)** Edit dates in place (history only in audit) | a. The old period stays true for past claims; the link shows the chain | Low (nullable column) |
| C6 | Asset status | **a)** Per group: warranty (with extended), AMC, other. **b)** One overall status | a. KB defines "out of warranty" per type; the detail card shows warranty and AMC lines. Overall = best of the groups, in the app | Low (function body) |
| C7 | Status | **a)** Live (view column and function, tenant time zone). **b)** Stored, refreshed daily by `pg_cron` | a. Portable, no job, never stale. 4.4's filter uses the set form; measure then | Low |
| C8 | Contract PDFs | **a)** Hook: reuse the 3.6 pattern later (path `<tenant>/coverage/<id>/<att>`; the storage policies then take a second entity). **b)** Now | a. Storage policies are an owner-review area and not in the story | Low |
| C9 | Expiry events | **a)** Hook (§22). **b)** Daily job now | a. No reader until notifications | Low |
| C10 | Split | **a)** One story: 2 tables, view, `asset_coverage`, setting, merge and guard. **b)** 4.2 tables, visibility, masking, merge; 4.2b status, setting, function | a. Status is one case and one function, and the story name includes it | None |

## 25. Build plan (after answers)

Migrations:
1. `4_2_coverage`: `tenant.coverage_expiring_days`, `tenant_today()`, `coverage`, `check_coverage()`, `coverage_asset`, policies, grants, `coverage_view`, `update_tenant_settings` with the new argument.
2. `4_2_asset_coverage`: `public.asset_coverage(uuid[])`.
3. `4_2_merge_vendor_coverage`: `merge_vendor` and the soft-delete guard with coverage.

pgTAP `4_2_coverage.test.sql`: permission steps on both tables; `tests.cross_tenant` for both; OQ-26 (unseen asset hides the contract, one visible asset shows it, no assets shows it); value masked without `coverage_values.view`, change refused without `update`; vendor rule (inactive, other tenant); end before start refused; status: start today, end today, end yesterday, future start, end at today + N, no rows = never covered, overlapping warranty plus AMC, extended warranty in the warranty group, time zone boundary (same UTC moment, two tenant zones); merge repoints coverage, vendor delete guard; EXPLAIN `asset_coverage` for 50 ids uses `(tenant_id, asset_id)`; tenancy guard green. Types regenerated. No UI.

## 26. Not in 4.2

Coverage screen, asset Coverage tab, settings field, "Active coverages" on Vendors (4.3); list column and filter (4.4); scope lines and exclusions (C3, OQ-05); OQ-27 precedence; expiry events and job; contract PDFs; coverage custom fields.

---

# Story 4.5: coverage term and warranty on Add asset

**Status:** done (owner accepted, 27 Oct 2026). Owner accepted the leans W1 to W4 and W6 on 27 Oct 2026, and chose **W5 b**: the block has an optional extended warranty line, with the same term select and End override. Built in migration `4_5_create_asset_with_warranty`, tests in `4_5_asset_warranty.test.sql`.

**As built (differences from the design below):**
- The RPC is `create_asset_with_warranty(p_asset jsonb, p_coverages jsonb)`: `p_coverages` is an array of one or two lines, each `{coverage_type, vendor_id, reference, start_date, end_date}`. Type must be `warranty` or `extended_warranty`; any other key is refused (`22023`), so a contract value cannot slip in.
- The extended line starts the day after the warranty End, and follows it until the user edits its Start. Its vendor defaults to the warranty vendor.
- The term select keeps two flags, `startByHand` and `endByHand` (§27). `startByHand` is what stops a follow (purchase date, warranty End) once the user typed a Start.

**Why:** owner UX request after the 4.3 review. Add asset asks for purchase date and OEM, then the coverage form asks again for start and end dates.

**Reads with:** §11 (OEM rules), §18 to §21 (coverage, C2, `coverage_asset`, visibility, `asset_coverage`), [data-model-goal3.md](data-model-goal3.md) §14 (3.3 write path: direct insert under RLS, column grants, `check_asset_values`), §2 (tag A1), §18 (create statuses), the fiscal-year lock (`3_1_fiscal_year_lock`).

**Open items used (lean):** none new. C2 a (vendor live and active, no role rule) still holds for the warranty vendor.

**Screen:** `assetly-screens.html` has no Add asset or coverage form. The block follows the 3.3 card style.

## 27. Term select (coverage form: add, edit, renew)

- A **Term** select next to Start and End: blank ("Custom"), then the months in W2. Every coverage type.
- Picking a term sets End from Start by the W1 rule. Picking blank leaves End as it is.
- **Override:** End stays an editable date. The form keeps one flag, `endByHand`: set when the user types in End, cleared when the user picks a term again.
- **Start changes:** when a term is picked and `endByHand` is false, End is recomputed. Otherwise End stays.
- **Edit:** the term is not stored (W3), so the select starts blank and End shows the stored date. **Renew:** End is prefilled with the old length (4.3, C5), select blank; picking a term recomputes it.
- The term lives only in the form. The database keeps checking `end_date >= start_date`.

## 28. Warranty block on Add asset

- Shown on **create only**, and only with `coverage_contract.create` **and** `coverage_contract.update` (the `coverage_asset` insert policy needs `update`; every starter group with create also has update, so this matches the grid: Tenant Admin, Plant Manager, Planner yes; Technician and Auditor no). Without them the block is hidden and the asset saves as today.
- Closed by default (an "Add warranty" checkbox opens it), so the form stays as short as today.
- Fields: **Term** (same select), **Start** (defaults to the purchase date; when that is empty, the in-service date; follows those fields until the user edits Start), **End** (W1, override as §27), **Vendor** (defaults to the OEM picked above while the user has not changed it; any live active vendor, C2 a), **Reference** (warranty card number, optional).
- Type is always `warranty`. No contract value (W4). Extended warranty: W5.
- Save with the block open calls one RPC (§29). Block closed: the plain insert as today.
- **Edit asset:** no warranty inputs. A read-only line from `asset_coverage([id])`, group `warranty`: "Warranty: Active to 14 Mar 2028 · Open" (link `/coverage?id=<coverage_id>`), or "None". Changing the purchase date later does **not** move coverage dates.

## 29. `public.create_asset_with_warranty(p_asset jsonb, p_warranty jsonb) returns uuid` [W6]

Lean: **security invoker**, plpgsql, `search_path = ''`. One call from the app, so one transaction:

1. `insert into public.asset` with exactly the keys the app sends today (the same payload object as the 3.3 plain insert): `format('insert into public.asset (%s) select %s from jsonb_populate_record(null::public.asset, $1)', cols, cols)`, `cols` = the payload keys through `quote_ident`. An unknown key fails as an unknown column.
2. `insert into public.coverage` (`coverage_type = 'warranty'`, `vendor_id`, `reference`, `start_date`, `end_date`; no value columns).
3. `insert into public.coverage_asset` (the new coverage, the new asset).
4. Returns the asset id.

**Why invoker:** every check is the one the plain inserts already run, so nothing can drift from 3.3 or 4.2: RLS (tenant, `asset_core.create`, `coverage_contract.create`, the link needs `update`, `tenant_can_write()`), the column grants (tag only with `set_tag`, no value columns), `check_asset_values` (mandatory fields, hidden values, create status Active or In Stock), the tag trigger (A1), `check_asset_vendors` (OEM role and tag), `check_coverage` (C2), `check_coverage_asset`. The fiscal-year lock needs nothing: it reads the tenant's assets at the next settings save. Any error rolls back all three inserts. A definer function would bypass RLS and grants and have to repeat these checks by hand.

**Audit and outbox:** the existing row triggers write three audit rows and three outbox events (asset, coverage, coverage_asset created) with one `transaction_id`. No new event.

**Errors:** raised as today, so the 3.3 mapping keeps working. New mappings on the block: a message that **starts** with `vendor_id:` (C2; `oem_vendor_id:` also contains it) → Vendor; the coverage end check → End; RLS on `coverage` or `coverage_asset` → a block message.

## 30. DECIDE

| # | Question | Options | Lean | Cost to reverse |
|---|---|---|---|---|
| W1 | End-date rule for N months | **a)** Day before the same date N months later: 15 Mar 2026 + 24 → **14 Mar 2028**. When that date does not exist, the last day of that month: 31 Jan 2027 + 1 → 28 Feb 2027; 29 Feb 2028 + 12 → 28 Feb 2029. **b)** Same date N months later (15 Mar 2028), clamped to month end | a. Common OEM practice; both days are covered (§18, inclusive), so b gives one day extra | Low: app only, stored ends unchanged |
| W2 | Months in the list | **a)** 3, 6, 12, 18, 24, 36, 48, 60. **b)** 6, 12, 18, 24, 36, 48, 60 | a. Short AMCs and spares warranties of 3 months exist | None: one constant |
| W3 | Store the term | **a)** No; End is the truth. **b)** `coverage.term_months smallint null` | a. End may be overridden, so a stored term can disagree with it; renew already copies the length | Low (nullable column later) |
| W4 | Contract value on the block | **a)** Not shown. **b)** Shown with `coverage_values.update` | a. Keeps the block light; value can be added on the Coverage page | None |
| W5 | Extended warranty | **a)** Standard warranty only. **b)** A second optional line (type `extended_warranty`, start defaults to the day after the warranty ends) | **Owner to choose.** Lean a: often bought later or from another vendor; the Coverage page has it | Low (UI and one more insert) |
| W6 | Write path | **a)** Invoker RPC doing the plain inserts (§29). **b)** Definer RPC repeating every check. **c)** Two app calls (asset, then coverage) with cleanup on failure | a. One transaction, no copied checks, no drift. c can leave a half save | Low: function body |

## 31. Build plan (after answers)

1. Migration `4_5_create_asset_with_warranty`: the function, `grant execute ... to authenticated`.
2. pgTAP `4_5_asset_warranty.test.sql`: asset, coverage and link created together; inactive vendor and missing mandatory field each roll back both; without `coverage_contract.create` refused while the plain asset insert works; cross-tenant vendor and category refused; end before start refused; three audit and outbox rows with one `transaction_id`; tag generated; a value key in the warranty refused; tenancy guard green.
3. Web: term select and `endByHand` in the coverage form; `addTerm(start, months)` helper with tests (W1, month end, leap year); Warranty block on Add asset (gating, start default, OEM vendor default, one RPC call, error mapping); warranty line on Edit asset; i18n. Types regenerated.

## 32. Not in 4.5

AMC on the asset form (AMCs cover many assets: Coverage page), default warranty term per category (parked by the owner), contract value on the block (W4), moving coverage when the purchase date changes.

---

# Story 4.4: coverage column, coverage filter and filter panel on the Assets list

**Status:** in review, 27 Oct 2026. On 27 Oct 2026 the owner widened the story to add a collapsible filter panel. After the measurements in §34, the owner asked for a **stored coverage state per asset** in place of the live filter that §21 planned. C7 a (live status) still holds everywhere else. The owner accepted every lean, C11 to C17, on 27 Oct 2026. Built in migration `4_4_asset_coverage_state`, tests in `4_4_asset_coverage_state.test.sql`.

**As built (differences from the design below):**
- The queue for a change of N or time zone (C15) is a cursor, `tenant.coverage_refresh_after uuid`, not a boolean. The job walks the tenant's assets by id from it, and null means nothing is queued. That lets a large tenant finish over several runs.
- Contract insert has no trigger: a new contract has no links yet, and the link insert refreshes the asset. The triggers are statement level with transition tables, so linking an AMC to many assets in one statement makes one refresh call.
- `check_asset_values` and `audit` are split into an insert trigger (no guard, since there is no OLD row) and a guarded update trigger (`check_asset_values_update`, `audit_update`). `set_updated_at` keeps its name and gets the guard.
- The job runs for at most 4 minutes per call (`p_budget`). It stops early on a batch that changes nothing.
- **Write cost:** a state change rewrites every asset index, because the state is indexed, so the update cannot be HOT. That is about 1 ms per changed asset at 200k. The job only writes assets whose state or until changes; see §34 for the numbers.

**Reads with:** §17 (screen), §18 to §21 (coverage, `asset_coverage`, live status, `coverage_expiring_days`), §27 to §32 (4.5); [data-model-goal3.md](data-model-goal3.md) §8 (keyset indexes), §13 (`list_assets`, `asset_list_where`, saved views), §14 (column grants); spike 1.7 §3 and §6.

**Open items used (lean):** none new. OQ-26 (contract visibility) shapes C13.

## 33. What the list shows and filters (no choice left; follows §17 and §21)

- **Column "Coverage"** (screens file): of the groups that cover the asset today, the one that ends first, so the most urgent of warranty, AMC and other. Ties go warranty, then AMC, then other. Texts:
  - "Warranty · 8 mo" when active: whole months left, at least 1.
  - "AMC · 24 d" or "AMC · today" when expiring.
  - "Out of coverage": contracts exist, but none covers today (all expired, or only future ones).
  - "None": never covered (doc change #8).

  Tones: active ok, expiring warn, out error, none neutral. The column reads `asset_coverage(page ids)` once per page (§21). It is live, so it is exact. It shows only with `coverage_contract.view`.
- **Filter "Coverage"**: one overall value per asset, by the same rule as the column. It shows only with `coverage_contract.view`. Values:
  - **Active**: covered, and the group that ends first ends on or after today + N.
  - **Expiring**: that group ends before today + N.
  - **Out of coverage.**
  - **Never covered.**

  Saved views store the value as `filters.coverage`. Views saved before 4.4 have no such key and load as before. An unknown value is dropped when a view loads.
- **Filter panel** (owner request, 27 Oct 2026; built; UI only, no schema):
  - Closed by default. The search box stays visible.
  - A "Filters · 2" button (`aria-expanded`, `aria-controls`) opens and closes the panel. Focus moves into the panel when it opens and back to the button when it closes.
  - While the panel is closed, the active filters show as chips with ×, plus "Clear all".
  - Open or closed is kept per browser in `localStorage`, inside try/catch, so the page works with storage blocked.
  - At phone width (< 768 px) the panel is a bottom sheet (`role="dialog"`). Esc, the backdrop and Apply close it.
  - Saved views sit next to the Filters button.

  **Clash with the screens file:** the screen shows the filter chips always open, in one row. The owner's request wins.

  **Choices made in the build, for the owner to confirm:**
  - Sort moved into the panel.
  - "Clear all" clears the panel filters and keeps the search text.
  - On a phone, filters apply as they are picked, so Apply only closes the sheet.
  - A phone never reopens the sheet when the page loads.

## 34. Measurements: the live filter of §21 does not scale (local Docker, p50, planner.a)

**Data:** tenant A with N assets. 60% have a warranty, with ends spread over 1,000 days. 20% are in AMCs of 100 assets each. That makes 0.8 links per asset.

**A** is §21 as planned: a set-form id helper, `private.coverage_asset_ids()`, computed once per statement and probed by a hashed subplan. The list still walks `asset_name_idx` with no sort. **B** is a prototype stored state: a column on `asset` with index `(tenant_id, coverage_state, name, id)`.

| Query | A, 200k | A, 1M | B, 200k | B, 1M | Target (spike §2) |
|---|---|---|---|---|---|
| List page, coverage filter | 270–915 ms | 1,400–2,360 ms | 1.5–2 ms | 2–4 ms | 100 ms |
| Count (capped 10,001), coverage filter | 250–500 ms | 1,700–2,540 ms | 5–30 ms | 11–160 ms | 200 ms |
| List page, no coverage filter | 1.4 ms | 1.1 ms | | | |
| Column, `asset_coverage` for 50 ids | 31 ms | 28 ms | | | |

**As built** (`4_4_asset_coverage_state`, same data, same machine, p50):

| Query | 200k | 1M |
|---|---|---|
| List page, coverage filter (any sort, page 1 or deep) | 2.0–4.5 ms | 1.2–2.4 ms |
| Count (capped 10,001), coverage filter | 5.5–11.5 ms | 4.4–5.3 ms |
| Column, `asset_coverage` for 50 ids | 31–160 ms (noisy) | 42 ms |
| Trigger: link one AMC to 100 assets in one statement | 666 ms | 373 ms |
| Job, nothing due | 1 ms | 1 ms |
| Job, next day (assets whose state or until changes) | 800 assets, 4.9 s | 3,800 assets, 14.5 s |
| Job, 30 days at once (catch-up) | 15,532 assets, 28 s | 72,328 assets, 150 s |
| Job, whole tenant after a change of N (C15) | 64,688 written, 53 s | 327,052 written, 370 s (two runs at the 4-minute budget) |
| Backfill of a whole tenant (the migration) | 175 s | 731 s |

Writes cost about 1 to 4 ms per changed asset. The update rewrites every asset index, the 64 MB trigram index included. Reads meet the targets with a wide margin at 1M. A tenant that arrives with 1M assets after this migration does not pay the backfill: imports link assets through the triggers.

A reads every link of the tenant on every call, so its cost grows with the tenant. It meets the targets up to about 20k assets (measured: list 40 to 95 ms, count 100 to 190 ms). A naive full recompute of B took 41 s at 200k and 368 s at 1M. So B must refresh only the assets whose state changes (§36), and never the whole tenant each night.

## 35. Stored state on `asset` [C11] [C12] [C13]

New columns, added in a new migration (the `asset` migration is never edited in place):

| Column | Type | Notes |
|---|---|---|
| `coverage_state` | text not null default `'none'` | `check in ('active', 'expiring', 'out', 'none')`. The §33 overall value |
| `coverage_state_until` | date null | The first tenant date on which the calendar alone can change the state. Null when no date can change it (never covered, or only expired contracts) |

- **`coverage_state_until`** is the earliest of these dates, taken over the asset's live contracts:
  - a future contract's `start_date`;
  - a covering contract's `end_date + 1`;
  - a covering contract's `end_date - N + 1` (the day it becomes expiring), when that day is after today.

  Expired contracts add nothing.
- **Indexes:** partial `where deleted_at is null`, tenant first (goal 3 §8), one per list sort, so a filtered page is still a keyset walk with no sort:
  - `(tenant_id, coverage_state, name, id)`
  - `(tenant_id, coverage_state, tag)`
  - `(tenant_id, coverage_state, updated_at desc, id)`

  The job (§36) gets one more: `(coverage_state_until) where coverage_state_until is not null and deleted_at is null`.
- **Writes:** only `private.refresh_coverage_state(p_asset_ids uuid[])` writes the two columns (definer, `search_path = ''`). Users cannot, because the asset column grants (goal 3 §14) do not include them. The function computes the state and `until` set-wise for the given ids, in each asset's tenant time zone and N. It updates only the rows whose values change.
- **No noise from system writes** [C12]: today `set_updated_at`, `check_asset_values` and `audit` fire on every asset update. They are recreated on `asset` with this guard:
  `when ((to_jsonb(old) - '{coverage_state,coverage_state_until}'::text[]) is distinct from (to_jsonb(new) - '{coverage_state,coverage_state_until}'::text[]))`.
  A state refresh then does not move `updated_at` (the "Recently updated" sort), writes no audit row and no `asset.updated` outbox event, and skips the value checks. Every other change fires them as before. The coverage row events (§22) still record what changed.
- **Reads** [C13]:
  - `asset_view` gets `coverage_state`.
  - `list_assets` and `count_assets` add `v.coverage_state = %L` for `p_coverage`. It is a new last argument, default null; the functions are dropped and recreated, as 4.1b did.
  - Without `coverage_contract.view`, the list functions treat a coverage filter as matching nothing, and the UI hides the column and the filter.

## 36. Keeping it right [C14] [C15]

**Event-driven.** Row triggers call `refresh_coverage_state` in the same transaction as the change. So they work for every writer: the Coverage page, the 4.5 RPC, merge, and imports later.

| Change | Assets refreshed |
|---|---|
| `coverage_asset` insert or soft delete | That asset |
| `coverage` insert, soft delete, or change of `start_date`, `end_date` or `coverage_type` | The contract's live linked assets (an AMC: up to hundreds, in one set-wise statement) |
| `asset` insert | None. The default `'none'` is right; the 4.5 RPC links after the insert, and that refreshes |
| `tenant.coverage_expiring_days` or `time_zone` change | The whole tenant, by the job (marked; see below) |

**Calendar-driven: the delta job** [C14]. `pg_cron` runs `private.refresh_due_coverage_states()` every 15 minutes.
- It picks live assets whose `coverage_state_until` is on or before their tenant's today, using the `until` index joined to `tenant` for the time zone.
- It refreshes them in batches of 10,000 per tenant per run.
- It touches only the assets whose state changes that day. With the bench data that is about 0.1% of a tenant per day.

A settings change of N or time zone sets `tenant.coverage_state_dirty = true` [C15]. The job then refreshes that tenant in batches until it is done, and clears the flag.

- **Staleness:** after the tenant's midnight, the filter can lag the column by up to one job interval. For example, an asset that became expiring at 00:00 still filters as active until about 00:15. After a change of N or time zone, a large tenant lags somewhat longer. The column, the detail card and the Coverage page stay live (C7 a) and exact.
- **Backfill** in the migration: every live asset goes through `refresh_coverage_state`, tenant by tenant.
- **Portability:** `pg_cron` is plain Postgres (RDS has it). The job is a definer function, so a future worker can call it instead. It is system work, not user work (CLAUDE.md §6.4).
- **`pg_cron` is new to the project:** the migration runs `create extension pg_cron`. Supabase and the local stack both ship it. The job runs as `postgres` and reads no token, so it passes each tenant explicitly.

## 37. DECIDE

| # | Question | Options | Lean | Cost to reverse |
|---|---|---|---|---|
| C11 | Where the state lives | **a)** Two columns on `asset`, with one index per sort (§35). **b)** A side table `asset_coverage_state`, keyed by asset. **c)** The live set form §21 planned (A in §34) | a. Only a column can share an index with the sort columns, so a filtered page stays a 2 ms keyset walk at 1M. b must either join and sort (100+ ms at 1M) or copy the sort keys. c measured 1.4 to 2.4 s at 1M | Medium: columns, indexes, backfill |
| C12 | System writes and the asset triggers | **a)** `when` guards on `set_updated_at`, `check_asset_values` and `audit` that ignore the two columns (§35). **b)** Let them fire: every refresh moves `updated_at` and writes an audit row and an outbox event | a. b floods the audit log and the future webhooks with machine changes, and breaks "Recently updated". The guard is generic (`to_jsonb` minus two keys), so new asset columns need no change. Owner review: it touches the audit trigger | Low |
| C13 | Who sees the state | **a)** In `asset_view` for `asset_core.view`; the list filter and the UI column only with `coverage_contract.view`. **b)** Masked in the view, like a value field | a. It is one word per asset: no contract, vendor, dates or value. Masking it in the view stops the index being used (the filter would compare a `case` expression), which brings back the slow path | Low |
| C14 | Calendar refresh | **a)** `pg_cron` every 15 minutes, delta by `coverage_state_until`, batches of 10,000. **b)** Once a night per time zone. **c)** Every hour | a. A run with nothing due is one index probe. 15 minutes keeps the lag after midnight short in every time zone | None: schedule only |
| C15 | Settings change of N or time zone | **a)** Mark the tenant; the job refreshes it in batches. **b)** Refresh the whole tenant inside the settings save | a. b would hold the settings save for many seconds at 1M assets | Low |
| C16 | The column | **a)** Live from `asset_coverage()` per page (exact, 30 ms). **b)** From the stored state | a. The column needs the group and the days left, which the state does not hold. One call per page | None |
| C17 | Split | **a)** One story: state, triggers, job, list filter, column, panel. **b)** 4.4 for the column and panel (UI, live column, no filter); 4.4b for the stored state, job and filter | a. The filter is in the story's name and the review point asks for it. The column and the panel are already built and tested | None |

## 38. Build plan (after answers)

1. **Migration `4_4_asset_coverage_state`.** It replaces the unpushed draft `4_4_asset_list_coverage`, which was never applied to staging. Contents:
   - `pg_cron`;
   - the columns, checks and indexes, and `tenant.coverage_state_dirty`;
   - `refresh_coverage_state`, `refresh_due_coverage_states`, and the `coverage` and `coverage_asset` triggers;
   - the guarded asset triggers;
   - `asset_view` with the column;
   - `list_assets` and `count_assets` with `p_coverage`;
   - the backfill and the cron schedule.
2. **pgTAP `4_4_asset_coverage_state.test.sql`:**
   - each state: active, expiring at the N boundary, end today, ended yesterday, only future, never covered, soft-deleted contract, AMC active with warranty expired, extended warranty in the warranty group;
   - every trigger path: link, unlink, contract dates, type, soft delete, an AMC with many assets;
   - the job with a given "now": the state flips at the tenant's midnight in two time zones; nothing due does nothing; batch size;
   - a change of N marks the tenant and refreshes it;
   - a refresh does not move `updated_at` and writes no audit row, while a normal edit still does both;
   - users cannot write the columns;
   - the filter without `coverage_contract.view` matches nothing;
   - cross-tenant;
   - EXPLAIN: for each sort, a filtered page walks its `(tenant_id, coverage_state, ...)` index with no sort;
   - the tenancy guard stays green.
3. **Bench:** re-run the §34 bench at 200k and 1M on the build, and record the numbers here.
4. **Web** (built, kept): column, filter, panel, saved views. Its 19 tests in `Assets.test.tsx` already pass.

## 39. Not in 4.4

Filters per group ("out of warranty" only, AMC only), coverage on the vendor filter, notifications on expiry (C9), a stored state per group.
