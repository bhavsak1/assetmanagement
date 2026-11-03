# Goal 8 data model: custom service skeleton (story 8.1)

**Status:** built 2 Nov 2026; deployed and verified on staging 2 Nov 2026 (`/health` ok, `/me` with a real token returns the user and tenant as `assetly_api` under RLS); 8.1 Done 2 Nov 2026. Decided 2 Nov 2026. The owner chose **Fastify** for G1 (after a wider framework comparison with a long-term enterprise view: maturity, OpenJS Foundation governance, official plugins, Node streams; Hono's run-anywhere strength is unused on Cloud Run) and accepted the leans for G2 to G10.

**Goal:** a small TypeScript service runs on Cloud Run staging. It has a health endpoint and one authenticated endpoint that proves RLS works through the service. A test proves pooled connections never leak tenant context. CI lints, typechecks, tests and builds the Docker image.

**Already decided, not reopened:**
1. Host (owner, 2 Nov 2026, OQ-28): Google Cloud Run from a Docker image, scale to zero, $0 target with no customers. Staging `asia-northeast1` (Tokyo, next to Supabase staging `blhxyfgkkhpqbfuhpnww`). Production later `asia-south1` (Mumbai). Fallback Fly.io Singapore. No always-on machine: `pg_cron` or Cloud Scheduler calls the service. Cloud NAT and a static egress IP only when a customer asks.
2. CLAUDE.md §6.4 to §6.6: no service-role key for user-driven work; tenant context per transaction (`SET LOCAL`) or the user's token, never per session; all database access behind one data layer.
3. CLAUDE.md §6.7: the public contract is `/v1`, built in Goal 9. 8.1 does not use the `/v1` prefix.

**Reads with:** technical-architecture.md §2, §5, §6; security-model.md; CLAUDE.md §3, §6, §14.

**Open items used:** D1 and OQ-28, decided by the owner 2 Nov 2026 (§10): Fastify, plain `pg`.

**Facts checked (2 Nov 2026):**
- `private.current_tenant_id()` reads `auth.jwt() ->> 'tenant_id'`, and `auth.jwt()` reads the setting `request.jwt.claims`. So any connection that sets that setting and the role `authenticated` gets the same RLS as PostgREST.
- Staging signs tokens with **ES256** (asymmetric). Its public keys are at `https://blhxyfgkkhpqbfuhpnww.supabase.co/auth/v1/.well-known/jwks.json`. The service can verify tokens with no secret.
- The local stack signs with the legacy HS256 secret unless `[auth] signing_keys_path` is set (`supabase/config.toml`).
- CI already runs Node 24. Node 24 runs `.ts` files directly (type stripping), so the service needs no build step.

---

**As built (differences from the design below):**
- Role and claims are set in one statement: `select set_config('role', 'authenticated', true), set_config('request.jwt.claims', $1, true)`, as PostgREST does. Same effect as `set local role`.
- The local signing key is made by `scripts/gen-signing-key.mjs` (`npm run db:signing-key`), not `supabase gen signing-key`: the CLI command fails once `config.toml` points at a file that does not exist yet.
- CI starts Auth and the REST gateway too (`supabase start -x ...` instead of `db start`), since the service tests sign in for real tokens.
- The deployer service account needs `roles/run.admin`, not `run.developer`: `--allow-unauthenticated` sets the service's IAM policy.
- pgTAP checks rights with `has_table_privilege` and `pg_has_role` rather than `set role assetly_api` (pgTAP functions are not callable as that role).
- Tests: `supabase/tests/8_1_api_role.test.sql` (6) and `services/api/test` (9, Node's own test runner). Mutation check: making the settings session-level fails the leak test.

## 1. Framework and query layer

| Option | For | Against |
|---|---|---|
| **Hono** | Tiny, web-standard `Request`/`Response`, typed routes, built-in middleware (CORS, request id, body limit). Same code runs on Node, Workers or Deno, so the Fly.io fallback or an edge move is free | Smaller ecosystem than Fastify |
| Fastify | Mature, fast, big plugin set, JSON schema validation | Node only; plugin style is more ceremony |
| NestJS | Enforced structure, DI | Heavy boilerplate for a solo builder; slow cold start hurts scale to zero |

Earlier lean: Hono. **Decided: Fastify** (G1), on Node 24.

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
  src/app.ts           Fastify routes: GET /health, GET /me
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
echo '[{"name":"keep-3","action":{"type":"Keep"},"mostRecentVersions":{"keepCount":3}},{"name":"delete-rest","action":{"type":"Delete"},"condition":{"tagState":"any"}}]' > /tmp/cleanup.json
gcloud artifacts repositories set-cleanup-policies assetly --location=asia-northeast1 --policy=/tmp/cleanup.json --no-dry-run
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
gcloud projects add-iam-policy-binding PROJECT --role=roles/run.admin --member=serviceAccount:assetly-api-deploy@PROJECT.iam.gserviceaccount.com
gcloud artifacts repositories add-iam-policy-binding assetly --location=asia-northeast1 --role=roles/artifactregistry.writer --member=serviceAccount:assetly-api-deploy@PROJECT.iam.gserviceaccount.com
gcloud iam service-accounts add-iam-policy-binding assetly-api-run@PROJECT.iam.gserviceaccount.com --role=roles/iam.serviceAccountUser --member=serviceAccount:assetly-api-deploy@PROJECT.iam.gserviceaccount.com
```

After the `8_1_api_role` migration is on staging: set the role password in the Supabase SQL editor, then store the URL (you type it; it never goes to chat or git):

```bash
gcloud secrets create assetly-api-db-url --replication-policy=user-managed --locations=asia-northeast1
gcloud secrets versions add assetly-api-db-url --data-file=-   # paste postgres://assetly_api.blhxyfgkkhpqbfuhpnww:PASSWORD@<pooler host>:6543/postgres, then Ctrl-D
gcloud secrets add-iam-policy-binding assetly-api-db-url --role=roles/secretmanager.secretAccessor --member=serviceAccount:assetly-api-run@PROJECT.iam.gserviceaccount.com
```

Then in GitHub: **Settings > Secrets and variables > Actions > Variables**, add `GCP_PROJECT_ID` and `GCP_PROJECT_NUMBER` (not secrets). Run **Actions > Deploy API (staging) > Run workflow**. Its last step calls `/health`.

## 10. DECIDE

| # | Decision | Options | Lean | Cost to reverse |
|---|---|---|---|---|
| G1 | Framework | a Hono, b Fastify, c NestJS | **b (owner)** | Medium: routes and middleware rewritten; data layer kept |
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

---

# Story 8.2: upload and streaming parse into staged rows

**Status:** owner accepted all leans I1 to I13 (3 Nov 2026). Built 3 Nov 2026, 8.2 In review. Not on staging yet.

**As built (differences from the design below):**
- `import_row.batch_id` is a **deferred** FK. The service inserts rows first (chunks of 1,000) and the batch row last, with its final row count, columns and warnings, so users never need an update grant.
- `warnings` is `{"list": [...], "total": n}`: the first 50 warnings are kept, `total` counts all of them. Codes: `cell_truncated`, `error_cell`, `beyond_header` (data right of the header; the column is named `Column F`).
- Zip limits: at most 1,000 entries; a sheet may inflate to 100 MB (streamed); shared strings, styles and the workbook part to 30 MB each (held in memory). Checked on the declared size and on the characters actually read; `yauzl` also refuses an entry whose real size differs from the declared one. The 100-to-1 ratio check was dropped: the size caps already bound memory, and real sheets with repeated cells pass 100 to 1.
- `.xlsm` is not refused by name: the route accepts `.xlsx` names only, and macros are never read anyway.
- Error codes from `POST /imports`: 401 `unauthorized`, 403 `forbidden` (RLS: no `excel_import.run`, or a read-only tenant), 413 `file_limits` / `too_many_rows` / `too_many_columns` (and Fastify's own 413 over 10 MB), 415 `not_xlsx`, 400 `bad_file` / `no_data` / `sheet_not_found`, 429 `busy`.
- The purge job is `assetly_purge_expired_imports`, daily at 03:17 UTC.
- technical-architecture.md §3 calls the staging table `import_row_result`; it is `import_row`.
- Tests: `supabase/tests/8_2_import_staging.test.sql` (42), `services/api/test/xlsx.test.ts` (12, no database), `services/api/test/imports.test.ts` (10), `apps/web/src/Import.test.tsx` (2). Fixture files are built in code (`test/fixture.ts`, a small zip writer); none are committed.

**Goal:** a user with `excel_import.run` picks an Excel file in the web app. The service checks it, reads one sheet as a stream, and writes one `import_batch` row and one `import_row` per data row, under RLS. The web app shows the batch: file, sheet, header row, columns, row count, warnings. Nothing touches assets. Mapping (8.3), validation and dry run (8.4), the review screen (8.5), commit and undo (8.6) come later.

**Facts checked (3 Nov 2026):**
- The catalog already has action domain `excel_import` with operations `run` (1), `review` (2), `commit` (3), and `import_undo.undo`. Starter groups: Administrator and Asset manager hold run, review, commit; Maintenance lead holds run, review. No new domain is needed.
- `exceljs` 4.4.0 is its latest release (Oct 2023); its stream reader pulls in `unzipper`, `archiver`, `jszip`, `tmp` and more. `xlsx` (SheetJS) on npm is stuck at 0.18.5 with known advisories; newer builds are only on SheetJS's own CDN, and it loads the whole workbook into memory. `yauzl` 3.4.0 (Jun 2026) and `saxes` 6.0.0 are small with few dependencies.
- An `.xlsx` is a zip whose directory sits at the end of the file, so no parser can read a sheet before the whole file has arrived. "Streaming" here means: the file is held once (at most 10 MB), and the sheet XML is inflated and read as a stream, row by row, never as a whole workbook object.
- Postgres `jsonb` and `text` refuse the NUL character. The parser strips it.

## 13.1 Flow

```
web  --POST /imports (raw .xlsx body, Bearer token)-->  service
service: verify token -> size and zip checks -> pick sheet -> find header row
         -> withUser: insert import_batch, then import_row in chunks of 1,000 (one transaction)
         <-- 201 { batch_id, sheet, sheets, header_row, columns, row_count, warnings }
web  --select import_batch / import_row through Supabase (RLS)-->  shows the summary
```

One transaction: a failed parse leaves no rows. The request body is the file itself (`.xlsx` content type, file name in an `X-File-Name` header), so no multipart library is needed.

## 13.2 Tables (1.4 RLS pattern)

`import_batch`: std columns, `file_name`, `file_size`, `file_sha256`, `sheet_name`, `sheet_names text[]`, `header_row int`, `columns text[]` (header text as found, duplicates renamed `Name (2)`), `row_count int`, `warnings jsonb`, `status text` (`staged` only in 8.2; later stories add their values in their own migrations), `expires_at`.

`import_row`: `id`, `tenant_id`, `batch_id` (composite FK to `import_batch`), `row_number int` (the Excel row number, so errors point at the real row), `cells jsonb` (array aligned with `columns`), `created_at`. No `updated_*` or `deleted_at` in 8.2: rows are written once; 8.3 and 8.4 add their columns (mapped values, errors) in their own migrations.

Cell values in `cells`: text as text, numbers as numbers, booleans as booleans, date-formatted numbers as ISO `YYYY-MM-DD` (with time if the format has one), error cells (`#N/A`) as null plus a warning. Formulas are never evaluated: only the value Excel saved with the file is read.

Policies (domain `excel_import`):
- select on both: tenant and `has_permission('excel_import', 'run')` or `'review'`. All importers in a tenant see each other's batches (a reviewer needs them).
- insert on both: tenant, `run`, `tenant_can_write()`.
- No update or delete policy in 8.2; `revoke delete, truncate`. Later stories change rows through action functions.
- Cross-tenant harness lines for both tables, plus one block per permission step.

## 13.3 Untrusted content (CLAUDE.md §11)

- **Zip bomb:** refuse more than 1,000 zip entries, a part that inflates past 100 MB, or a compression ratio over 100 to 1. Counted on the bytes actually inflated, not the sizes the zip claims.
- **Oversized sheet:** stop at the row limit (I2) with a clear message; at most 200 columns; a cell over 4,000 characters is cut and a warning names the row and column.
- **Formula injection:** a cell such as `=HYPERLINK(...)` is stored as the text it is and never run. Escaping (a leading `'`) happens on export, in the "Download errors" file (8.5) and any later CSV export, not at import, so real values like `-5` or `+91 98...` stay intact. A test fixture with such cells is kept for the later export test.
- **XML:** the SAX reader never expands entities; a `<!DOCTYPE` in any part refuses the file.
- **Other:** the first bytes must be a zip (`PK`) whatever the name says; macros in `.xlsm` are never run (the type is refused); NUL and other control characters except tab and newline are stripped.
- Cell text is data. Nothing in 8.2 sends it to a model (AI mapping is Goal 10, through the gateway).

## 13.4 Service changes

- `POST /imports`: auth as `/me`; `bodyLimit` 10 MB on this route only; at most 3 parses at once per instance, else `429` (bounds memory on a 512 MiB instance).
- `src/xlsx.ts`: the reader (zip, shared strings, styles for date formats, one sheet as a row stream) with the limits in §13.3. Tests build small fixture files in code, plus a zip bomb and a 20,001-row sheet.
- CORS: allowlist from env `CORS_ORIGINS` (local `http://localhost:5173`, staging `https://assetly-staging.pages.dev`), method `POST`, headers `Authorization`, `Content-Type`, `X-File-Name`. No cookies: the token goes in the header.

## 13.5 Web changes

- `VITE_API_URL` in `.env.example` and the Pages settings.
- Sidebar "Import" (already in the screens) opens `/import`: a file picker, an upload progress bar, then the batch summary (file, sheet, header row, columns, row count, warnings, first 20 rows). Recent batches below. The full ImportReview screen (stepper, mapping, AI column) is 8.5.
- Hidden without `excel_import.run`.

## 13.6 Hooks left for later (and nothing more)

- `import_batch.status`: 8.3 to 8.6 add `mapped`, `validated`, `committed`, `undone`.
- `import_row.row_number` and `cells`: 8.4 adds error columns, 8.6 links each row to the asset it made.
- A job runner (I7 b) can replace the in-request parse with no schema change: the batch already has a status.

## 13.7 Not in 8.2

Column mapping and templates, validation, dry run, commit, undo, the ImportReview screen, `.xls`, `.ods` and `.csv`, AI anything, a job queue, `/v1`.

## 13.8 The smaller option

Take the `exceljs` stream reader as is: no zip-bomb counting, first sheet and row 1 as header always. About half the code, but a crafted file can exhaust a small instance, and a messy file with a title row above the header stages the title as the header. Not recommended for untrusted uploads.

## 13.9 DECIDE

| # | Decision | Options | Lean | Cost to reverse |
|---|---|---|---|---|
| I1 | File types | a `.xlsx` only, b `.xlsx` and `.csv`, c also `.xls` (old binary) | a. CSV adds a second reader and encoding guesswork (Excel saves CSV in the PC's code page); a small story if pilots ask | Low: additive |
| I2 | Limits | a 10 MB, 20,000 data rows, 200 columns, 4,000 chars per cell, b 25 MB and 100,000 rows | a. SME registers are hundreds to a few thousand rows; bigger needs a job (I7 b) | Low: constants |
| I3 | Sheet | a first visible sheet with data; the response lists all sheet names and the user can re-upload with `?sheet=`, b always the first sheet, c user picks before the parse | a | Low |
| I4 | Header row | a the row with the most non-empty text cells among the first 20 (skips title rows); stored on the batch, 8.3 can override, b always row 1 | a | Low: one function |
| I5 | Parser | a `yauzl` + `saxes` (two small dependencies) and about 200 lines of our own reader with exact zip-bomb limits, b `exceljs` stream reader (big dependency tree, last release 2023, no zip-bomb limits), c SheetJS (CDN-only builds, whole workbook in memory) | a: smallest trust surface, exact limits, bounded memory | Medium: the reader is one module behind one function |
| I6 | Keep the original file | a no: name, size and SHA-256 on the batch; staged rows are the record, b yes, private `imports` bucket on the 3.6 pattern, 90 days | a. Keeping it needs storage policies, a delete path and a purge job (deleting objects needs the Storage API, not SQL); add when audit asks | Low: additive |
| I7 | Parse in request or job | a in the request, one transaction, b job (`pg-boss`) with status polling | a: 20,000 rows parse in seconds; Cloud Run allows 300 s | Low: status column is there |
| I8 | Progress to the UI | a upload percent from the browser (XHR progress), then "Reading file" until the 201; the summary is read through Supabase, b live parse progress (polling or Realtime) | a | Low |
| I9 | Uncommitted staged rows | a daily `pg_cron` job hard-deletes `import_row` of batches past `expires_at` (created + 30 days, not committed); the batch row stays as history with status `expired`, b keep forever, c 7 days | a. Staged rows are a scratch copy, not business records, so the soft-delete rule does not apply | Low |
| I10 | Writes | a table insert policies with `excel_import.run` (staging is not a business write; commit in 8.6 is the action function), b an action function `import_stage(...)` | a | Low |
| I11 | Audit | a audit trigger on `import_batch` only (one audit row and one outbox event per upload), b also on `import_row` (up to 20,000 audit rows per upload) | a | Low |
| I12 | CORS | a `@fastify/cors` (official plugin) with an env allowlist, b hand-written hook | a: preflight edge cases are easy to get wrong | Low |
| I13 | Cloudflare PR previews | a not allowed (only local and staging), b allow `https://*.assetly-staging.pages.dev` | a: uploads fail on previews; b opens the allowlist to every preview build | Low: env value |

## 13.10 Build plan (after answers)

1. Migration `8_2_import_staging`: tables, policies, triggers, purge job; pgTAP with permission blocks and cross-tenant lines.
2. `src/xlsx.ts` and its tests (fixtures, zip bomb, limits, header detection, dates, NUL).
3. `POST /imports`, CORS, service tests (401, 403 without `run`, 413, 429, staged rows isolated per tenant).
4. Types, web `/import` page, i18n strings, browser check against the local stack.
5. `.env.example`, README, 8.2 `In review`, PR, demo note.

---

# Story 8.3: column mapping step (pluggable) and mapping templates

**Status:** owner accepted all leans M1 to M11 (3 Nov 2026) and added the field list and the download template (§14.8). Built 3 Nov 2026, 8.3 In review. Not on staging yet.

**As built (differences from the design below):**
- Template choice (M6): ties go to the most recently **saved** template (`updated_at`); there is no `last_used_at` column.
- Catalog gates (M3): a field-domain column or custom field is offered only with **view and update** on its domain (the 6.2 write checks ask for both); warranty columns need `coverage_contract.create`. So an Asset manager (financials view only) is not offered Purchase value.
- The insert policy on `import_batch` now also requires `status = 'staged'`: only `import_save_mapping` sets `mapped`. The service stores its suggestion with the batch insert, so no update grant is needed.
- Status lookups (M7) match the status **label or code** (statuses have both, 3.7).
- `mapping` source values: `template`, `rules`, `user` (changed on screen), and `ai` reserved for Goal 10.
- Header-row override (M10) is a list of rows 1 to 20 on the Mapping step; the browser still holds the file, so it re-uploads it with `?header_row=N`. A row outside 1 to 20, or an empty one, is `400 bad_header_row`.
- The zip writer moved from the test fixture to `services/api/src/zip.ts` (the download template uses it); no new dependency.
- Tests: `supabase/tests/8_3_import_mapping.test.sql` (45), `services/api/test/mapping.test.ts` (8), `apps/web/src/Import.test.tsx` (4). `1_6_starter_groups.test.sql` seeds one template row for its tenant-B check.

**Goal:** after upload, the user sees each source column (header text and letter) with a suggested target field, changes any of them, and saves. The mapping is stored on the batch for 8.4. A saved mapping can be kept as a template, and it is applied by itself the next time the headers match. No value checks (8.4), no review grid (8.5), no commit (8.6), no AI (Goal 10).

**Facts checked (3 Nov 2026):**
- Asset columns (3.1): `tag`, `name`, `category_id`, `location_id`, `status_id` (tenant statuses, 3.7), `criticality`, `quantity`, `parent_asset_id`, `serial_number`, `manufacturer`, `model`, `purchase_date`, `purchase_value` and `purchase_currency` (domain `asset_financials`, masked in `asset_view`), `in_service_date`, `oem_vendor_id` and `om_vendor_id` (4.1b), `custom_values`. Warranty lines come through `create_asset_with_warranty` (4.5).
- Custom fields: `field_definition` with `entity = 'asset'`, `key` unique per tenant, each with its own `security_domain_id`. Its select policy needs `category_config.view`, which an importer may not hold.
- Lookups: category has `code` (unique, case-free) and a parent tree; location has `code` (unique) and a tree; vendor has `code` and a unique `lower(name)`; a status has a name.
- Domain `excel_import` (run, review, commit) exists. Administrator, Asset manager and Maintenance lead hold `run`.
- The ImportReview screen shows a stepper (Upload, Mapping, Review, Commit) and a "Column mapping" card: source, target, a confidence tag and "Save as template". The percent tags are AI output (Goal 10).

## 14.1 Flow

```
upload (8.2) --> service: stage rows, then suggest a mapping (template, else rules) --> batch.mapping (status staged)
web /import, Mapping step: user edits --> rpc import_save_mapping(batch, mapping) --> status mapped
                           "Save as template" --> insert import_mapping_template (RLS)
```

## 14.2 The pluggable step

One interface in the service, tried in order until every column has a target:

```ts
type Mapper = (input: { columns: string[]; samples: Cell[][]; catalog: Target[] }) =>
  Promise<{ column: number; target: string; source: 'template' | 'rules' | 'ai'; confidence?: number }[]>
```

8.3 ships `templateMapper` and `rulesMapper`. Goal 10 adds `aiMapper` at the end of the chain, behind the AI gateway and the tenant's entitlement. It only ever sees the catalog the user may see (CLAUDE.md §11). Nothing else changes.

## 14.3 Rules mapper (deterministic)

- Normalise: lower case, `&` to `and`, keep only letters and digits (`Asset Tag No.` becomes `assettagno`).
- Exact match on the target key or label, then on a synonym list in code (English, like the UI). Examples: `assetcode`, `assetid`, `tagno` to tag; `serialno`, `sn` to serial; `make`, `oem` to manufacturer; `site`, `plant`, `area` to location; `supplier` to O&M vendor.
- `srno`, `slno`, `sno` map to **ignore**. In Indian sheets "Sr. No." is the row count, not the serial number.
- Custom fields: exact match on label or key.
- Each target once: the leftmost column wins, later ones get ignore. No fuzzy matching (edit distance). That guess is the AI's job and needs a human.

## 14.4 Storage

- `import_batch.mapping jsonb` (array aligned with `columns`, each `{target, source}`), `mapping_template_id uuid null`; status gains `mapped`.
- `import_mapping_template`: std columns, `name` (unique per tenant while live), `headers text[]` (normalised, file order), `targets jsonb` (normalised header to target), `last_used_at`. 1.4 pattern, soft delete.
- Targets are strings: `tag`, `name`, `category`, `location`, `status`, `criticality`, `quantity`, `parent_tag`, `serial_number`, `manufacturer`, `model`, `purchase_date`, `purchase_value`, `purchase_currency`, `in_service_date`, `oem_vendor`, `om_vendor`, `warranty_start`, `warranty_end`, `custom:<key>`, `ignore`.

## 14.5 Not in 8.3

Value checks and lookup matching (8.4), the review grid and AI column (8.5, Goal 10), commit (8.6), creating categories or locations from a file, other entity types, CSV.

## 14.6 The smaller option

No template table: the browser keeps the last mapping per header set in local storage. About half the work, but templates do not follow the user to another device or a teammate, and "Save as template" on the screen has nowhere real to live.

## 14.7 DECIDE

| # | Decision | Options | Lean | Cost to reverse |
|---|---|---|---|---|
| M1 | Where mapping logic runs | a suggest in the service at upload (behind `Mapper`, §14.2); save through a database action function, b all in the browser, save by table update, c all in SQL functions | a: Goal 10's AI mapper lives in the service next to the gateway; the database still checks every saved target | Low |
| M2 | Target catalog | a SQL function `import_target_catalog()` (security definer, fixed `search_path`): the core list in §14.4 plus active asset custom fields; the service uses it to suggest, the save function to check, b core list in TypeScript, custom fields read by the web app | a: one list, enforced in the database. Definer because `field_definition` needs `category_config.view` | Low |
| M3 | Fields the user cannot view (`purchase_value`, `purchase_currency`, custom fields in restricted domains) | a not offered; the save refuses them; a template entry for one becomes ignore for that user, b offered but written masked | a: an importer who cannot see a value should not set it blind. Masking suits reads, not writes | Low |
| M4 | Save | a `import_save_mapping(batch_id, mapping)` security definer: checks tenant, `excel_import.run`, `tenant_can_write()`, batch `staged` or `mapped`, one entry per column, targets in the user's catalog, each target once, `name` and `category` mapped; sets `mapped`. No update policy on the table, b an update policy on `mapping` | a (CLAUDE.md §7.8). Owner review: definer function | Low |
| M5 | Template rights | a domain `excel_import`: read with `run` or `review`, write with `run`, b new domain `import_template` (view, create, update, delete) with starter group grants | a: no new domain, no starter group change; whoever imports can keep templates | Low: b is additive |
| M6 | Template match | a apply by itself when every non-blank header in the file is in the template (by normalised text, not letter, so moved columns still work); several match: most headers, then most recently used; partial matches listed for the user to pick, b exact header list only, c best overlap above 80% | a | Low: one function |
| M7 | Lookup columns | a one target each; 8.4 matches **category** by code, then name, then path `Utilities / Air compressor`; **location** by code, then name if unique, then path `Plant 2 / Bay 3`; **vendor** by code, then name (case-free); **status** by name. No match is a row error; nothing is created, b separate "by code" and "by name" targets | a | Low |
| M8 | Entity types per file | a assets only (with one warranty line per row, M9), b assets, vendors and locations | a (Phase 1). Vendors and locations are few and entered by hand | Low: the catalog takes an entity later |
| M9 | Warranty columns | a `warranty_start`, `warranty_end` map to one warranty line, committed through the 4.5 path in 8.6, b no warranty in import | a: the screen shows "Warranty end"; it is what SMEs track most | Low |
| M10 | Header-row override | a re-upload with `?header_row=N` (the file is not kept, I6); the old batch stays, b stage every row from row 1 and re-cut in place | a: same as `?sheet=` | Low |
| M11 | Suggestion tag on screen | a "Template", "Matched", "Not mapped"; percents only once the AI mapper exists, b made-up percents now | a | Low |

## 14.8 Field list and download template (owner, 3 Nov 2026)

Both come from `import_target_catalog()`, so a user sees only the fields they may set (M3).

- **Field list** on `/import`: label, Required or Optional (name and category), and how to fill it (category and location by code, name or path; vendor by code or name; status by label or code; dates as an Excel date or `YYYY-MM-DD`; criticality A, B or C). A custom field tied to a category says "Only for some categories".
- **Download template:** `GET /imports/template` (Bearer token) returns an `.xlsx` with one bold, frozen header row: the catalog labels in catalog order. A custom field whose label clashes with another field becomes `Label [key]`, which the rules mapper also knows, so the file maps 100% when uploaded back (tested). Written by our own zip writer (`src/zip.ts`, about 40 lines on `node:zlib`); checked to open in openpyxl. No library added.

## 14.9 Build plan (after answers)

1. Migration `8_3_import_mapping`: batch columns and status, template table (1.4 pattern), `import_target_catalog()`, `import_save_mapping()`; pgTAP with permission blocks, a masked-field case and cross-tenant lines.
2. Service: `src/mapping.ts` (`Mapper`, template and rules mappers, tests), suggest at upload, `?header_row=`.
3. Types, web Mapping step (stepper, column list, target select, save, save as template), i18n, browser check.
4. 8.3 `In review`, PR, demo note.
