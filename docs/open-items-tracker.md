# Asset Management Platform: Open Items Tracker

**Purpose:** one place to track every undecided, parked and unvalidated item from the pre-development gap review, so nothing is lost and decisions can be taken after talking to users. Read together with the Knowledge Base, `technical-architecture.md` and `security-model.md`.

**Created:** 11 Oct 2026
**Last updated:** 11 Oct 2026
**Source:** gap review of the Knowledge Base, architecture, security model and screens (sections A to E). Sections A and B are discussed. Sections C, D and E are not yet reviewed (see part 7).

## How to use this file

- Each item has an ID (OQ-nn). Never reuse an ID. Add new items at the end of their part.
- **Status values:** `Open` (needs a decision), `Needs user input` (ask real users first), `Parked` (deliberately set aside), `Phase 2` (agreed to defer), `Provisional` (agreed for now, revisit if users disagree), `Closed` (decided, record the outcome).
- **Needed by** says when the decision blocks work. If it is not decided by then, the **current lean** is used.
- When an item is decided: set the status to `Closed`, fill in **Outcome**, add a line to the change log (part 8), and update the affected document.

---

## 1. Needs user input (ask in customer conversations)

### OQ-01 Quantity or lot assets (from B8)
- **Status:** Needs user input. **Needed by:** before the asset schema in M2 (F5).
- **Question:** are items like chairs, laptops or tools tracked as one lot with a quantity, or individually?
- **Current lean:** a `quantity` field on the asset, default 1, with no splitting or partial transfers in Phase 1. Option: skip lots entirely in Phase 1.
- **Affects:** asset table, import, transfers, asset-count licensing later.
- **Ask users:** "Which of your assets do you count in bulk rather than one by one? Do you ever move part of a lot to another location?"
- **Outcome:**

### OQ-02 QR scan access (from B10)
- **Status:** Needs user input. **Needed by:** token design in M2, feature F21 in M3.
- **Question:** must a person sign in to see an asset after scanning its QR code?
- **Current lean:** login required. The QR carries an opaque token, not the tag or tenant ID. The scan opens the asset only if it is within the user's scope.
- **Alternative:** a public minimal card (name, tag, "contact your admin"). Less friction, but it exposes the tag format.
- **Ask users:** "Would technicians on the shop floor sign in on a phone? Is there mobile data or Wi-Fi at the machines? Would you want a public card?"
- **Outcome:**

### OQ-03 Default schedule anchor for obligations (from B2)
- **Status:** Decided (owner, 27 Oct 2026). **Needed by:** start of M3 (F11).
- **Question:** when a service is done late, does the next due date shift from the actual completion date, or stay on the original calendar?
- **Current lean:** both supported per rule. Default for new rules is "from last completion". Statutory items (boiler, calibration) default to fixed dates.
- **Ask users:** "If a quarterly service is done two weeks late, when is the next one due?"
- **Outcome:** the lean, accepted by the owner on 27 Oct 2026. Each rule picks its anchor: "from last completion" or "fixed dates". New rules default to "from last completion"; statutory items (boiler inspection, calibration) default to "fixed dates". Design: `docs/data-model-goal5.md` §1, §3.

### OQ-04 Reopening disposed assets (from B11)
- **Status:** Needs user input. **Needed by:** M2.
- **Question:** can a disposed or retired asset ever come back?
- **Current lean:** terminal status, reopen only by an admin with a reason, fully audited.
- **Ask users:** "How often does a retired asset come back into use, for example a repaired spare?"
- **Outcome:**

### OQ-05 Contract exclusions
- **Status:** Parked (kept aside for now). **Needed by:** contract schema in M2, only if users need it.
- **Question:** do AMCs exclude specific assets, such as "all HVAC except Chiller 07"?
- **Current lean:** not in Phase 1. It conflicts with the additive-only principle. A short asset-wise contract covers the same need. If needed later, the contract scope line can gain an exclusion flag.
- **Ask users:** "Do your AMCs list machines they do not cover? How do you record that today?"
- **Outcome:**

### OQ-06 Vendor picklist strictness
- **Status:** Needs user input. **Needed by:** M2.
- **Question:** on the asset form, should the OEM and O&M dropdowns be limited to vendors tagged to the category, or should users be able to pick any vendor?
- **Current lean:** limited to tagged vendors, as requested. Possible admin-only override later.
- **Ask users:** "Do you ever buy or service an asset through a vendor that was not set up for its category?"
- **Outcome:**

### OQ-07 Asset hierarchy rules
- **Status:** Needs user input. **Needed by:** M2.
- **Questions:** how deep does a parent and child structure go in practice (current lean: cap at 5 levels)? Should coverage or obligations on a parent apply to its children (current lean: no cascade)?
- **Ask users:** "Do you track components inside machines separately? Does an AMC on the machine cover its components?"
- **Outcome:**

