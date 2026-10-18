# Asset Management Platform: Goals and Stories Tracker

**Purpose:** the working backlog for Phase 1. Each goal ends in something you can open and review. Read together with the Knowledge Base, `technical-architecture.md`, `security-model.md` and `open-items-tracker.md`.

**Created:** 11 Oct 2026
**Last updated:** 11 Oct 2026
**Status:** Order agreed. Acceptance criteria not yet written for any goal (next: Goal 0 and Goal 1).

## How to use this file

- Story IDs are `goal.number` (for example 3.2). Never reuse an ID. Add new stories at the end of their goal.
- **Status values:** `Todo`, `In progress`, `In review` (built, waiting for owner review), `Done`, `Blocked`, `Dropped`.
- Update the status column at the end of each session. Add a line to the change log (part 4) when a story is added, split, moved or dropped.
- **Review point** is the deliverable you check before the next goal starts. A goal is `Done` only when its review point is accepted.
- **Open items** point to `open-items-tracker.md` (OQ-nn). If a decision is not made by the "needed by" date there, the current lean is used.
- Stories are sized for about one Claude Code session: one migration or one feature, plus tests.

## Definition of done (every story)

1. SQL migration in git, no dashboard-only changes.
2. RLS and permission tests where the story touches data.
3. UI matches the attached screen (`assetly-screens.html`) where a screen exists.
4. TypeScript types regenerated from the schema.
5. Short demo note (what to click, what to expect).
6. Owner reviews personally anything touching auth, RLS, API keys or file access.

## Decisions needed before Goal 0

| # | Decision | Needed by | Status |
|---|---|---|---|
| D1 | Service framework for M3 (Hono or Fastify preferred, NestJS acceptable) and query layer (Drizzle or Kysely). Same as OQ-28 | Start of Goal 8 | Open |
| D2 | Draft `CLAUDE.md` as story 0.1 (tenancy, migration, RLS, naming rules) | Before 0.1 | Open |

---

## 1. Stories by goal

### Goal 0: Walking skeleton
**Review point:** you sign in and see the Assetly shell running in a real environment.

| ID | Story | Open items | Status |
|---|---|---|---|
| 0.1 | Repo setup: `CLAUDE.md`, the context docs, folder structure, conventions | D2 | Todo |
| 0.2 | Local Supabase, migration workflow, GitHub Actions running tests | | In review |
| 0.3 | React, Vite, TS app shell: design tokens from the screens, sidebar, topbar, routing, empty pages for every screen | | Todo |
| 0.4 | Email login and logout with Supabase Auth, protected routes. No SSO button (SSO moved to Phase 2) | OQ-29 | Todo |

### Goal 1: Tenant and security core
**Review point:** two test tenants exist, and a test report proves tenant A cannot see tenant B and an Auditor cannot update anything.

| ID | Story | Open items | Status |
|---|---|---|---|
| 1.1 | Tenant, user profile, tenant membership, JWT hook carrying `tenant_id`. Hand-seeded `tenant_entitlement` and `tenant.status` | OQ-16, OQ-17, OQ-23, OQ-30 | Todo |
| 1.2 | Security tables: domain, operation, group, policy, assignment. Seed the default domain catalog | OQ-25 | Todo |
| 1.3 | `user_effective_permission` rebuild function and `has_permission()` helpers (includes tenant status write check) | OQ-30 | Todo |
| 1.4 | First RLS pattern on a sample table, plus the cross-tenant test harness | | Todo |
| 1.5 | Audit log and outbox tables with triggers | | Todo |
| 1.6 | Starter groups (Tenant Admin, Plant Manager, Planner, Technician, Auditor) and the permission test matrix in CI | OQ-22, OQ-25 | Todo |
| 1.7 | Spike: RLS and scope-check performance on about 1M generated assets (added from open-items tracker, section E) | | Todo |

### Goal 2: Configuration (categories, fields, locations)
**Review point:** you create a category with custom fields and a location tree in the UI.

| ID | Story | Open items | Status |
|---|---|---|---|
| 2.1 | Category and field definition tables (hierarchy, type, required flag, security domain) | | Todo |
| 2.2 | Categories screen: list, add, edit category and fields | | Todo |
| 2.3 | Location hierarchy with closure table | | Todo |
| 2.4 | Locations screen: tree, add, move | | Todo |
| 2.5 | Tenant settings (locale, currency, time zone) and mandatory-field rules | | Todo |

### Goal 3: Working asset register
**Review point:** you add real assets and see them on the Assets list and detail screens. First "feels like a product" demo.

| ID | Story | Open items | Status |
|---|---|---|---|
| 3.1 | Asset table, status lifecycle, identifiers, JSONB custom values, RLS | OQ-01, OQ-04, OQ-07 | Todo |
| 3.2 | Assets list: filters (including In Stock), search, pagination, saved views | | Todo |
| 3.3 | Add and edit asset form, driven by category fields and mandatory rules | OQ-06 | Todo |
| 3.4 | Asset detail: Overview tab and Audit tab | | Todo |
| 3.5 | Transfer between locations with history, and Retire with reason | | Todo |
| 3.6 | Attachments (per-tenant storage) and QR label with scan-to-open | OQ-02 | Todo |

