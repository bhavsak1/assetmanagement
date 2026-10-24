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

**Status:** in review, 24 Oct 2026. Owner accepted every lean on 24 Oct 2026 except B6: the Assets list gets a vendor filter (B6 b). Built in the `4_1b_*` migrations.

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
