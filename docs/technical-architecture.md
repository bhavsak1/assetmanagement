# Asset Management Platform: Technical Architecture

**Purpose:** shared technical context for all work on this project. Read together with the product Knowledge Base and `security-model.md`. Treat "Decided" as settled unless the product owner changes it. Treat "Proposed" and "Open" as working assumptions.

**Last updated:** 10 Oct 2026
**Status:** Initial-build architecture agreed. Supersedes the Knowledge Base working assumption of "NestJS, PostgreSQL, React" as the backend approach (see 2.1).

---

## 1. Constraints driving the design

- Multi-tenant SaaS for small and mid-size industrial and manufacturing companies in India first, then global. Low cost per tenant is a hard requirement.
- AI-native (paid add-on, core product works without AI) and fully cloud.
- Built **solo by the product owner with Claude Code**. Minimise things to operate and code to review.
- Owner background: ERP (Workday, Oracle Apps), has used Supabase before, limited MERN or custom-development experience.
- Phase 1 must not need rework for Phase 2 (incidents, work orders) or IoT.

---

## 2. Decisions

### 2.1 Decided

| Topic | Decision |
|---|---|
| Platform approach | **Supabase-first** (managed Postgres, Auth, Storage). Custom service added only when a feature needs it. Revisit full AWS later (major re-platform is a later conversation) |
| Region | Supabase Mumbai (ap-south-1), single region, single shared database |
| Tenancy | Shared schema, `tenant_id` on every table, Postgres RLS. One Supabase project for all tenants (never one project per tenant) |
| Frontend | React + TypeScript, Vite SPA, responsive PWA (QR scan-to-open), i18n from the start |
| Custom service | Added in **Milestone 3**. One small TypeScript service for import workers, public API, webhooks, outbox poller, AI gateway |
| Queue, search, vectors, events | All in Postgres: pg-boss or `pg_cron` for jobs, full-text and trigram for search, `pgvector` for embeddings, transactional outbox table for events. No Redis, OpenSearch or Kafka at launch |
| Portability | Everything is a plain SQL migration in git (including RLS policies). Avoid Supabase-only features for core business logic so a move to RDS or self-hosting stays a migration, not a rewrite |
| Security model | Workday/Oracle-style domain security. See `security-model.md` |
| Compute model | Modular monolith. No Kubernetes, no microservices |

### 2.2 Proposed (confirm when relevant)

- Service framework: Hono or Fastify preferred over NestJS for a solo builder (less boilerplate). NestJS remains acceptable if the owner wants enforced structure.
- ORM or query layer: Drizzle or Kysely preferred over Prisma (RLS needs per-transaction tenant context via `SET LOCAL`).
- Service hosting: small container host such as Fly.io, Railway, Render or AWS App Runner. Move to AWS Fargate later if needed.
- Frontend hosting: Cloudflare Pages or similar (free tier).
- Email: Amazon SES. WhatsApp: a business solution provider (Gupshup, Twilio or Meta Cloud API).
- AI provider: Anthropic Claude as primary, second provider as fallback, behind the AI gateway.
- Observability: Sentry plus uptime checks, OpenTelemetry later.

### 2.3 Open

- Supabase plan tier needed for SAML SSO and compliance evidence (likely Team plan). Verify before promising SSO to any customer.
- Point-in-time recovery and backup retention (paid add-on). Budget before first paying customer.
- Data residency approach for global expansion and the first enterprise deal.
- Which stronger model is used for natural-language queries, and its pricing (not verified).
- WhatsApp provider selection and onboarding lead time.

---

## 3. Component view

```
 React web app (PWA)                 Customer systems (ERP, scripts)
        |                                        |
        | direct, user JWT + RLS                 | public API + API keys
        v                                        v
+--------------------------------+      +-----------------------------+
| Supabase (Mumbai)              |      | Custom service (from M3)    |
|  Auth (email, SSO later)       |<-----|  Excel import workers       |
|  Storage (per-tenant files)    |      |  Public REST API + keys     |
|  Postgres + RLS                |      |  Webhooks + outbox poller   |
|   JSONB, pgvector, pg_cron,    |      |  AI gateway + metering      |
|   outbox                       |      +-----------------------------+
+--------------------------------+            |            |
                                              v            v
                                  Email + WhatsApp     AI providers
                                  (SES, BSP)           (Claude, fallback)
```

