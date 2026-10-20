# Assetly

AI-native, multi-tenant asset management platform for small and medium industrial and manufacturing companies.

Read `CLAUDE.md` first. Product, architecture and security context is in `docs/`.

## Setup

Needs Docker Desktop (running) and Node 24. The Supabase CLI is pinned in `package.json`. Run it with `npx supabase`.

```bash
npm install
npm run db:start    # local Supabase stack (first run pulls images)
npm run db:reset    # rebuild the local database from supabase/migrations
npm run db:test     # pgTAP tests in supabase/tests
npm run db:types    # regenerate apps/web/src/types/database.ts. Commit it.
npm run db:stop
```

Copy `.env.example` to `.env`. Local keys come from `npx supabase status`. Never put the service-role key in web config.

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
- Users: no public signup. Add users in the Supabase dashboard (Authentication, Add user, auto-confirm) until the provisioning script exists.

### RLS performance spike (story 1.7, local only)

Loads about 1M assets into the local database (about 3 min), then times the RLS queries (about 20 min). Never run it on staging or in CI. Results and plans land in `spike.result`; the write-up is `docs/spike-1-7-rls-performance.md`. `npm run db:reset` removes it all.

```bash
npm run db:reset
cat scripts/spike-1-7/01_setup.sql scripts/spike-1-7/02_data.sql scripts/spike-1-7/03_bench.sql scripts/spike-1-7/04_fixes.sql | docker exec -i supabase_db_assetly psql -U postgres -v ON_ERROR_STOP=1 -q
```

### CI

`.github/workflows/ci.yml` runs on every pull request: a fresh `db reset`, `supabase test db`, and a check that the committed types match the schema. The web lint, typecheck and build job comes in story 0.3.
