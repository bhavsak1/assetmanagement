# Asset Management Platform: Project Knowledge Base

**Purpose:** shared context for all work on this project (design, architecture, cost analysis, backlog). Treat the "Decided" sections as settled unless the product owner changes them. Treat "Proposed" and "Open" sections as working assumptions.

**Last updated:** 10 Oct 2026
**Status:** Product definition complete for Phase 1 scope and priorities. Technology stack, architecture and cost analysis are next, then epics and stories.

---

## 1. Product summary

An **AI-native, multi-tenant asset management platform** (ERP-style) sold as SaaS to **small and medium industrial and manufacturing companies in India first**, then globally, with a path to larger companies with very large asset counts (multi-million assets).

- It is **not** a single-company internal tool. Every design choice must work for many tenants.
- IT and office assets are supported, but the primary target is industry and manufacturing.
- Asset types, fields and rules must be **fully configurable** by each tenant.
- AI features are a **paid add-on**. The core product must work fully without AI.
- Future phases include incident management, IoT integration and predictive capabilities. Phase 1 design must not need rework for them.

Working assumption for the technology (to be confirmed in the stack review): NestJS, PostgreSQL, React. Screens already planned: login (email and SSO), dashboard, Asset Category, Asset, Vendor.

---

## 2. Decisions log

### 2.1 Decided

| Topic | Decision |
|---|---|
| Customer model | Multi-tenant SaaS for SMEs first, scaling to large enterprises later |
| Geography | India first, global later. Do not hard-code India (see 6.2) |
| Asset types | Fully configurable. Onboarding asks the tenant's industry and suggests asset types, fields and defaults |
| AMS | Means **AMC** (Annual Maintenance Contract) |
| Warranty and AMC | Modelled as **Coverage** records with vendor and dates. "Out of warranty" means no active warranty-type coverage today |
| Service due date | Stored at **asset level**. Category may provide a default interval at creation, but the asset owns the date |
| Service scheduling | **Calendar-based only** in Phase 1. No run-hours or meter-based rules |
| Depreciation | **Out of Phase 1.** Indicative only when built. Method set per asset category with per-asset override. Phase 1 still captures purchase date and value |
| Mandatory fields | Minimal by default. Admins can configure which fields are mandatory per tenant and category |
| BOM | Optional. Reference list only, **no inventory** in Phases 1 and 2. May expand later |
| Data in | Excel upload and public API integration |
| AI pricing | Paid add-on, with usage metering |
| AI hero features | **Smart import** and **query-based insights** on asset data |
| Phase 2 | Incident management (incidents raised against assets), plus depreciation (indicative) |
| Low-cost Phase 1 additions | Accepted (see 4.2) |

### 2.2 Open (to be resolved in the stack, architecture and cost review)

- Technology stack confirmation, hosting and deployment model
- Multi-tenancy implementation details (shared schema with row-level security is the leading option)
- Cost model: infrastructure, AI usage, WhatsApp messaging, per-tenant unit economics
- AI add-on pricing structure and usage limits
- Data residency and compliance approach for global expansion
- Which AI model provider(s) to use, and how fallback works
- Industry template list for launch (suggested: 3 to 4 industries hand-built first)

---

## 3. Phase scope

### 3.1 Phase 1 (MVP)

1. Asset registry with configurable categories and fields
2. Vendor onboarding with roles (OEM, O&M, supplier) and contacts
3. Coverage (warranty, AMC) per asset, with status tracking
4. Locations (hierarchy) and location-wise asset views with statuses
5. Maintenance view: assets due for service, overdue, warranty status, age, optional purchase value
6. Optional BOM per asset
7. Excel import and public API
8. Industry-aware onboarding wizard
9. Notifications, roles, audit trail
10. AI add-on: smart import and query-based insights

### 3.2 Phase 2

