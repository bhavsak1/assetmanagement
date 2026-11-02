# Goal 8 data model: custom service skeleton (story 8.1)

**Status:** design, waiting for the owner's answers to §10 (DECIDE G1 to G10). Nothing built yet.

**Goal:** a small TypeScript service runs on Cloud Run staging. It has a health endpoint and one authenticated endpoint that proves RLS works through the service. A test proves pooled connections never leak tenant context. CI lints, typechecks, tests and builds the Docker image.

**Already decided, not reopened:**
1. Host (owner, 2 Nov 2026, OQ-28): Google Cloud Run from a Docker image, scale to zero, $0 target with no customers. Staging `asia-northeast1` (Tokyo, next to Supabase staging `blhxyfgkkhpqbfuhpnww`). Production later `asia-south1` (Mumbai). Fallback Fly.io Singapore. No always-on machine: `pg_cron` or Cloud Scheduler calls the service. Cloud NAT and a static egress IP only when a customer asks.
2. CLAUDE.md §6.4 to §6.6: no service-role key for user-driven work; tenant context per transaction (`SET LOCAL`) or the user's token, never per session; all database access behind one data layer.
3. CLAUDE.md §6.7: the public contract is `/v1`, built in Goal 9. 8.1 does not use the `/v1` prefix.

**Reads with:** technical-architecture.md §2, §5, §6; security-model.md; CLAUDE.md §3, §6, §14.

**Open items used:** D1 and OQ-28 (framework, query layer). Leans below; the owner decides in §10.

**Facts checked (2 Nov 2026):**
- `private.current_tenant_id()` reads `auth.jwt() ->> 'tenant_id'`, and `auth.jwt()` reads the setting `request.jwt.claims`. So any connection that sets that setting and the role `authenticated` gets the same RLS as PostgREST.
- Staging signs tokens with **ES256** (asymmetric). Its public keys are at `https://blhxyfgkkhpqbfuhpnww.supabase.co/auth/v1/.well-known/jwks.json`. The service can verify tokens with no secret.
- The local stack signs with the legacy HS256 secret unless `[auth] signing_keys_path` is set (`supabase/config.toml`).
- CI already runs Node 24. Node 24 runs `.ts` files directly (type stripping), so the service needs no build step.

---

## 1. Framework and query layer

| Option | For | Against |
|---|---|---|
| **Hono** | Tiny, web-standard `Request`/`Response`, typed routes, built-in middleware (CORS, request id, body limit). Same code runs on Node, Workers or Deno, so the Fly.io fallback or an edge move is free | Smaller ecosystem than Fastify |
| Fastify | Mature, fast, big plugin set, JSON schema validation | Node only; plugin style is more ceremony |
| NestJS | Enforced structure, DI | Heavy boilerplate for a solo builder; slow cold start hurts scale to zero |

**Lean: Hono** (with `@hono/node-server` on Node 24).

| Option | For | Against |
|---|---|---|
| **Plain `pg`** | One small dependency. Full control of `BEGIN`, `set_config`, `COMMIT`. Works with Supavisor transaction mode (unnamed statements only). Import staging uses `unnest` or `COPY`, which `pg` does directly | Hand-written SQL strings; row types written by hand |
| Kysely | Typed SQL builder on top of the same `pg` pool; can be added later without changing the tenant helper | Its types come from a codegen step, a second types file next to `database.ts` |
| Drizzle | Typed, migrations tool | Wants to own the schema and migrations; we keep plain SQL migrations (CLAUDE.md §3 portability) |

**Lean: plain `pg` for 8.1.** Kysely sits on the same pool, so adding it at 8.6 or 9.2 is a small change, not a rewrite.

## 2. How tenant context reaches Postgres

**A. Forward the user's JWT to PostgREST.** The service calls Supabase with `supabase-js` and the user's `Authorization` header. RLS applies with no new database role.
- For: nothing new to secure; the service cannot impersonate anyone.
- Against: no multi-statement transactions (only one RPC per call); bulk staging rows go over HTTP; Goal 9 integration users have no Supabase token, so the service would have to mint JWTs with the signing key, which is a bigger power than option B.

**B. Own database role plus `SET LOCAL` in each transaction (lean).** The service verifies the JWT itself (§3), then for every request runs:

```sql
begin;
set local role authenticated;
select set_config('request.jwt.claims', $1, true);   -- the verified token payload, true = local to this transaction
-- the request's queries
commit;   -- or rollback on any error
```

