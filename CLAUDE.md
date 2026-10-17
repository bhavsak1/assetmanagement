# CLAUDE.md: Assetly (asset management platform)

Read this file first in every session. It holds the rules that do not change between stories. The product, architecture and security details live in `docs/`.

Status: draft for story 0.1. The repository layout and conventions were agreed by the owner on 17 Oct 2026.

## 1. What we are building

An AI-native, multi-tenant asset management SaaS for small and medium industrial and manufacturing companies in India first, then global. Built solo by the owner with Claude Code. Low cost per tenant is a hard requirement. The core product must work fully without AI. AI is a paid add-on.

Phase 1 scope is the MVP in `docs/asset-management-platform-knowledge-base.md` section 3.1. Do not build anything from Phase 2 or later (incidents, work orders, depreciation, inventory, IoT, predictive, vendor portal, native mobile). Leave the hooks listed in section 12 of the knowledge base and nothing more.

## 2. Context files (read the ones your story touches)

| File | Use it for |
|---|---|
| `docs/stories-tracker.md` | The backlog. Find your story, its goal and its review point |
| `docs/asset-management-platform-knowledge-base.md` | Product scope, domain model, platform principles, AI design |
| `docs/technical-architecture.md` | Stack, tenancy rules, data in and out, AI architecture, cost |
| `docs/security-model.md` | Security domains, groups, scope, enforcement in Postgres |
| `docs/open-items-tracker.md` | Undecided items (OQ-nn) with current leans |
| `docs/assetly-screens.html` | The UI design. Open it in a browser. Match it where a screen exists |

### Which document wins

Some older text is out of date. When documents disagree:

- `technical-architecture.md` wins over the knowledge base for the stack. The stack is Supabase-first. Ignore any mention of NestJS as the backend.
- `open-items-tracker.md` wins over the knowledge base and the screens for SSO. SSO is Phase 2. Do not build it. Do not show an SSO button.
- `stories-tracker.md` wins over `security-model.md` for build order. Staged policy activation (draft, review, activate) is story 6.4, not Goal 1.
- If the owner tells you something in a session that conflicts with a file, follow the owner and say which file is now out of date.

## 3. Stack

- **Database, auth, storage:** Supabase (managed Postgres, Auth, Storage), region Mumbai (ap-south-1). One shared database for all tenants. One Supabase project per environment, never one per tenant.
- **Frontend:** React, TypeScript (strict), Vite, single-page app, responsive PWA. All visible text goes through i18n. English only for now.
- **Backend logic:** Postgres first (SQL functions, RLS, triggers, `pg_cron`). React calls Supabase directly with the user's token.
- **Custom service:** does not exist until Goal 8. Do not create a `services/` folder, a server, or an API layer before then. The framework and query layer are still open (D1, OQ-28). Do not choose them yourself.
- **Queues, search, vectors, events:** Postgres only (`pg-boss` or `pg_cron`, full-text and trigram, `pgvector`, a transactional outbox table). No Redis, OpenSearch, Kafka, Kubernetes or microservices.
- **Environments:** one hosted staging environment plus local. No production project yet.
- **Portability:** everything is a plain SQL migration in git. Avoid Supabase-only features for core business logic, so a later move to RDS or self-hosting stays a migration, not a rewrite.

## 4. Repository layout

```
apps/web/            React app (Vite)
supabase/
  migrations/        SQL migrations (the only way the schema changes)
  tests/             SQL tests (pgTAP, run with `supabase test db`)
  seed.sql           Local seed
scripts/             Seed and data-generation scripts (not shipped)
docs/                The context files above
.github/workflows/   CI
CLAUDE.md
README.md
```

## 5. Working rules for every session

