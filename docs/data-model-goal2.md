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

- UI (2.2). Note for 2.2: `security_domain` is readable only with `users_security.view` (1.3 owner decision), so a category admin without it cannot list domains for the picker. Owner chose a read function (20 Oct 2026): 2.2 adds `public.field_domains(entity)` (needs `category_config.view`, returns the entity's entity and field domains) and `public.my_permission`, a view of the caller's own grants so the UI can hide actions. Migration `2_2_ui_read_helpers`.
- Asset table, `custom_values`, the write function and the secure view (3.1, 3.3).
- Industry templates (Goal 7), depreciation method, field translations, per-category required override, a `money` type.

---

## 5. Story 2.5: tenant settings and mandatory-field rules

**Status:** design, 20 Oct 2026. Waiting on owner answers to **S1 to S3** and **M1, M2** before any migration or UI work.

### 5.1 Settings: what exists

1.1 already built the four D2 columns on `tenant` (data-model-goal1.md §2.1):

| Column | Today | 2.5 adds |
|---|---|---|
| `currency_code` | `char(3) not null`, no check | Check `^[A-Z]{3}$` |
| `locale` | `text not null default 'en-IN'` | Check `^[a-z]{2,3}(-[A-Z]{2})?$`. Drop the India default (CLAUDE.md §8) |
| `time_zone` | `text not null`, no check | Must be a name in `pg_timezone_names` (IANA). Checked in the S1 action function |
| `date_format` | `text not null`, no check | Check in a fixed list: `dd-MM-yyyy`, `dd/MM/yyyy`, `MM/dd/yyyy`, `yyyy-MM-dd`, `dd MMM yyyy` |
| `fiscal_year_start_month` | missing | **New** `smallint not null`, check 1 to 12 [S3] |

- Locale also drives number format (open-items section A: "number format at company setup"). No separate column.
- Seed and staging values (`INR`, `en-IN`, `Asia/Kolkata`, `dd-MM-yyyy` and `USD`, `en-US`, `America/New_York`, `MM/dd/yyyy`) all pass the new checks.
- Currency is a regex, not an ISO 4217 lookup table. The UI picker lists `Intl.supportedValuesOf('currency')`, so users pick only real codes. A lookup table later is a cheap migration.

**Read:** no change. `tenant_select_member` (1.1) already lets every active member read their tenant row, all columns. Every user needs locale, time zone and date format to show data. The `tenant_settings.view` grant only decides who sees the Settings page.

**Write:** see [S1]. `tenant` keeps **no** update grant for `authenticated`, so `status`, `slug`, `name` and `deleted_at` stay system-only.

**Audit:** `private.audit_row()` reads `tenant_id` from the row. `tenant` has none (its key is `id`) and `audit_log.tenant_id` is not null, so the generic trigger cannot go on `tenant`. The action function writes the audit row and outbox event itself, same transaction, category `'data'`.

### 5.2 Mandatory-field rules

Two kinds of field on the future asset form:

1. **Custom fields** (`field_definition`). `is_required` already exists (2.1) and the 2.2 field form already toggles it. A field on a parent category is inherited by every descendant, `is_required` included (G3). No per-category override (2.1 decision). **Nothing to build for custom fields.**
2. **System fields** (columns on the Goal 3 `asset` table). These need a rule store, and the table does not exist yet. See [M1].

| System fields | Fields (3.1 fixes the final list) | Rule |
|---|---|---|
| Always required | name, category, status | `not null` on the asset table. Not configurable |
| Optional, tenant can make mandatory | serial_number, manufacturer, model, location, purchase_date, purchase_value, in_service_date | The M1 rule store |

Minimal by default (CLAUDE.md §10.3): every optional system field starts **not** mandatory.

**Enforcement (3.3 builds it, 2.5 fixes the shape):**
- In the database, at write time. The 3.3 asset write function (and the Goal 4 import commit) reads the M1 rules plus `field_definition.is_required` for the asset's category line, and refuses a missing value with one error that lists the missing fields.
- The UI marks the same fields required. A hint only.
- Turning a rule on does not recheck old records. It applies on their next save. [M2] covers fields in a domain the user cannot write.

### 5.3 UI

- **Settings page** at `/settings` (the sidebar already has it). There is no Settings screen in `assetly-screens.html` (open-items section D lists it as missing), so it follows the 2.2 and 2.4 card and form style. Shown with `tenant_settings.view`. Editable with `tenant_settings.manage`, read-only otherwise.
  - Card "Regional": currency, locale, time zone, date format (with a sample date), fiscal year start month.
  - Card "Mandatory asset fields": one switch per optional system field (M1 option A).
- **Category field form:** no change. The 2.2 "Required" switch is the custom-field rule.
- No screen formats dates or money with these settings yet: nothing in Goals 1 and 2 shows tenant dates. Goal 3 uses them.

### 5.4 Owner decisions

#### S1. How a settings admin writes. DECIDE

| Option | |
|---|---|
| A | Action function `public.update_tenant_settings(currency_code, locale, time_zone, date_format, fiscal_year_start_month, required_asset_fields)`. Security definer, fixed `search_path`. Checks `tenant_settings.manage` and `tenant_can_write()`, current tenant only, validates the time zone, writes audit and outbox rows. No update grant on `tenant` |
| B | Column-level `grant update (...)` plus an update policy, like `field_definition` (2.1). Needs a tenant-specific audit trigger and a time-zone trigger |

**Lean: A.** One place for permission, checks and audit; the generic audit trigger cannot go on `tenant` anyway. CLAUDE.md §7.8: actions are functions. **Cost to reverse:** low, no data shape change.

#### S2. Can a read-only tenant change settings? DECIDE

| Option | |
|---|---|
| A | No. `tenant_can_write()` applies, like every other write |
| B | Yes. Settings are admin config, not business data |

**Lean: A.** One rule everywhere. **Cost to reverse:** low, one line.

#### S3. Fiscal year start month now. DECIDE

| Option | |
|---|---|
| A | Add `fiscal_year_start_month` now (data-model-goal1.md §2.1 planned it for 2.5). Existing tenants backfilled to 4 (April), then the default is dropped so provisioning must pass it. The "locks after the first asset" rule is a 3.1 trigger |
| B | Leave it until a story uses it (depreciation is Phase 2) |

**Lean: A.** Planned for 2.5, set at company setup (open-items section A), and it must exist before the first asset locks it. **Cost to reverse:** low before assets exist.

#### M1. Where system-field mandatory rules live. DECIDE

| Option | |
|---|---|
| A | `tenant.required_asset_fields text[] not null default '{}'`, check `<@` the optional list above. Tenant-wide. Written through S1 |
| B | Table `mandatory_field_rule (tenant_id, entity, field_code, category_id null)`, per category, inherited like G3. Full 1.4 pattern, cross-tenant tests, UI on the category screen |
| C | Nothing in 2.5. 3.3 decides, with the asset table |

**Lean: A.** Per-category needs are already covered by custom fields on the category. A is one column; B is a table, policies and a screen for a need no pilot has raised. A to B later is a data copy (one row per array item, `category_id` null). 3.1 may change the allowed list with a new migration once the asset columns are final. **Cost to reverse:** low.

#### M2. Mandatory field in a domain the user cannot write. DECIDE

Example: `purchase_value` (domain `asset_financials`) is mandatory, and a Technician without that domain creates an asset.

| Option | |
|---|---|
| A | Refuse the save. That user cannot create assets |
| B | Skip the rule for fields the caller cannot update. The asset saves with the field empty. A later "incomplete records" list can show it |
| C | Refuse to make a field mandatory unless every group that can create assets can write it |

**Lean: B.** Never blocks work on a field the user cannot even see. A is a support trap; C is complex and breaks when groups change. Same rule for custom fields in `asset_financials`. **Cost to reverse:** low, logic in the 3.3 function only.

### 5.5 Build plan (after answers)

Migrations, one purpose each:
1. `2_5_tenant_settings_columns`: the checks in §5.1, drop the `locale` default, add `fiscal_year_start_month` (S3) and `required_asset_fields` (M1).
2. `2_5_update_tenant_settings`: the S1 action function.

pgTAP `2_5_tenant_settings.test.sql`: no grant refused; `view` only refused; `manage` updates; read-only tenant refused (S2); bad currency, locale, time zone, date format, month and field code refused; a direct `update public.tenant` by a manage user is refused (status, name, slug unchanged); the other tenant is untouched; an audit row is written. No new tenant table, so no `tests.cross_tenant` line.

Web: `Settings.tsx` and `Settings.test.tsx` in the 2.4 style, strings in `en.json`, types regenerated.

### 5.6 Not in 2.5

- Asset table, the 3.3 required check, the fiscal-year lock (3.1).
- Formatting dates and money in the UI with these settings (Goal 3, when there is data to show).
- Per-category system-field rules, an ISO 4217 table, a curated locale list, editing the tenant name or logo.