- Incident management: raise incidents against assets for failures or issues. Auto-detect current coverage and responsible vendor, assignment, SLA timers, status workflow, resolution notes, downtime or cost capture, optional link to a BOM part, feedback into service history
- Depreciation (indicative only)
- Work orders (evolving from the Phase 1 service completion record)

### 3.3 Later phases

IoT ingestion, predictive maintenance, inventory, meter or usage-based servicing, vendor portal, native mobile apps, ERP and accounting connectors (Tally is a strong India candidate).

---

## 4. Phase 1 prioritisation

**Priority levels:** P0 Foundation (nothing works without it), P1 Core MVP (not sellable without it), P2 Differentiators (AI add-on), P3 Low-cost accelerators (cheap and valuable, can be slotted anywhere). Effort is relative: XS, S, M, L.

### 4.1 Feature list

| ID | Feature | Pri | Effort | Notes |
|---|---|---|---|---|
| F1 | Tenant, auth (email and SSO), roles, audit log, tenant settings | P0 | L | Tenant isolation from day one |
| F2 | Metadata engine: categories, field definitions, mandatory-field rules | P0 | L | Almost everything depends on this |
| F3 | Location hierarchy | P0 | M | |
| F4 | Domain events (outbox) and asset identifiers table | P0 | S | Phase 2 and IoT insurance |
| F5 | Asset registry (CRUD, status lifecycle, custom fields, attachments) | P1 | L | |
| F6 | Vendor management (roles, contacts) | P1 | M | |
| F7 | Coverage (warranty, AMC, other) | P1 | M | |
| F8 | Asset transfer between locations, with history | P1 | S | |
| F9 | Industry templates and onboarding wizard | P1 | M | Hand-seed first |
| F10 | Excel import (rules-based): mapping, validation, dry-run, commit, undo | P1 | L | Mapping step must be pluggable for AI |
| F11 | Recurring obligations (service, calibration, inspection, certificates) with next-due date | P1 | M | Generalised service rule |
| F12 | Service/obligation completion record (date, notes, cost, attachments) | P1 | S | Seed of work orders |
| F13 | Maintenance view: due, overdue, coverage status, age, optional purchase value | P1 | M | |
| F14 | Location view with status counts | P1 | S | |
| F15 | Notifications: email and in-app | P1 | M | |
| F16 | Optional BOM (reference only) | P1 | S | |
| F17 | Public REST API, API keys, webhooks | P1 | M | AI assistant also calls this |
| F18 | AI gateway: entitlement, metering, logging, fallback | P2 | M | Must precede any AI feature |
| F19 | Smart import (AI mapping, normalising, dedupe, review) | P2 | L | Hero feature 1 |
| F20 | Query-based insights (natural language to structured query) | P2 | L | Hero feature 2 |
| F21 | QR labels and scan-to-open (responsive web) | P3 | S | |
| F22 | Asset criticality (A/B/C) | P3 | XS | |
| F23 | Retire/dispose action with reason and date | P3 | XS | |
| F24 | Saved views, bulk edit, export | P3 | S | |
| F25 | Custody/assignment to a person or department (optional) | P3 | XS | |
| F26 | WhatsApp notification channel | P3 | M | Provider onboarding and template approval take lead time |
| F27 | Setup copilot (describe business, get category tree) | Could | M | |
| F28 | Document extraction (invoice, warranty card, nameplate) | Could | M | Fast follow |
| F29 | Weekly insights digest | Could | S | Cheap after F20 |

### 4.2 Low-cost additions accepted into Phase 1

QR codes with a mobile-friendly web app, asset criticality, recurring obligations beyond service (calibration, inspection, certificates), service completion record, disposal action, saved views and bulk edit, WhatsApp notifications.

### 4.3 Suggested build sequence

1. **Milestone 1, Foundation (F1 to F4).** Multi-tenancy, metadata engine, events.
2. **Milestone 2, Working register (F5 to F9).** Assets, vendors, coverage, locations, onboarding. Slot in F22, F23, F25. Start WhatsApp provider onboarding.
3. **Milestone 3, Data in and value out (F10 to F17).** Import, obligations, service records, maintenance view, notifications, API. First pilot-ready point. Slot in F21 and F24.
4. **Milestone 4, AI add-on (F18 to F20).** Gateway, then smart import, then insights.