### OQ-08 Coverage intelligence value (Knowledge Base 9.3)
- **Status:** Needs user input. **Needed by:** before committing marketing and pricing.
- **Hypothesis:** "never pay for a repair that was covered, renew AMCs with data" is a headline value for Indian SMEs.
- **Ask users:** "Have you paid for a repair that was under warranty or AMC? How do you track AMC renewals today?"
- **Outcome:**

---

## 2. Product and commercial (open)

| ID | Item | Current lean | Needed by | Status |
|---|---|---|---|---|
| OQ-09 | What counts toward the asset limit (are retired assets counted?) | Not counted | Phase 2 | Phase 2 |
| OQ-10 | Licence grace period length before read-only | To be set (for example 30 days) | Phase 2 | Phase 2 |
| OQ-11 | AI add-on pricing structure, usage limits and metering unit (tokens, rows or questions) | Per-tenant monthly cap, unit to decide | Before M4 (F18) | Open |
| OQ-12 | Pricing tiers, free tier or trial, GST invoicing, per-asset price points ($50 to 150 per month target) | Unverified | Before first pilot | Open |
| OQ-13 | Launch industry templates (suggested 3 to 4 hand-built) | Pick from pilot prospects | M2 (F9) | Needs user input |
| OQ-14 | WhatsApp provider (Gupshup, Twilio or Meta Cloud API), message costs, opt-in consent, template approval | Start onboarding in M2 | M2 start | Open |
| OQ-15 | Regional-language UI priorities (which languages first) | English first, i18n in place | Before pilots | Needs user input |
| OQ-16 | Tenant signup model: self-serve or sales-led, first admin creation, tenant discovery at login | Sales-led for pilots | M1 | Open |
| OQ-17 | How the active tenant is chosen at login for multi-tenant users (last used, picker, or subdomain) | Last used, with a header switcher | M1 | Open |

---

## 3. Technical and security (open)

| ID | Item | Current lean | Needed by | Status |
|---|---|---|---|---|
| OQ-18 | Tenant-level recovery: confirm soft delete plus nightly per-tenant export. Verify whether Supabase can restore PITR into a separate project (not verified) | As stated | Before first paying customer | Open |
| OQ-19 | Backups and PITR add-on budget | Budget before first paying customer | Before first paying customer | Open |
| OQ-20 | Data residency approach for global expansion and the first enterprise deal | Mumbai only for now | Before first enterprise deal | Open |
| OQ-21 | AI model provider(s), fallback, and pricing of the stronger query model (unverified) | Claude primary, second provider as fallback | Before M4 | Open |
| OQ-22 | Policy activation approval: single approver or a separate security administrator | Single approver for pilots | M1 | Open |
| OQ-23 | Token lifetime and permission-version refresh behaviour | Short token, version check on sensitive actions | M1 | Open |
| OQ-24 | Scope dimensions beyond location, category, vendor and criticality | Not needed unless a pilot asks | M2 | Needs user input |
| OQ-25 | Default security domain catalog and starter groups per industry template | Draft in M1 | M1 | Open |
| OQ-26 | Contract visibility rule: a user sees a contract if they can see at least one covered asset | As stated | M2 (domain catalog) | Provisional |
| OQ-27 | Contract precedence for "responsible vendor" when several contracts cover an asset | Most specific scope wins (asset, then category and location, then category or location, then company) | Phase 2 incidents | Phase 2 |
| OQ-28 | Custom service host and framework (Fly.io, Railway, Render, App Runner; Hono, Fastify or NestJS), query layer (Drizzle or Kysely) | Decide at the start of M3 | M3 | Open |

---

## 4. Parked or deferred to Phase 2

| ID | Item | Note |
|---|---|---|
| OQ-29 | SSO (SAML) | Moved to Phase 2. Verify the Supabase plan tier (likely Team, $599 per month) before promising it to anyone. Remove the SSO button from the Phase 1 login screen |
| OQ-30 | Asset-count licensing enforcement, expiry grace period and read-only mode | Phase 2. In M1 only create `tenant_entitlement` (hand-seeded) and add `tenant.status` plus a write-check helper in the RLS policies |
| OQ-31 | Data privacy: DPDP Act position for vendor contacts, DPA with tenants, AI provider zero-retention, data leaving Mumbai, prompt injection from Excel cell text | Deliberately postponed. Revisit before the first paying customer |
| OQ-32 | Currency conversion | Decided: none in Phase 1. Totals show per currency. Revisit if multi-currency tenants need combined totals |
| OQ-33 | Depreciation | Phase 2. Phase 1 only adds nullable capitalisation date and salvage value |
| OQ-34 | Work orders | Phase 2. Needs approval, assignment, labour and parts. Not a no-schema-change step (see part 6) |

