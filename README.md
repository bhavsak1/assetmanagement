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

### Staging (hosted, Mumbai)

```bash
npx supabase login
npx supabase link --project-ref <staging-ref>
npx supabase db push
```

`link` asks for the database password. It is not stored in git.

### CI

`.github/workflows/ci.yml` runs on every pull request: a fresh `db reset`, `supabase test db`, and a check that the committed types match the schema. The web lint, typecheck and build job comes in story 0.3.