An early demo after Milestone 3 ("upload Excel, see dashboard, get alerts") is possible, optionally with a limited insights feature (counts and lists only).

### 4.4 Scope-pressure rules

1. Cut P3 and "Could" first, never P0.
2. Never ship an AI feature without the gateway, a review step and a manual fallback.
3. Keep mandatory fields minimal by default.
4. Do not start P1 or P2 features before the metadata engine (F2) is stable.

---

## 5. Domain model (Phase 1)

**Tenancy and access:** Tenant, User, Role, Tenant Settings (locale, currency, time zone, mandatory-field rules, AI entitlement).

**Configuration:** Industry Template, Asset Category (hierarchical), Field Definition (type, required flag, picklist values, unit), Category-Field link.

**Core:** Asset (core fields plus custom values in JSONB), Asset Identifier (tag, serial, QR, ERP reference, future device ID), Location (hierarchy), Asset Location History, Vendor, Vendor Role, Vendor Contact, Coverage (type: warranty, AMC, other; vendor, start, end, scope), Obligation / Service Rule (structured interval rule, last done, next due), Service Record, BOM Item (reference only), Attachment.

**Data and AI:** Import Job, Import Row Result, Import Mapping Template, Saved Query / Insight Widget, AI Usage Log.

**Platform:** Audit Log, API Key, Webhook Subscription.

**Not in Phase 1 (hooks only):** Incident, Work Order, Depreciation fields, Inventory, Telemetry.

### Asset status lifecycle

In Stock, Active, Under Maintenance, Inactive/Spare, Disposed/Retired. Disposed assets stay as history and are never hard-deleted.

### Key modelling reasons

- **Vendor as one entity with roles**, because one company is often both OEM and servicer.
- **Coverage as its own entity**, because an asset can have a warranty plus an extended warranty plus an AMC, and contracts renew. It also lets Phase 2 incidents ask "is this asset covered right now, and by whom?"
- **Obligation as a structured rule** (not a bare number of days) so usage-based rules can be added later without changing the model.
- **Custom fields in JSONB with separate definitions**, giving per-tenant flexibility without per-tenant schema changes.

---

## 6. Platform principles

### 6.1 Multi-tenancy

- Every record carries a tenant ID. Enforce isolation with Postgres row-level security, not only in application code.
- Start with a shared schema. Keep the option to move a very large customer to a dedicated database.

### 6.2 Internationalisation (India first, not India only)

- Tenant-level currency, locale, time zone and date format. UTC timestamps. Amounts stored with currency code.
- Translatable UI text from the start.
- Tax and compliance fields (GSTIN, PAN) are optional configurable fields on vendors, not hard-coded.
- Decide on data residency before the first enterprise deal.

### 6.3 Configurability

- Categories and types are data, not code. Each category defines its fields. "Required" is a flag on the field definition that admins can change.
- Industry onboarding: tenant picks its industry, the platform suggests categories, fields, default service intervals and typical BOM parts. Users accept, edit or delete. These are starting points, not locks.

### 6.4 Data in and out

- Excel import with mapping, dry-run validation, row-level errors and re-import of corrected rows. Idempotent via external reference IDs so repeat syncs don't create duplicates. Whole imports can be undone as a batch.
- Versioned REST API with scoped API keys. Outbound webhooks (asset created, coverage expiring, service overdue, and later incident raised).

### 6.5 Always on

RBAC, audit trail, soft delete, per-tenant file storage, notification preferences.

### 6.6 Event-driven core and IoT readiness