This is what PostgREST does. Both settings end at `commit` or `rollback`.
- The service logs in as a new role **`assetly_api`**: `login noinherit`, member of `authenticated` only, no grants of its own. `noinherit` means that **outside** `set local role` it holds no rights at all: a forgotten `SET LOCAL` reads nothing (default deny), it does not read everything. It cannot become `service_role` or `postgres`.
- The role is a migration (`8_1_api_role`). Its password is **not** in git: the owner sets it once on staging with `alter role assetly_api password '...'` in the SQL editor and puts the same value in Secret Manager. Locally the seed sets a test password.
- Note: Postgres grants `execute` on new public functions to `PUBLIC`. The base role could call a public action function outside a transaction, but every action checks `auth.uid()` and `has_permission`, which are null and false with no claims. The leak test checks this too.

**One data layer (CLAUDE.md §6.6):** one module `src/db.ts` exports `withUser(claims, fn)`. Routes never get the pool. The pool is the only `pg` object in the service.

**Pooling.** The direct Supabase host is IPv6 only and Cloud Run's default egress is IPv4 (to verify at build), so the service goes through **Supavisor in transaction mode** (port 6543, user `assetly_api.blhxyfgkkhpqbfuhpnww`). Transaction mode hands the server connection back at each `commit`, which is exactly why every context setting must be transaction-local. `pg` sends unnamed statements unless given a name; the code never names one (named prepared statements break in transaction mode). Pool size in the service: 5 per instance, max instances 2 (§6), so at most 10 client connections.

**Leak test (`services/api/test/tenant-leak.test.ts`), against the local stack with a pool of size 1** (stricter than Supavisor: one physical connection is reused by every request):
1. 50 requests run at the same time, alternating user A (tenant A) and user B (tenant B). Each answer names only its own user and tenant.
2. A request whose query throws mid-transaction is followed by one for the other tenant: the second sees only its own tenant.
3. After all requests, a raw query on the same connection shows `current_user = 'assetly_api'`, `current_setting('request.jwt.claims', true)` empty, and `select from public.tenant` fails with `permission denied`.
4. A token for user A with `tenant_id` of tenant B (not a member) sees no tenant row: RLS, not the service, refuses it.

## 3. Verifying the token

The service must check the token itself, since Postgres trusts whatever claims the service sets. It uses `jose` with the project's JWKS (cached in memory, refreshed on an unknown `kid`), and checks signature, `exp`, `iss = <SUPABASE_URL>/auth/v1`, `aud = authenticated`, `role = authenticated`. Anything else is `401` with one generic message.

Local dev and CI need the same path: one-time `npx supabase gen signing-key` (ES256; exact flags checked at build) into `supabase/signing_keys.json` (git-ignored), and `signing_keys_path = "./signing_keys.json"` in `config.toml`. CI generates the file before `supabase db start`. Tests then sign in through the local Auth API and use real tokens. This is an Auth setting, so the owner reviews it (G4).

## 4. The service-role key

Not used in 8.1 at all. The service holds one secret: the `assetly_api` database URL, in **Secret Manager** (`assetly-api-db-url`), mounted as the env var `DATABASE_URL` by Cloud Run. It never appears in `.env.example` values, the web config, the image or the repo.

System jobs (9.1 outbox poller) need rights beyond one user. Lean: a second role `assetly_jobs` with grants only on the tables a job touches, in its own Secret Manager entry, instead of the service-role key (the key is a PostgREST JWT; the service talks to Postgres directly). That is a 9.1 decision; 8.1 only leaves room for it.

## 5. Layout, local dev, CI

```
services/api/
  Dockerfile           node:24-slim, npm ci --omit=dev, runs src/index.ts
  package.json         own lockfile, like apps/web
  tsconfig.json        strict, noEmit, erasableSyntaxOnly
  eslint.config.js
  src/index.ts         reads env, starts the server
  src/app.ts           Hono routes: GET /health, GET /me
  src/auth.ts          JWT verification (jose, JWKS)
  src/db.ts            pg pool and withUser() (the one data layer)
  test/*.test.ts       node:test, real local Supabase
supabase/migrations/   8_1_api_role
.github/workflows/     ci.yml gains an api job; deploy-api.yml is new
```

CLAUDE.md changes: §4 gains `services/api/  Custom service (Goal 8 on): import, later /v1 API, webhooks, AI gateway`; §3 "Custom service" says it exists from 8.1 and names the choices from §10.

**Local dev:** `npm run db:start`, then in `services/api`: `npm run dev` (`node --watch --env-file=.env src/index.ts`). `.env.example` gains `DATABASE_URL` (local `assetly_api` URL on port 54322), `SUPABASE_URL` and `PORT`.

**CI:**
- New `api` job (no database): `npm ci`, `lint`, `typecheck`, `docker build`.
- The existing `db` job, after `supabase test db`: `npm ci` and `npm test` in `services/api` against the running stack. Reuses the started stack, so no second Supabase start.

