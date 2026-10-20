# Goal 2 data model

**Status:** in review, 20 Oct 2026. Owner accepted the leans for G1 to G6 on 20 Oct 2026. Categories part written in story 2.1. The locations part (2.3) is added by that story.

**Purpose:** the category and field definition tables that 2.1 builds and 2.2, 2.5, 3.1 and 3.3 use. Same conventions as [data-model-goal1.md §1](data-model-goal1.md#1-conventions-used-in-every-table): std columns, composite same-tenant FKs, `unique (tenant_id, id)`, RLS on, the 1.4 pattern. Choices that are costly to reverse are marked **[G1]** to **[G6]**, decided, and listed in [section 3](#3-owner-decisions).

---

## 1. Categories

### 1.1 `asset_category` (2.1) [G1] [G2]

| Column | Type | Notes |
|---|---|---|
| id, tenant_id, std | | Standard |
| parent_id | uuid null | Composite FK `(tenant_id, parent_id) → asset_category (tenant_id, id)`. Null means a top-level category |
| name | text not null | Unique per tenant among rows not deleted: `(tenant_id, lower(name)) where deleted_at is null` |
| description | text null | |
| is_active | boolean not null default true | Deactivate, never delete (CLAUDE.md §8). Inactive categories stay on old assets and drop out of pickers |

- **Hierarchy: adjacency list** (`parent_id`), read with a recursive CTE. A tenant has tens to a few hundred categories, so no closure table. A trigger refuses a parent change that would make a cycle.
- `deleted_at` stays (std column) but users do not set it. It is for the later merge function, which repoints assets and soft-deletes the merged category. Today the soft-delete trigger checks `category_config.manage`.
- Depreciation hook (knowledge base §12, "category has a place for a method") is **not** added now. It is one nullable column when Phase 2 needs it.

### 1.2 `field_definition` (2.1) [G3] [G4] [G5] [G6]

| Column | Type | Notes |
|---|---|---|
| id, tenant_id, std | | Standard |
| entity | text not null | `check (entity in ('asset', 'vendor', 'coverage'))`. Which record the value lives on. Vendor GSTIN and PAN are vendor fields (CLAUDE.md §8). A system list, not tenant data |
| category_id | uuid null | Composite FK to `asset_category`. Null = applies to every record of the entity. Set = this category **and its descendants** [G3]. Only allowed when `entity = 'asset'` |
| key | text not null | The JSONB key. `^[a-z][a-z0-9_]*$`, max 63. **Unique per tenant and entity, for all rows, deleted or not** [G4]. Cannot change after insert |
| label | text not null | Shown to users. Tenant data, so not in the i18n file |
| type | text not null | `check (type in ('text', 'number', 'date', 'boolean', 'list'))`. Cannot change after insert. Adding a type later is a one-line check change |
| options | jsonb not null default `'[]'` | For `list`: array of `{"code": "oil", "label": "Oil", "is_active": true}`. Values store the code, so labels can change. Check: array; non-empty if and only if type is `list` |
| unit | text null | For `number`, e.g. `kW`. Display only (knowledge base §5) |
| is_required | boolean not null default false | "Required is a flag on the field definition" (knowledge base §6.3). Checked on save in 3.3. 2.5 adds tenant mandatory rules for core fields |
| sort_order | int not null default 0 | Order on the form. Inherited fields show parent first, then by `sort_order` |
| security_domain_id | uuid not null | FK `(security_domain_id, entity) → security_domain (id, entity)` [G6]. So an asset field can sit in `asset_core` or `asset_financials`, never in `vendor_tax_ids`. The UI defaults to the entity's core domain |
| is_active | boolean not null default true | Inactive: hidden on forms, values kept on records |

- `key`, `entity` and `type` are immutable: the update grant leaves those columns out (column-level grant), so a change is refused with 42501. Changing them would orphan or corrupt values already stored.
- No `field_category` link table [G3]. Reuse across categories is by putting the field on a shared parent, or with `category_id` null.
- No per-category override of `is_required`. Add later if pilots ask.

### 1.3 Policies

Both tables follow the 1.4 pattern with the existing catalog domain **`category_config`** (`view`, `manage`). No new domain is seeded.

| | Rule |
|---|---|
| select | tenant, `has_permission('category_config', 'view')`. All five starter groups have view, so every user can render forms |
| insert, update | tenant, `has_permission('category_config', 'manage')`, `tenant_can_write()` |
| soft delete | trigger `check_soft_delete('category_config', 'manage')` |
| delete | no policy, grant revoked |
| audit | `audit_row('data')` on both |

A user without `asset_financials` can still read that a field definition in `asset_financials` exists (its key and label). Only the **value** is hidden (section 2). Lean: acceptable, labels are not sensitive.

## 2. Values on the record (3.1 builds this, 2.1 only fixes the shape)

- Each entity table gets `custom_values jsonb not null default '{}'`. Keys are `field_definition.key` [G5]. Example: `{"rated_kw": 15, "fluid": "oil", "installed_on": "2024-03-01"}`.
- JSON types: `text` string, `number` number, `date` string `YYYY-MM-DD`, `boolean` true/false, `list` the option code.
- A write function (3.3) checks: every key has an active definition for the record's entity and category line, the value matches the type, required keys are present. Deterministic, in SQL.
- Values of inactive fields stay. Keys are never reused [G4], so an old value never takes a new meaning.
- Index: a GIN on `custom_values` only if 3.2 filtering needs it. Not now.

### Per-key domain filtering (CLAUDE.md §7.7; 3.1 and 6.x build it)

- **Read:** the app reads assets through a secure view. It keeps only the keys whose field domain the user can view:
  `custom_values` filtered by `key = any((select private.visible_field_keys('asset'))::text[])`.
  The helper is set-returning and called once per statement, as the 1.7 spike advises (§6). It joins `field_definition` to `user_effective_permission`.
- **Write:** the 3.3 write function checks `has_permission(<field domain>, 'update')` for each key that changes. Keys the user cannot view are kept as stored, never blanked.
- **AI and exports:** use the same helper, so a hidden key is never offered to the model (CLAUDE.md §11).

---

## 3. Owner decisions

"Cost to reverse" assumes the tables are on staging with real data.

### G1. Table name: `asset_category` or `category`. DECIDED

| Option | |
|---|---|
| A | `asset_category`. Says what it is. Leaves room for vendor or document categories later |
| B | `category`. Shorter. Matches the domain entity name `category` |

**Lean: A. Owner: A.** **Cost to reverse:** rename table, FKs, policies, types, every query. Medium.

### G2. Category hierarchy shape. DECIDED

| Option | |
|---|---|
| A | Adjacency list (`parent_id`), recursive CTE to read, cycle trigger |
| B | Closure table, like locations (2.3) |

**Lean: A. Owner: A.** Categories are few and are not a scope dimension, so no fast "all under X" check per row is needed. **Cost to reverse:** low. A closure table can be built from `parent_id` later without changing it.

### G3. Field to category: one owner category, or a link table. DECIDED

| Option | |
|---|---|
| A | `field_definition.category_id` (null = all). Inherited by child categories. One table |
| B | Field definitions per tenant plus a `category_field` link (knowledge base §5 names a "Category-Field link"). One field reused in many unrelated categories, `is_required` and order per link |
| C | Like A, but no inheritance: a child category does not get its parent's fields |

**Lean: A. Owner: A.** Smallest. Covers the common case (shared fields on a parent). Because keys are unique per tenant (G4), moving to B later is a data copy: one link row per definition. **Cost to reverse:** low to medium.

### G4. Key uniqueness. DECIDED

| Option | |
|---|---|
| A | Unique per tenant and entity, forever (deleted rows keep the key). One key has one meaning and one type across the tenant |
| B | Unique per category line. Two sibling categories can each have `voltage` with different types |

**Lean: A. Owner: A.** Insights, exports, filters and the AI semantic layer need one meaning per key. **Cost to reverse:** high. B to A later means renaming keys inside stored JSONB.

### G5. JSONB keyed by field `key` or by field `id`. DECIDED

| Option | |
|---|---|
| A | By `key` (`{"rated_kw": 15}`). Readable in exports, API, audit diffs. Needs `key` immutable |
| B | By `id` (`{"3f1c...": 15}`). Rename-safe, but unreadable everywhere and every read needs a join |

**Lean: A. Owner: A.** **Cost to reverse:** high, rewrites every stored value.

### G6. Field domain: required, and tied to the entity. DECIDED

| Option | |
|---|---|
| A | `security_domain_id not null`, composite FK on `(id, entity)` so the domain must belong to the same entity. Adds `unique (id, entity)` to `security_domain` (new migration) |
| B | Nullable, null = entity core domain. Every filter does `coalesce` |
| C | Not null, but no entity check |

**Lean: A. Owner: A.** Every key has an explicit domain, and a wrong-entity domain is refused with zero code. Tenants pick only from the platform catalog (no tenant-defined domains in Phase 1). **Cost to reverse:** low for the check, medium to make nullable later.

## 4. Not in 2.1

- UI (2.2). Note for 2.2: `security_domain` is readable only with `users_security.view` (1.3 owner decision), so a category admin without it cannot list domains for the picker. 2.2 needs either a small read function for field domains or a policy change. Owner call then.
- Asset table, `custom_values`, the write function and the secure view (3.1, 3.3).
- Industry templates (Goal 7), depreciation method, field translations, per-category required override, a `money` type.
