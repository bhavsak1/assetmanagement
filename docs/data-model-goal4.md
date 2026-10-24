# Goal 4 data model: vendors (story 4.1)

**Status:** design, 24 Oct 2026. Waiting for the owner on V1 to V7 (section 6). No migration yet.

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

- **Read:** `public.vendor_view` (owner-run, `security_barrier`, like `asset_view`): repeats the base select policy (tenant, `vendor_core.view`, `deleted_at is null`) and returns `custom_values - (select private.hidden_field_keys('vendor'))`. The 3.1 helper already takes the entity. The base table grants `select` on every column except `custom_values`.
- **Write:** `private.check_vendor_values()` before insert or update, the same rules as asset §4.1 checks 2 to 4 and 6: hidden keys kept as stored, changed keys need an active definition, the right type (`private.custom_value_ok`), and `update` on the field's domain; unknown keys refused; `is_required` checked on insert and on data changes. No category line (every vendor field applies to every vendor).
- **Format check** [V2]: only if the tenant set one on the field.
- **Defining the fields:** a "Vendor fields" card on the Vendors page, reusing the 2.2 `FieldForm` (export it from `Categories.tsx`), shown to `category_config.manage` (the existing `field_definition` policies; no policy change). The local seed adds GSTIN and PAN to the demo tenant. A tenant outside India just never adds them.
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

- The Vendors list reads `vendor_view` through PostgREST: `order=name,id`, keyset by `(name, id)`, 50 a page, role filter `roles=cs.{oem}`, active filter.
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