Dev and release: GitHub Actions and Supabase CLI, with dev, staging and production environments.

---

## 4. Milestone mapping

| Milestone | Technical content | Custom server? |
|---|---|---|
| M1 Foundation (F1 to F4) | Tenancy, auth, security engine, metadata engine, locations, outbox and identifiers. Supabase only | No |
| M2 Working register (F5 to F9) | Assets, vendors, coverage, transfers, onboarding. React calls Supabase directly | No |
| M3 Data in, value out (F10 to F17) | Excel import, obligations, service records, maintenance view, notifications, public API and webhooks | **Yes, first time** |
| M4 AI add-on (F18 to F20) | AI gateway, smart import, query-based insights | Same service |

Before M3 there is **no public API**. If a pilot needs integration earlier, pull the service forward.

---

## 5. Multi-tenancy rules

1. `tenant_id` on every table. `tenant_id` and a permission-version number are carried in the JWT (via an Auth hook).
2. RLS on every table. Policies call permission helper functions (see `security-model.md`).
3. The custom service must **not** use the Supabase service-role key for user-driven work, because it bypasses RLS. Pass the user's token or set tenant context per transaction (`SET LOCAL`). Reserve the service role for system jobs (outbox poller, scheduled checks).
4. Use transaction-scoped tenant settings so pooled connections cannot leak context.
5. Automated cross-tenant tests in CI (log in as tenant A, try to read tenant B). Reviewed by the owner personally.
6. Keep all database access behind one data layer so a very large tenant can later move to a dedicated database.

---

## 6. Data in and out

- **Public REST API:** versioned (`/v1`), OpenAPI documented, cursor pagination. Do **not** expose Supabase's auto-generated API as the public contract.
- **API keys:** per tenant, stored hashed, shown once, revocable, scoped. Keys map to an integration user governed by the same security engine.
- **Inbound sync:** idempotent upserts by external reference ID.
- **Webhooks:** driven by the outbox (asset created, coverage expiring, service overdue), signed, with retries.
- **Rate limits and usage logs** per key.
- **Excel import pipeline:** upload to storage, parse in a worker (streaming), stage rows in `import_row_result`, deterministic validation, pluggable AI mapping step, batched commit, idempotent and undoable as a batch.

---

## 7. AI architecture

1. **AI gateway (F18)** is the single entry point for every model call: entitlement check, usage metering, logging, rate limits, retries, provider fallback. Must precede any AI feature.
2. **Tiered models by task:** a small, cheap model for column mapping, normalising and classification; a stronger model for natural-language-to-query; embeddings (`pgvector`) for vendor and category matching and duplicate detection.
3. **Smart import:** AI proposes mappings and normalisation, deterministic code validates, humans confirm. Confirmed mappings are saved as templates (zero AI cost on repeat imports). Batch rows per request.
4. **Query-based insights:** model outputs a **structured query** (JSON) against a defined semantic layer, never raw SQL. A deterministic compiler produces parameterised SQL under the user's own permissions. The semantic layer is built per user, so fields in domains they cannot view are never offered. Tenant custom fields are included automatically.
5. **Trust controls:** schema-validated structured outputs, confidence scores, "AI-suggested" flags, AI action log (suggested, accepted, rejected), no training on customer data.
6. **Cost controls:** deterministic code first, prompt caching of the schema context, per-tenant monthly caps, batch API where possible.
7. **Evaluation harness from day one:** golden set of messy Excel files and sample questions, run in CI against prompt and model changes.
8. UI and AI assistant use the same API and permission checks, so capabilities are not built twice.

---

## 8. Events and IoT readiness

- Domain events are written to an outbox table in the same transaction as the data change, then published by a poller. The same events later feed notifications, webhooks, IoT-triggered incidents and AI agents.
- Stable asset identity: internal ID plus an identifiers table (tag, serial, QR, ERP reference, future device ID).
- Telemetry stays out of the core transactional database. Later use a time-series store (for example TimescaleDB) behind an ingestion layer.

---

## 9. Initial cost estimate (indicative, verify before any business case)