Note: start WhatsApp provider onboarding around this goal because of lead time (OQ-14).

### Goal 4: Vendors and coverage
**Review point:** assets show warranty and AMC status and the responsible vendor.

| ID | Story | Open items | Status |
|---|---|---|---|
| 4.1 | Vendor, roles (OEM, O&M, supplier), contacts, optional GSTIN and PAN fields, Vendors screen | OQ-06 | Todo |
| 4.2 | Coverage table, status derivation (active, expiring, expired, never covered) | OQ-05, OQ-26 | Todo |
| 4.3 | Coverage screen and Coverage tab on asset detail | | Todo |
| 4.4 | Coverage column and filter on the Assets list | | Todo |

### Goal 5: Obligations and dashboard (first pilot-style demo)
**Review point:** a seeded demo tenant with a populated dashboard and maintenance view.

| ID | Story | Open items | Status |
|---|---|---|---|
| 5.1 | Obligation rule table, next-due calculation, category default intervals | OQ-03 | Todo |
| 5.2 | Service completion record (date, notes, cost, attachment) that advances next due | | Todo |
| 5.3 | Maintenance screen: overdue, due soon, scheduled, completed | | Todo |
| 5.4 | Dashboard KPIs, upcoming list, assets by location | | Todo |
| 5.5 | Locations status counts, optional BOM tab, demo seed data | | Todo |

### Goal 6: Security admin UI and scope
**Review point:** you create a Pune-only Plant Manager and verify through the UI that Mumbai assets disappear.

| ID | Story | Open items | Status |
|---|---|---|---|
| 6.1 | Scope profiles (location, category) and row-level scope enforcement | OQ-24 | Todo |
| 6.2 | Secure views for restricted fields (purchase value, vendor tax IDs) | | Todo |
| 6.3 | Security screen: groups, domain policy grid (rendered from each domain's operations), assignments | | Todo |
| 6.4 | Draft, review, activate change sets | OQ-22 | Todo |
| 6.5 | "Why can this user see this?" explainer and access review report | | Todo |

### Goal 7: Onboarding and templates
**Review point:** a new tenant is usable within minutes.

| ID | Story | Open items | Status |
|---|---|---|---|
| 7.1 | Industry template tables, with one hand-seeded industry | OQ-13 | Todo |
| 7.2 | Onboarding wizard UI (pick industry, accept or edit categories, fields, intervals) | | Todo |
| 7.3 | Starter security groups per template, plus two more industries | OQ-13, OQ-25 | Todo |

### Goal 8: Excel import (starts the custom service)
**Review point:** upload a messy Excel file, review it, commit, and undo.

| ID | Story | Open items | Status |
|---|---|---|---|
| 8.1 | Custom service skeleton, deployed, using user token or `SET LOCAL` tenant context | D1, OQ-28 | Todo |
| 8.2 | Upload and streaming parse into staged rows | | Todo |
| 8.3 | Column mapping step (pluggable) and mapping templates | | Todo |
| 8.4 | Deterministic validation and dry run | | Todo |
| 8.5 | Import review screen | | Todo |
| 8.6 | Idempotent commit and batch undo | | Todo |

### Goal 9: Notifications, API, webhooks
**Review point:** an overdue service or expiring coverage produces an alert, and an external script reads assets through the API.

| ID | Story | Open items | Status |
|---|---|---|---|
| 9.1 | Outbox poller, in-app and email notifications | | Todo |
| 9.2 | Public REST API `/v1`, API keys, integration users | | Todo |
| 9.3 | Webhooks with signing and retries | | Todo |
| 9.4 | WhatsApp channel | OQ-14 | Todo |

### Goal 10: AI add-on
**Review point:** smart import and query-based insights working behind the gateway.

Stories to be written once Goal 8 is done. Planned order: AI gateway (entitlement, metering, logging, fallback), smart import (mapping, normalise, dedupe), Insights screen with structured queries.

Open items: OQ-11, OQ-21.

---

## 2. Goal progress

| Goal | Review point accepted | Notes |
|---|---|---|
| 0 Walking skeleton | No | |
| 1 Tenant and security core | No | |
| 2 Configuration | No | |
| 3 Working asset register | No | |
| 4 Vendors and coverage | No | |
| 5 Obligations and dashboard | No | |
| 6 Security admin UI and scope | No | |
| 7 Onboarding and templates | No | |
| 8 Excel import | No | |
| 9 Notifications, API, webhooks | No | |
| 10 AI add-on | No | Stories not yet written |

## 3. Scope-pressure rules (from the Knowledge Base)

1. Cut P3 and "Could" items first, never P0.
2. Never ship an AI feature without the gateway, a review step and a manual fallback.
3. Keep mandatory fields minimal by default.
4. Do not start P1 or P2 work before the metadata engine (Goal 2) is stable.

## 4. Change log

| Date | Change |
|---|---|
| 11 Oct 2026 | File created from the agreed goal-wise breakdown. Added vs the chat version: story 1.7 (RLS performance spike), links to open items, SSO button removed from 0.4, entitlement and tenant status added to 1.1 and 1.3, WhatsApp onboarding note under Goal 3, review points for Goals 9 and 10 |