**Deploy (`deploy-api.yml`):** GitHub Actions authenticates with **Workload Identity Federation** (`google-github-actions/auth`, no JSON key), builds the image, pushes to Artifact Registry `asia-northeast1-docker.pkg.dev/<project>/assetly/api:<sha>`, then:

```
gcloud run deploy assetly-api --region asia-northeast1 --image ...:<sha> \
  --service-account assetly-api-run@<project>.iam.gserviceaccount.com \
  --set-secrets DATABASE_URL=assetly-api-db-url:latest \
  --set-env-vars SUPABASE_URL=https://blhxyfgkkhpqbfuhpnww.supabase.co \
  --min-instances 0 --max-instances 2 --cpu 1 --memory 512Mi --concurrency 40 \
  --cpu-throttling --allow-unauthenticated
```

`--allow-unauthenticated` lets the request reach the service; the service then checks the Supabase JWT. Google's own IAM auth cannot read Supabase tokens.

## 6. Endpoints

| Route | Auth | Returns |
|---|---|---|
| `GET /health` | none | `{"ok":true}`. No database call, so health checks never wake Postgres or cost a connection |
| `GET /me` | Supabase JWT | `{"user_id","tenant_id","tenant_name"}`. `user_id` and `tenant_id` come from `auth.uid()` and `private.current_tenant_id()` inside Postgres, and `tenant_name` from `public.tenant` **through RLS**. Not a member of the token's tenant: `403` |

No CORS in 8.1 (only `curl` calls it). 8.2 adds it with an allowlist when the web app first calls the service.

## 7. Logs and budget

- One JSON line per request on stdout: time, request id, method, path, status, ms, user id, tenant id. Never the token or the database URL. Cloud Run ships stdout to Cloud Logging with no setup; default retention 30 days, first 50 GiB per project per month free.
- Budget alert: the owner creates it (§9). Lean: $5 per month on the project, emails at 50, 90 and 100 percent. A budget only warns, it does not stop spend; `--max-instances 2` is the hard cap.
- Expected cost with no customers: $0. Cloud Run's free tier (2 million requests, 180,000 vCPU-seconds, 360,000 GiB-seconds per month) covers it; Artifact Registry keeps 0.5 GB free (keep the last 5 images); Secret Manager covers 6 secret versions and 10,000 reads free. Egress to Supabase is internet egress, a few cents per GB. Free-tier figures are from Google's pricing pages as I recall them; verify on the GCP billing page before the first customer.

## 8. The smaller option: no service for import

Parse Excel **in the browser** (for example SheetJS), and send rows in chunks to Postgres functions (`import_stage_rows`, then validate and commit functions, all `security invoker` or action-checked). 8.1 would then move to the start of Goal 9.

| | Service parses (lean) | Browser parses |
|---|---|---|
| Cost now | Cloud Run, $0 at this size | $0, nothing to host |
| Moving parts | One more deploy, one secret, a new DB role | None new |
| Large files, cheap phones | Streaming parse on the server | A 20,000-row file can stall a phone |
| Goal 9 (`/v1` bulk import by API) | Same parser and staging code | A second parser on the server anyway |
| Goal 10 (AI mapping) | The gateway is server-side; it reads staged rows directly | Browser sends samples to the gateway; still needs the service |
| Security | New identity path to review (§2, §3) | No new path; RLS as today |

Goals 9 and 10 need the service anyway, so the browser option only delays it, and builds the parser twice. **Lean: service parses.** Choose the browser option if you want Goal 8 shipped with zero new infrastructure and accept a second parser in Goal 9.

## 9. Owner steps on GCP (after §10 is answered; I never handle your credentials)

Console: create a project (for example `assetly-staging`), link billing, then **Billing > Budgets & alerts > Create budget**: scope the project, $5 per month, thresholds 50/90/100 percent, email to you.

Then in Cloud Shell (replace `PROJECT`):