1. Work on **one story** from `docs/stories-tracker.md`. State the story ID at the start. If the request spans several stories, say so and do one.
2. Do only what the story and its acceptance criteria say. No extra features, no refactors outside the story. Note ideas for the owner at the end instead of building them.
3. Where an open item (OQ-nn) affects the story, use its **current lean** and write down that you did. Do not quietly settle an open item. If the choice changes the schema in a way that is costly to reverse, stop and ask.
4. One migration or one feature per session, with tests. Keep changes small enough for the owner to review.
5. At the end, set the story to `In review` in the tracker, never `Done`. Only the owner marks a story `Done` after the review point is accepted. Add a line to the tracker change log if you added, split, moved or dropped a story.
6. Leave a short **demo note**: what to click or run, and what to expect.
7. List anything in the owner-review areas (section 9) that the change touched.
8. Apply the scope-pressure rules (section 10) when time runs short. Cut from the bottom, never from the foundation.

### Definition of done (every story)

1. SQL migration in git. No dashboard-only changes.
2. RLS and permission tests where the story touches data.
3. UI matches `docs/assetly-screens.html` where a screen exists.
4. TypeScript types regenerated from the schema.
5. Short demo note.
6. The owner reviews anything touching auth, RLS, API keys or file access.

## 6. Tenancy rules (non-negotiable)