- Publish domain events through an outbox (coverage expiring, service overdue, status changed). The same events later drive notifications, webhooks, IoT-triggered incidents and AI agents.
- Stable asset identity: internal ID plus an identifiers table, so a device ID maps to an asset without schema change.
- Telemetry stays out of the core transactional database. Later, use a time-series store (for example TimescaleDB on Postgres) fed by an ingestion layer. The asset record holds only latest status.
- The UI and the AI assistant should use the same API, so capabilities aren't built twice.

---

## 7. AI design

### 7.1 Principles

- AI **suggests**, humans **confirm**. Nothing is committed silently.
- Deterministic checks (types, required fields, duplicates) run in code. AI handles the fuzzy parts (mapping, matching, inference).
- Every AI-filled field is marked "AI-suggested" with source and confidence.
- Tenant data isolation. Customer data is not used for training.
- AI action log (suggested, accepted, rejected). It doubles as feedback data.
- Per-tenant usage limits and metering through one AI gateway that checks entitlement. Manual alternatives must always work.

### 7.2 Hero feature 1: Smart import

Flow: upload, understand (AI profiles the data and proposes column mapping with confidence), normalise (merge vendor name variants, match or propose categories and sites, parse mixed date and number formats, standardise units), validate (duplicates, missing mandatory fields, impossible dates such as warranty ending before purchase, suspicious values), review (accepted, needs-attention and rejected rows with bulk accept, inline edit and explanations), commit (background job, idempotent, undoable).

Extras: save confirmed mappings as reusable templates, batch requests to control cost, keep an import record (file, mapping, row outcomes) for audit and AI improvement.

### 7.3 Hero feature 2: Query-based insights

- The user asks in plain language ("Which assets at the Pune plant have AMC expiring in the next 60 days?").
- The model converts the question into a **structured query** (filters, grouping, aggregation, sort) over a defined **semantic layer**. It never writes raw SQL.
- The backend validates and runs the query with the user's own permissions and tenant isolation. The assistant can never show more than the screens would.
- The answer shows the interpreted filters ("I understood this as...") so users can correct it, with options to save as a dashboard widget or export.
- Start with descriptive questions (counts, lists, groupings). Add proactive insights (weekly digest) afterward.
- Tenant-defined custom fields are included in the semantic layer automatically.

### 7.4 Later AI candidates

Setup copilot, document-to-asset extraction (invoice, warranty card, AMC contract, nameplate photo), BOM suggestions from model or manual, service-interval suggestions from OEM manuals, weekly digest, then predictive features when IoT data exists.

---

## 8. Competitive landscape (public sources, Oct 2026; verify before using externally)

### 8.1 Tiers

| Tier | Examples | Profile |
|---|---|---|
| Heavy enterprise EAM | IBM Maximo, SAP EAM, HxGN (formerly Infor) EAM | Deep functionality for asset-intensive industries. Expensive and implementation-heavy. Maximo bundles monitoring and AI |
| Mid-market CMMS | Fiix (Rockwell Automation), Limble, MaintainX, UpKeep, eMaint | Strong work orders and technician adoption. Fiix is cloud-native and easier than SAP or Maximo. MaintainX is mobile-first |
| Asset tracking / fixed assets | Asset Panda, Asset Infinity (India) | Configurable tracking. Asset Infinity is a Noida-based tool with native mobile apps, priced by asset count (listings show roughly $49 to $149 per month for up to 1,000 assets) |

The platform sits between mid-market CMMS and asset tracking, with a path upward.

### 8.2 AI in competitors

- Fiix launched **Fiix MAX** (14 July 2026): a conversational assistant trained on the customer's own CMMS data, sold as a paid add-on on Professional and Enterprise tiers. Fiix also has Foresight (PM interval optimisation, parts forecasting, anomaly detection).
- MaintainX has a CoPilot on premium tiers and anomaly detection.
- Takeaway: natural-language Q&A over asset data is becoming **expected** in the mid-market. Some comparison sources describe competitor AI as assistive, but those sources are vendors with competing products, so treat that as a hint, not proof.
- Fiix, Limble, MaintainX and UpKeep all offer a free tier or trial. Fiix lists a free version.