```bash
gcloud config set project PROJECT
gcloud services enable run.googleapis.com artifactregistry.googleapis.com secretmanager.googleapis.com iamcredentials.googleapis.com sts.googleapis.com
gcloud artifacts repositories create assetly --repository-format=docker --location=asia-northeast1
gcloud iam service-accounts create assetly-api-run
gcloud iam service-accounts create assetly-api-deploy
PN=$(gcloud projects describe PROJECT --format='value(projectNumber)')
gcloud iam workload-identity-pools create github --location=global
gcloud iam workload-identity-pools providers create-oidc github --location=global --workload-identity-pool=github \
  --issuer-uri=https://token.actions.githubusercontent.com \
  --attribute-mapping=google.subject=assertion.sub,attribute.repository=assertion.repository \
  --attribute-condition="assertion.repository=='bhavsak1/assetmanagement'"
gcloud iam service-accounts add-iam-policy-binding assetly-api-deploy@PROJECT.iam.gserviceaccount.com \
  --role=roles/iam.workloadIdentityUser \
  --member="principalSet://iam.googleapis.com/projects/$PN/locations/global/workloadIdentityPools/github/attribute.repository/bhavsak1/assetmanagement"
gcloud projects add-iam-policy-binding PROJECT --role=roles/run.developer --member=serviceAccount:assetly-api-deploy@PROJECT.iam.gserviceaccount.com
gcloud artifacts repositories add-iam-policy-binding assetly --location=asia-northeast1 --role=roles/artifactregistry.writer --member=serviceAccount:assetly-api-deploy@PROJECT.iam.gserviceaccount.com
gcloud iam service-accounts add-iam-policy-binding assetly-api-run@PROJECT.iam.gserviceaccount.com --role=roles/iam.serviceAccountUser --member=serviceAccount:assetly-api-deploy@PROJECT.iam.gserviceaccount.com
```

After the `8_1_api_role` migration is on staging: set the role password in the Supabase SQL editor, then store the URL (you type it; it never goes to chat or git):

```bash
gcloud secrets create assetly-api-db-url --replication-policy=user-managed --locations=asia-northeast1
gcloud secrets versions add assetly-api-db-url --data-file=-   # paste postgres://assetly_api.blhxyfgkkhpqbfuhpnww:PASSWORD@<pooler host>:6543/postgres, then Ctrl-D
gcloud secrets add-iam-policy-binding assetly-api-db-url --role=roles/secretmanager.secretAccessor --member=serviceAccount:assetly-api-run@PROJECT.iam.gserviceaccount.com
```

Then give me the project ID and project number (not secrets); I put them in `deploy-api.yml` as plain values.

## 10. DECIDE

| # | Decision | Options | Lean | Cost to reverse |
|---|---|---|---|---|
| G1 | Framework | a Hono, b Fastify, c NestJS | a | Medium: routes and middleware rewritten; data layer kept |
| G2 | Query layer | a plain `pg`, b Kysely, c Drizzle | a, revisit at 8.6 or 9.2 | Low: Kysely runs on the same pool |
| G3 | Tenant context | a own role `assetly_api` (noinherit, member of `authenticated` only) plus `SET LOCAL` per transaction, b forward the JWT to PostgREST | a | Medium: the data layer changes; routes do not |
| G4 | Token check | a JWKS only, ES256 locally too (git-ignored local key, CI generates one), b call `/auth/v1/user` every request, c JWKS on staging and HS256 secret locally | a | Low: one module |
| G5 | Staging DB connection | a Supavisor transaction mode (6543), b session mode (5432), c direct (needs IPv6 and a VPC) | a | Low: the URL |
| G6 | Runtime | a Node 24 runs TypeScript directly, `tsc` only typechecks, b compile to JS in the image | a | Low |
| G7 | Deploy trigger | a manual (`workflow_dispatch`), like the staging db push, b on every push to `main` that touches `services/api` | a, since the service can depend on a migration that is pushed by hand | Low: one line |
| G8 | Import parse | a in the service (8.2), b in the browser, service moves to Goal 9 (§8) | a | Medium: 8.2 to 8.6 change shape |
| G9 | Service-role key | a not in the service; system jobs later get an `assetly_jobs` role (9.1), b store the key in Secret Manager now | a | Low |
| G10 | Who-am-I route | a `GET /me`, outside `/v1`, b `GET /v1/me` | a, `/v1` stays the Goal 9 contract | Low |

## 11. Build plan (after answers)

1. Migration `8_1_api_role`; local seed sets its test password; pgTAP test: the role is `noinherit`, member of `authenticated` only, and has no table grants.
2. `services/api` (§5), `/health` and `/me`, the tests in §2.
3. CI `api` job and the test step in the `db` job; local signing key (G4).
4. `deploy-api.yml`; deploy to staging once §9 is done and the owner pushes the migration.
5. CLAUDE.md §3 and §4, `.env.example`, 8.1 `In review`, PR, demo note.

## 12. Not in 8.1

- CORS and any web app call to the service (8.2).
- The `/v1` prefix, API keys, integration users (9.2).
- System-job role, outbox poller, Cloud Scheduler (9.1).
- Production project in `asia-south1`, custom domain, Cloud NAT and static egress IP.
- Sentry or tracing (technical-architecture.md §2.2 lists Sentry; add when there is traffic).