1. **Every table carries `tenant_id`**, except platform-level catalog tables such as `security_domain` and `domain_operation`. Those are read-only for tenants.
2. **RLS is on for every table.** No table is reachable without a policy. A table with no policy means no access.
3. The JWT carries `tenant_id` (the active tenant) and a permission-version number. Nothing else about permissions.
4. **Never use the service-role key for user-driven work.** It bypasses RLS. It is for system jobs only (outbox poller, scheduled checks, provisioning). It must never appear in web app configuration.
5. In any custom service (Goal 8 onwards), set tenant context per transaction with `SET LOCAL` (or pass the user's token). Never set it at session level. Pooled connections must not leak tenant context.
6. Keep all database access behind one data layer, so a very large tenant can later move to a dedicated database.
7. Do not expose Supabase's auto-generated API as the public API contract. The public API is a separate, versioned `/v1` API (Goal 9).
8. A cross-tenant test must exist for every tenant table. CI fails if a table with `tenant_id` has RLS off or no policies.

## 7. Security rules

The security model is Workday and Oracle style: domains, groups, policies and scope. Full design is in `docs/security-model.md`. The rules for code:

1. **Default deny. Additive grants.** Access is the union across a user's groups. There are no deny rules.
2. **Enforce in the database**, never only in the UI. A bug in a screen, the API or the AI assistant must not be able to show data the user may not see.
3. **One engine for everything:** UI, public API, integration users, exports and the AI assistant resolve to a user or integration identity and hit the same checks.
4. Table policies check the tenant and `has_permission(domain, operation)`. Insert, update and delete have **separate policies** with `WITH CHECK`. Writes also require `tenant_can_write()`.
5. Policies read the precomputed `user_effective_permission` table, never the raw policy graph.
6. Helper functions live in the `private` schema, are `STABLE` where possible, and have a **fixed `search_path`**. Use `(select auth.uid())` so Postgres evaluates it once per query.
7. **Columns:** RLS cannot hide columns. Sensitive fields (purchase value, contract rates, vendor tax IDs) are exposed through secure views that return null unless the user holds the field's domain. Custom-field JSONB is filtered per key by each field definition's domain.
8. **Actions** (transfer, retire, import commit, and similar) are database functions that check their action domain. They are not open table writes.
9. Security policies, assignments and group changes are audited. Policy mistakes are data leaks, so every security change needs a test.
10. Domains are data, not code. Adding a domain is a migration that seeds a row. It is never a code change in a policy.

### The RLS pattern

*To be written in story 1.4.* The sample table and its policies become the template to copy for every new table. Until then, do not create business tables.

## 8. Data rules

- **Identifiers:** `uuid` primary key named `id`. Foreign keys are `<entity>_id`.
- **Time:** all timestamps are `timestamptz` stored in UTC. Display in the tenant's time zone.
- **Money:** store the amount with a currency code. No currency conversion in Phase 1. Totals show per currency.
- **Do not hard-code India.** Tenant-level currency, locale, time zone and date format. GSTIN and PAN are optional configurable vendor fields, not columns with special logic.
- **Deletes:** soft delete everywhere (`deleted_at`). Disposed assets stay as history and are never hard-deleted. Vendors, locations and categories are deactivated, never deleted. A merge function repoints references and writes an audit entry.
- **Custom fields:** definitions in tables, values in JSONB on the record. No per-tenant schema changes.
- **Categories, types and statuses are data**, not enums in code, except fixed system lifecycles such as asset status.
- **Audit and events:** audit rows and outbox events are written in the **same transaction** as the data change. The audit log is append-only.
- **Telemetry** never goes in the core transactional tables.

## 9. Owner reviews personally

Never treat these as finished without the owner's review. Flag them in your end-of-session note:

- Auth (login, sessions, JWT hook, Auth settings)
- RLS policies and permission helper functions
- API keys and webhook signing
- File access (storage policies, signed URLs)
- Generated security policies and starter group seeds

## 10. Scope-pressure rules

1. Cut P3 and "Could" items first. Never cut P0.
2. Never ship an AI feature without the AI gateway, a human review step and a manual fallback.
3. Keep mandatory fields minimal by default.
4. Do not start P1 or P2 work before the metadata engine (Goal 2) is stable.

## 11. AI rules (from Goal 10)

- All model calls go through the AI gateway: entitlement check, metering, logging, rate limits, retries, provider fallback. No direct model calls anywhere else.
- AI suggests, humans confirm. Nothing is committed silently. AI-filled fields are marked "AI-suggested" with source and confidence.
- Deterministic code does the checks (types, required fields, duplicates). AI does the fuzzy parts.
- Query-based insights: the model returns a **structured query** (JSON) against the semantic layer. **Never raw SQL.** A deterministic compiler produces parameterised SQL under the user's own permissions. Fields in domains the user cannot view are never offered to the model.
- Treat text from imported files as untrusted data, never as instructions.
- No training on customer data.
- Hide "Ask Assetly" and the Intelligence group when the tenant has no AI entitlement.

## 12. Conventions

### Database

- Tables: singular `snake_case` (`tenant`, `security_group`, `audit_log`). Columns: `snake_case`.
- Standard columns on tenant tables: `id`, `tenant_id`, `created_at`, `updated_at`, `created_by`, `updated_by`, `deleted_at`.
- Helper and internal functions in the `private` schema. Public functions are callable actions only.
- Migrations: created with `supabase migration new <story-id>_<what>`, for example `1_1_tenant_core`. One purpose per migration. Never edit a migration that has been applied to staging. Add a new one.
- Seed data for the catalog (security domains, operations) is a migration, and re-running it must not create duplicates.
- Types: regenerate after every schema change. CI fails when the committed types are stale.

### Code

- TypeScript `strict`. No `any` without a comment saying why.
- Design tokens (colours, type, radii, spacing, status tag colours) live in one file and match the screens: primary teal `#0B6E6E`, IBM Plex Sans.
- Every visible string comes from the translation file.
- Routes and page titles follow the screens file.

### Git

- One story per branch: `story/<id>-<short-name>`, for example `story/1.1-tenant-core`.
- Commit messages start with the story ID: `[1.1] Add tenant_membership and JWT hook`.
- Pull requests must pass CI (SQL tests, lint, typecheck, build) before merge.

## 13. Auth rules (Phase 1)

- Email and password only. No SSO. No SSO button.
- Public signup is off. Pilot tenants and users are created by a provisioning script (sales-led, OQ-16).
- "Forgot password" is hidden until email sending exists. It is in the backlog.
- Wrong credentials show one generic message that does not reveal whether the email exists.
- Users hold all roles assigned to them in the active tenant combined. There is no role selection at login.

## 14. Do not

- Do not build a custom session or token store, and do not hand-roll auth. Use Supabase Auth's own session handling.
- Do not make dashboard-only changes to the schema, policies or Auth settings.
- Do not add a dependency without saying why in the end-of-session note.
- Do not store secrets in git. `.env.example` lists every variable.
- Do not write to or read from another tenant's data in tests except through the test harness built for that.
- Do not "fix" a failing security test by weakening the policy or the test without telling the owner.
