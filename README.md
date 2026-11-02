# Assetly

AI-native, multi-tenant asset management platform for small and medium industrial and manufacturing companies.

Read `CLAUDE.md` first. Product, architecture and security context is in `docs/`.

## Setup

Needs Docker Desktop (running) and Node 24. The Supabase CLI is pinned in `package.json`. Run it with `npx supabase`.

```bash
npm install
npm run db:signing-key   # once: local ES256 Auth key, git-ignored (story 8.1)
npm run db:start    # local Supabase stack (first run pulls images)
npm run db:reset    # rebuild the local database from supabase/migrations
npm run db:test     # pgTAP tests in supabase/tests
npm run db:types    # regenerate apps/web/src/types/database.ts. Commit it.
npm run db:stop
```

Copy `.env.example` to `.env`. Local keys come from `npx supabase status`. Never put the service-role key in web config.

### Custom service (`services/api`, story 8.1)

```bash
cd services/api
npm install
cp .env.example .env    # add SUPABASE_ANON_KEY from `npx supabase status -o env`
npm test                # needs the local stack; includes the tenant-leak test
npm run dev             # http://localhost:8080/health, /me with a Bearer token
```

Staging deploy: Actions, "Deploy API (staging)", run manually. Setup steps are in `docs/data-model-goal8.md` §9.

### Schema changes

1. `npx supabase migration new <story-id>_<what>`, for example `1_1_tenant_core`.
2. Write the SQL and a test in `supabase/tests`.
3. `npm run db:reset`, `npm run db:test`, `npm run db:types`.
4. Never edit a migration that is already on staging. Add a new one.

### Staging (hosted, Tokyo)

```bash
npx supabase login
npx supabase link --project-ref <staging-ref>
npx supabase db push
```

`link` asks for the database password. It is not stored in git.

## Staging

- Web app: https://assetly-staging.pages.dev (Cloudflare Pages), against Supabase project `blhxyfgkkhpqbfuhpnww`.
- Deploys: every push to `main` builds and deploys through Cloudflare's Git integration. Pull requests get preview URLs.
- Pages settings: root `apps/web`, build `npm run build`, output `dist`, env `NODE_VERSION=24`, `VITE_SUPABASE_URL`, `VITE_SUPABASE_ANON_KEY` (publishable key only, never service-role). Values live in the Pages dashboard, not git.
- Auth settings: `[remotes.staging]` in `supabase/config.toml`. Preview with `npx supabase config diff --project-ref blhxyfgkkhpqbfuhpnww`, apply with `npx supabase config push --project-ref blhxyfgkkhpqbfuhpnww`.
- Users: no public signup. Add the auth user in the Supabase dashboard (Authentication, Add user, auto-confirm), then give it a tenant and a starter group with the provisioning script.

### Staging provisioning (story 1.6b)

Push in this order. The JWT hook reads Goal 1 tables, so config before migrations breaks every sign-in.

1. `npx supabase db push --dry-run`, then `npx supabase db push`. Migrations only: no seed, test harness or spike script. A pushed migration is frozen; fix it with a new one.
2. Add any new auth users in the dashboard. Edit the user list in `scripts/provision-staging.sql`, then run it as postgres (Supabase MCP `execute_sql`, or psql). It creates the tenants, calls `private.seed_starter_groups`, and adds memberships and group assignments. Re-running it changes nothing. It stops if a user is missing or already in another tenant.
3. `npx supabase config diff --project-ref blhxyfgkkhpqbfuhpnww`, then `npx supabase config push --project-ref blhxyfgkkhpqbfuhpnww`.

Staging test users (one tenant each, until the "Choose company" screen exists):

| User | Tenant | Group |
|---|---|---|
| krunal.bhavsar@assetly.com | STAGING Tenant A | Tenant Admin |
| auditor.a@assetly.com | STAGING Tenant A | Auditor |
| hiya.bhavsar@assetly.com | STAGING Tenant B | Tenant Admin |

The web app does not call `select_tenant()` yet, so a fresh token has no `tenant_id` and tenant data stays hidden until that call and a session refresh.

### Demo tenant (story 5.6)

`scripts/demo-tenant.sql` builds "Demo Manufacturing Pvt Ltd" (slug `demo-manufacturing`; INR, en-IN, Asia/Kolkata): 3 plants and 14 locations, 21 categories with warranty terms and default obligations, two tenant statuses (Standby, Under repair), 8 vendors with contacts and GSTIN, 150 assets, warranties and 4 AMCs (some expiring, expired, never covered), 285 obligations (about 10% overdue, 10% due soon) and about 440 service records. No attachments. Dates are relative to today, so the dashboard stays live until the next run.

It is one all-or-nothing DO block run as postgres. It never creates auth users or handles passwords.

```bash
docker exec -i supabase_db_assetly psql -U postgres -v ON_ERROR_STOP=1 < scripts/demo-tenant.sql
docker exec -i supabase_db_assetly psql -U postgres < scripts/demo-tenant-check.sql
```

On staging, run the same file as postgres (Supabase MCP `execute_sql`, or psql with the DB password), then `scripts/demo-tenant-check.sql`.

- **Reset:** run it again. The old copy is renamed `Demo Manufacturing (retired …)`, slug `demo-manufacturing-r<timestamp>`, suspended, and its memberships disabled (the audit log is append-only, so nothing is deleted). A fresh copy is built.
- **Guard:** it touches only the tenant with slug `demo-manufacturing` and name `Demo Manufacturing Pvt Ltd`, and stops otherwise. It also stops if a demo email is a member of any non-demo tenant.
- **Logins:** add these in the dashboard first (Authentication, Add user, auto-confirm). A missing one is skipped with a NOTICE; run again after adding it.

| User | Group |
|---|---|
| bhavsar.krunal.h+demo-admin@gmail.com | Tenant Admin |
| bhavsar.krunal.h+demo-manager@gmail.com | Plant Manager |
| bhavsar.krunal.h+demo-planner@gmail.com | Planner |
| bhavsar.krunal.h+demo-tech@gmail.com | Technician |
| bhavsar.krunal.h+demo-auditor@gmail.com | Auditor |

### RLS performance spike (story 1.7, local only)

Loads about 1M assets into the local database (about 3 min), then times the RLS queries (about 20 min). Never run it on staging or in CI. Results and plans land in `spike.result`; the write-up is `docs/spike-1-7-rls-performance.md`. `npm run db:reset` removes it all.

```bash
npm run db:reset
cat scripts/spike-1-7/01_setup.sql scripts/spike-1-7/02_data.sql scripts/spike-1-7/03_bench.sql scripts/spike-1-7/04_fixes.sql | docker exec -i supabase_db_assetly psql -U postgres -v ON_ERROR_STOP=1 -q
```

### Scope performance check (story 6.1, local only)

Loads 200k assets into one tenant and times list, count, search and location tiles for a tenant-wide user and three scoped users (about 1.5 min). It runs in one transaction and rolls back. Numbers are in `docs/data-model-goal6.md` §8.

```bash
docker exec -i supabase_db_assetly psql -U postgres -q -v ON_ERROR_STOP=1 < scripts/spike-6-1/bench.sql
```

### CI

`.github/workflows/ci.yml` runs on every pull request: a fresh `db reset`, `supabase test db`, and a check that the committed types match the schema. The web lint, typecheck and build job comes in story 0.3.