---

## 9. Differentiation strategy

1. **Time to value.** Industry templates plus smart import should get a customer to a populated register in a day, versus implementation projects for heavy EAM. Prove with timed pilots.
2. **Combination, not chat alone.** NL queries are not a moat by themselves. The edge is AI-driven import and data quality feeding trustworthy insights, for a segment competitors serve less directly.
3. **Commercial coverage intelligence.** Warranty and AMC as a headline feature ("never pay for a repair that was covered, renew AMCs with data"). Hypothesis to test in interviews.
4. **Built for Indian SMEs.** Asset-count-based pricing, WhatsApp alerts, GST and PAN vendor fields, Tally export (later), regional-language UI, Indian statutory inspection and calibration templates.
5. **Configurable without consultants.** Metadata-driven fields and industry-aware onboarding.
6. **Platform path.** API-first, event-driven, IoT-ready, so small customers grow into incidents, work orders, IoT and predictive without switching vendor.

---

## 10. Risks

- **Free tiers and low prices** in the market. The AI add-on needs a clear ROI story.
- **"Is this a CMMS?"** Maintenance-driven buyers expect work orders. Position Phase 1 as the asset system of record and maintenance planner. Work orders arrive in Phase 2.
- **Well-funded incumbents** (for example Fiix inside Rockwell). Speed and SME focus must compensate.
- **AI trust.** Confident mistakes in smart import would hurt adoption. The review step and confidence scores are essential.
- **WhatsApp lead time.** Provider onboarding and message-template approval can delay the channel.

---

## 11. Validation plan

- 8 to 10 conversations with small manufacturers to test the differentiators.
- Timed import trials on messy real Excel files from a couple of those prospects.
- Trial two competitors (suggested: Fiix and Asset Infinity) to see where their onboarding slows down.
- Re-verify competitor pricing and features before any business case, since they change often.

---

## 12. Phase 2 and later hooks built into Phase 1

| Deferred item | Phase 1 hook |
|---|---|
| Incident management | "Under Maintenance" status, queryable coverage by date, vendor contacts, published events |
| Work orders | Service completion record becomes a work order without schema change |
| Depreciation | Purchase date and value captured, category has a place for a method |
| Inventory | BOM items are reference records that can link to stock later |
| Meter-based servicing | Obligations stored as structured rules |
| IoT ingestion | Identifiers table holds device IDs, events flow through the outbox |
| Native mobile apps | API-first plus a responsive web app |
| Vendor portal | Vendors and contacts are separate records, so login can be added later |

---

## 13. Glossary

- **AMC:** Annual Maintenance Contract (the "AMS" in early notes).
- **OEM:** Original Equipment Manufacturer.
- **O&M:** Operations and Maintenance vendor.
- **BOM:** Bill of Materials. Here, an optional reference list of parts, consumables and accessories per asset.
- **Coverage:** a warranty, AMC or similar contract tied to an asset with a vendor and date range.
- **Obligation:** a recurring task on an asset (service, calibration, inspection, certificate renewal) with a next-due date.
- **Semantic layer:** the defined set of fields, statuses and measures that the AI assistant is allowed to query.
- **Outbox pattern:** writing domain events to a table in the same transaction as the data change, then publishing them reliably.
- **RLS:** Row-level security in PostgreSQL, used to enforce tenant isolation.
- **EAM / CMMS:** Enterprise Asset Management / Computerised Maintenance Management System.

---

## 14. Next steps

1. Technology stack review (confirm NestJS, PostgreSQL, React, hosting, background jobs, search, file storage).
2. Architecture review (multi-tenancy, event layer, AI gateway, import pipeline, semantic layer, security).
3. Cost analysis (infrastructure, AI usage, messaging, per-tenant economics, add-on pricing).
4. Then: Phase 1 backlog with epics, user stories and acceptance criteria (P0 and P1 first), plus separate specifications for P2 AI features.