Figures come from public 2026 pricing guides, not vendor pages. Sources disagree slightly on Supabase Small compute (most say $15). USD per month.

| Item | Build (M1 to M2) | Pilot (M3 to M4, 3 to 10 tenants) | Early production (about 30 tenants) |
|---|---|---|---|
| Supabase | $0 (Free) | $35 to 40 (Pro, prod plus staging) | $85 to 110 |
| Custom service host | none | $5 to 15 | $15 to 30 |
| Frontend hosting | $0 | $0 | $0 to 20 |
| Email, domain, uptime | about $2 | $3 to 6 | $5 to 15 |
| Error monitoring | $0 | $0 | $0 to 26 |
| AI usage (Haiku-class) | about $0 | $1 to 5 | $10 to 40 |
| WhatsApp | none | $0 to 10 | $10 to 40 |
| **Total** | **about $2** | **about $45 to 80** | **about $130 to 280** |

Reference points: Supabase Pro is $25 per organisation per month with a $10 compute credit covering one Micro instance; Small is about $15 and Medium about $60; Team is $599 per month (adds SOC 2 and SSO); production plus staging on Micro is about $35. Claude Haiku 5.5 is $0.10 per million input tokens and $0.50 per million output tokens (up to 100K-token prompts; its tokenizer counts about 30 percent more tokens than Haiku 4.5; Batch API discount of 50 percent).

Service host and WhatsApp figures are estimates. Not included: Claude Code subscription, owner time, GST, payment-gateway fees, external security review.

At about 30 tenants infrastructure is roughly $5 to 9 per tenant against the $50 to 150 per month asset-based pricing target.

**Cost cliffs to watch:** Small to Medium compute (about $50 extra), Team plan ($599) when SSO or compliance is demanded, point-in-time recovery add-on, WhatsApp per-message fees.

---

## 10. Scale path

| Trigger | Move |
|---|---|
| Heavy reporting | Read replica, materialised views, then columnar store |
| Large tenant | Partitioning by tenant, then dedicated database |
| Queue throughput | pg-boss to BullMQ with Redis, or SQS |
| Search complexity | Add OpenSearch only when Postgres full-text is proven insufficient |
| IoT telemetry | TimescaleDB behind an ingestion service |
| Enterprise, compliance, data residency abroad | Move to AWS (RDS, Fargate), regional stacks with tenants pinned to a region |
| Team growth | Extract AI gateway, import, notifications into services along existing module boundaries |

---

## 11. Engineering practices (solo with Claude Code)

- Repo holds the Knowledge Base and these architecture files, referenced from `CLAUDE.md` so every session starts with the same context.
- All schema and policy changes as SQL migrations (Supabase CLI). Never dashboard-only changes.
- Generate TypeScript types from the schema.
- Local-first development (Supabase CLI and Docker), separate dev, staging, production projects.
- Small, reviewable changes: one migration or feature per session, with tests.
- Owner personally reviews auth, RLS, API key handling and file access. Consider an external security review before paying customers.

---

## 12. Risks

1. **RLS correctness.** A policy mistake is a data leak. Mitigate with tests per role and per tenant in CI.
2. **RLS and connection pooling.** Session-level settings can leak across pooled connections. Use `SET LOCAL` per transaction and test early.
3. **Solo capacity.** Phase 1 is large for one person. Apply the scope-pressure rules (cut P3 and "Could" first).
4. **Supabase cost steps and plan gating** (SSO, compliance, backups).
5. **AI trust.** Confident mistakes in smart import hurt adoption. Review step, confidence scores and the evaluation harness are mandatory.
6. **WhatsApp lead time and per-message cost.** Start provider onboarding in Milestone 2.
7. **LLM pricing and availability change often.** Keep the gateway provider-agnostic and re-verify before business cases.

---

## 13. Next steps

1. Stack decision record and starter `CLAUDE.md` (architecture rules, tenancy rules, migration conventions).
2. M1 SQL schema: tenancy, security engine (see `security-model.md`), metadata engine, outbox.
3. Re-verify pricing (Supabase plan for SSO, PITR, WhatsApp, LLM) before the business case.
4. Then: Phase 1 backlog with epics, stories and acceptance criteria (P0 and P1 first).