---

## 5. Provisionally agreed (section B recommendations)

These were proposed with a recommended default and not objected to. Treat them as agreed unless user conversations say otherwise.

| ID | Decision |
|---|---|
| B1 | Obligations have an owner (user or person) and a default vendor taken from the asset's O&M vendor |
| B3 | Reminder lead times are a list with a tenant default. Postpone or skip needs a reason and is audited. No grace window in Phase 1 |
| B4 | Service records carry certificate number and valid-until, and next due can derive from it |
| B5 | `person` and `department` entities. Custody is an optional field with history. A person need not be a user |
| B6 | Optional `legal_entity` and `cost_center` tables. Locations get a type, address and optional coordinates |
| B7 | Ownership type (owned, leased, rented). A lease is a contract of type Lease using scope lines |
| B9 | Tag numbering: tenant-level pattern with tokens, atomic sequence, unique per tenant, override needs a permission, imports may supply their own tags |
| B11 | Status transitions: In Stock to Active or Disposed; Active to Under Maintenance, Inactive or Disposed; Under Maintenance and Inactive back to Active or to Disposed; Disposed is terminal (see OQ-04). Reason required for Inactive and Disposed |
| B12 | Vendors, locations and categories are deactivated, never deleted. A merge function repoints references with an audit entry |
| B13 | Transfers need transfer rights on both source and destination locations |
| B14 | Nullable capitalisation date and salvage value on the asset |
| B15 | Service record gets a nullable `work_order_id` later |

Also settled in section A: users get all roles in the active tenant combined (no role selection); contracts have scope lines (company, category, location, asset) with no per-asset rows; vendor roles OEM and O&M tagged per category; asset hierarchy is optional; UI, API and AI share the same functions and views; time zone, currency, fiscal year and number format are set at company setup; fiscal year locks after the first asset.

---

## 6. Follow-ups on existing documents and screens

| # | Change |
|---|---|
| 1 | Knowledge Base: reword "service completion record becomes a work order without schema change" (see OQ-34) |
| 2 | Knowledge Base and architecture: move SSO to Phase 2 (F1) and remove it from M1 scope; update the cost cliff note |
| 3 | Knowledge Base, architecture and project notes: remove remaining "NestJS" wording where the architecture now says Supabase-first |
| 4 | Security model: add contract visibility rule, entitlement and tenant status helper, `tenant_membership` |
| 5 | Screens: add In Stock to status filters; vendor roles (OEM, O&M) on Vendors; vendor tagging tab on Categories; OEM and O&M pickers on the asset form; scope column on Coverage; remove the SSO button from Login |
| 6 | Screens: render the Security policy grid from the operations of each domain (Audit log is view only) instead of a fixed View, Create, Update, Delete grid |
| 7 | Screens: hide "Ask Assetly" everywhere when the AI add-on is not licensed |
| 8 | Data model: define "never covered" versus "expired" for the Coverage column |
| 9 | Check the "Assetly" name and domain availability before branding is fixed |

---

## 7. Not yet reviewed

The gap review sections below still need discussion. Add items here as OQ numbers once discussed.

- **Section C, missing capabilities and flows:** user lifecycle (invite, deactivate, MFA, session timeout), notifications (recipients, preferences, escalation, suppression during bulk import, WhatsApp consent), import beyond assets (multi-entity rows, template download, update versus create, limits, undo after edits), attachments (security domain, limits, scanning, quota, storage cost), search (trigram under RLS, keyset pagination), dashboards and reports at scale, physical verification, mobile and PWA scope with no offline mode, operations (rate limits, query timeouts, migration rollback, test data, analytics, support tooling, status page), commercial (tiers, trial, invoicing).
- **Section D, screens versus documents:** the full list of missing screens (settings, onboarding wizard, import upload and mapping, import history, asset forms, transfer and retire dialogs, service completion, obligation setup, vendor and coverage detail, notifications, user management, API keys and webhooks, audit log, AI usage, QR label printing, BOM and attachments tabs).
- **Section E, spikes during M1:** (1) RLS and scope-check performance on about 1M generated assets, including the coverage view; (2) multi-tenant membership and token switching; (3) a metadata-driven form and validation engine; (4) PostgREST views and functions for the maintenance view. The SSO plan spike is dropped because SSO is Phase 2. Also define a thin vertical slice before the full M1 breadth.
- **Backlog and stories:** the stories were not available in the project files during this review. Check them against this tracker once shared.

---

## 8. Change log

| Date | Change |
|---|---|
| 11 Oct 2026 | File created from the gap review (sections A and B discussed, C to E pending) |
