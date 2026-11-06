# Goal 10 design: AI add-on (stories 10.1 to 10.9)

**Status:** plan accepted by the owner, 5 Nov 2026: every story and every lean in the DECIDE table (§9), including 10.9 (D11 a). Docs only, nothing built. Items to revisit at build are in §11.
**Owner-review areas touched (CLAUDE.md §9):** a new secret (provider key), two `security definer` functions
(`private.ai_begin`, `private.ai_finish`), RLS on `ai_call`, and the AI semantic layer, which decides which fields
a model may see.

**Goal:** the review point of Goal 10: "smart import and query-based insights working behind the gateway". A tenant
with the AI add-on gets AI-suggested column mappings and value matches in import, and can ask plain-language
questions on the Insights screen. A tenant without it sees no AI anywhere, and import and every screen work as today.

**Already decided, not reopened:**
1. CLAUDE.md §11: every model call goes through one gateway (entitlement, metering, logging, rate limits, retries,
   provider fallback). AI suggests, humans confirm. Deterministic code checks. The model returns a structured JSON
   query against a semantic layer, never SQL. Fields the user cannot view are never offered. Imported text is
   untrusted data. No training on customer data. Hide "Ask Assetly" and Intelligence without the add-on.
2. CLAUDE.md §10.2: no AI feature without the gateway, a human review step and a manual fallback.
3. technical-architecture.md §7: tiered models, saved mappings mean zero AI cost on repeat imports, prompt caching of
   the schema context, per-tenant monthly caps, an evaluation harness from day one.
4. 8.3 (data-model-goal8.md §14.2): the mapper chain is pluggable; Goal 10 adds `aiMapper` at the end. Mapping
   entries already allow `source: 'ai'` (`import_save_mapping` accepts it).
5. 9.5 (data-model-goal9.md §19): MCP is not a model call, so it stays outside the gateway and needs no AI
   entitlement. Outside agents already search and change assets through `/mcp`. Goal 10 is about AI inside the app.

**Facts checked (5 Nov 2026):**
- `tenant_entitlement` (1.1) has `feature_code` and `limit_value integer null`; members of the tenant can read it, and
  nobody can write it except the service role (provisioning script). The local seed gives the demo tenant `ai_addon`.
- The web app already hides "Ask Assetly" and the Intelligence group without a live `ai_addon` row (`App.tsx`,
  tested in `App.test.tsx`). The "Ask Assetly" button does nothing yet.
- Domains seeded since 1.2: `ai_usage` (view, manage), `insights_query` (ask), `insights_widget` (save, share).
  Starter groups: `insights_query.ask` for Tenant Admin, Plant Manager, Planner; `ai_usage.view` for Tenant Admin,
  Plant Manager, Auditor. **No new domain is needed for Goal 10.**
- Secure views mask by field domain: `asset_view` nulls `purchase_value` without `asset_financials.view` and removes
  hidden custom-field keys (`private.hidden_field_keys`); scope (6.1) is in the view's `where`. Also `vendor_view`,
  `coverage_view`, `service_record_view`. `public.my_permission` lists the caller's own grants.
- `pg_trgm` is installed (3.2). There is no `pgvector`. Locations have a closure table (2.3), so "Pune" can mean the
  Pune subtree.
- `services/api`: `withUser` runs one transaction per call as the user under RLS; `createJobsDb` is the system path.
  Fastify ships Ajv. No model SDK is installed. Secrets live in GCP Secret Manager (8.1, 9.1).
- 8.4 validation gives stable codes per row (`not_found`, `ambiguous`, `possible_duplicate`, ...). The mapping
  catalog (`Target[]`) already holds only the targets this user may set.
- Prices (Anthropic first-party, per million tokens, from the claude-api reference cached 6 Oct 2026, to re-check at
  build): Claude Haiku 5.5 `claude-haiku-5-5` $0.10 in / $0.50 out (prompts up to 100K tokens); Claude Sonnet 5.5
  `claude-sonnet-5-5` $2 / $10; Claude Opus 5.5 `claude-opus-5-5` $4 / $20. Cache reads cost about a tenth of
  input. Batch API is half price but asynchronous. Vertex AI prices Claude separately (not checked).

---

## 1. Story order

| ID | Story | Model calls | Depends on |
|---|---|---|---|
| 10.1 | AI gateway: `ai_call` log, entitlement, cap, rate limit, retries, fallback, eval harness | yes (no feature yet) | |
| 10.2 | AI usage tab in Settings (spend against cap, calls per feature) | no | 10.1 |
| 10.3 | Smart import 1: AI column mapping | yes | 10.1 |
| 10.4 | Smart import 2: AI value matching (category, location, vendor, status) | yes | 10.3 |
| 10.5 | Fuzzy duplicate warning in import (trigram, deterministic) | **no** | 8.4 |
| 10.6 | Semantic layer and query compiler, `POST /insights/run` | **no** | |
| 10.7 | Insights screen and "Ask Assetly" (question to structured query) | yes | 10.1, 10.6 |
| 10.8 | Saved insight widgets ("Could", cut first) | no | 10.7 |
| 10.9 | **Proposal:** chat actions: AI drafts a create or change, the user saves it on the normal form | yes | 10.7 |

10.5, 10.6 and 10.8 make no model call, so 10.5 and 10.6 can start before or next to 10.1.

---

## 2. The gateway (10.1)

### 2.1 Where it lives

One module, `services/api/src/ai.ts`, with one exported function:

```ts
callModel({ claims, feature, system, input, schema, model }) -> { output, ai_call_id } | AiError
```

- Only `ai.ts` imports a model SDK (an ESLint `no-restricted-imports` rule enforces it). Every feature calls
  `callModel`; none calls a provider.
- `feature` is one of `import_map`, `import_values`, `insights`, `assist` (10.1 adds `check`, the `POST /ai/check`
  probe for `ai_usage.view`) (data, a text column; new features add a
  value, not a code path in SQL).
- `schema` is a JSON Schema. The provider is asked for structured output (`output_config.format`), and the answer is
  checked again with Ajv. A failing answer is an error, never "best effort".
- Effort `low`, no conversation history, one request per call. Small prompts keep cost and latency down.

**Lean (D1):** in `services/api`. It already holds the user's token, `withUser`, Secret Manager and Cloud Run; the
web app must not hold a provider key, and Supabase Edge Functions would add a second runtime.

### 2.2 The flow of one call

```
feature code (in a route, after its own checks)
  1. withUser: select private.ai_begin(feature, est_micro_usd)        -- short transaction, commits
       checks: AI_ENABLED, live ai_addon row, the feature's domain, month spend + estimate <= cap,
               user rate limit; inserts ai_call (status 'started'); returns its id or raises a code
  2. model call, outside any transaction (a pooled connection is never held for 1 to 20 s)
       primary provider, SDK retries 2 (429, 5xx, timeout 20 s); then the fallback provider once
  3. withUser: select private.ai_finish(id, provider, model, tokens..., cost, status, error_code)
  4. Ajv check of the output; the feature uses it
```

- Refusal codes from step 1 (stable, i18n text in the web app): `ai_off`, `ai_not_licensed`, `ai_no_right`,
  `ai_cap_reached`, `ai_rate_limited`. Every one leaves the manual path open: import keeps the rules mapping,
  Insights keeps the chip editor (§5.4).
- A crash between 1 and 3 leaves a `started` row; it counts at its estimate, and a daily job marks it `lost`
  after an hour. So a failure never lets spend escape the cap.
- No fallback on a 400 (our bug) or a refusal (`stop_reason: refusal`); those are logged as errors.

### 2.3 Tables and functions (one migration, `10_1_ai_gateway`)

`public.ai_call`, a log like `audit_log` (append, then one finish update):

| Column | Type | Note |
|---|---|---|
| `id` | uuid pk | |
| `tenant_id` | uuid not null | `unique (tenant_id, id)` |
| `user_id` | uuid not null | who asked (person or integration user) |
| `feature` | text not null | `import_map`, ... |
| `subject_id` | uuid null | the import batch, later the widget |
| `status` | text not null | `started`, `ok`, `error`, `lost` |
| `provider`, `model` | text null | which one answered (fallback shows here) |
| `input_tokens`, `output_tokens`, `cache_read_tokens` | integer null | |
| `est_micro_usd`, `cost_micro_usd` | bigint | cost from the token counts and a price table in `ai.ts` |
| `latency_ms` | integer null | |
| `error_code` | text null | provider or our code; never provider text |
| `request` | jsonb null | **insights and assist only:** the question (D6) |
| `output` | jsonb null | **insights and assist only:** the structured query or draft |
| `outcome` | text null | what the user did: `ran`, `edited`, `saved`, `discarded` (§7.3) |
| `created_at`, `finished_at` | timestamptz | |

- RLS on. Select: `tenant_id = current_tenant_id()` and (`has_permission('ai_usage', 'view')` or
  `user_id = auth.uid()`). No insert, update or delete policy; `revoke insert, update, delete, truncate` from
  `anon, authenticated`. Rows are written only by the functions below.
- `private.ai_begin(feature, subject_id, est)` and `private.ai_finish(...)`, `private.ai_set_outcome(id, outcome)`:
  `security definer`, fixed `search_path = ''`, granted to `authenticated`, each reads `auth.uid()` and
  `current_tenant_id()` itself, so a user can only log, finish or mark their own calls in their own tenant.
- Index `(tenant_id, created_at)` for the month sum and `(tenant_id, user_id, created_at)` for the rate limit.
- `pg_cron` daily: mark old `started` rows `lost`; null `request` and `output` after 90 days (D6). Token and cost
  numbers stay.
- Not audited by the row trigger and not in the outbox: it is itself a log, and its writes are not data changes.
- Tests: no add-on, no right, cap reached, rate limit, another user's row unreadable, cross-tenant via
  `tests.cross_tenant` (the harness inserts as owner), finish of someone else's call refused.

### 2.4 Entitlement and cap (OQ-11, current lean used)

OQ-11's lean is "per-tenant monthly cap, unit to decide". This design uses the lean and **does not settle the unit**:
the log keeps tokens and cost, so any customer-facing unit (questions, rows, credits) can be computed later.

- The add-on stays the existing `ai_addon` row. Its `limit_value` becomes the **monthly cap in US cents of provider
  cost**; `null` means 500, so $5 a month (built in 10.1 as a constant in `ai_begin`, not an env var: the service cannot
  widen the cap). No new column, no
  new table. The provisioning script sets it, as today (service role, a system job).
- Month = calendar month in UTC (D4 has the tenant-time-zone option).
- Rate limit per user: 20 calls a minute (constant in `ai_begin`, like the `/v1` 120 a minute).
- Kill switch: env `AI_ENABLED=false` refuses every call platform-wide, with no deploy of code.
- Outside git (owner): a spend limit on the provider account and a GCP budget alert (§8).

### 2.5 Provider and fallback (OQ-21, current lean used)

OQ-21's lean is "Claude primary, second provider as fallback". This design uses it:

- **Primary:** Anthropic API, key `ANTHROPIC_API_KEY` in Secret Manager, official SDK `@anthropic-ai/sdk`.
- **Fallback (lean, D2):** the same Claude models through Google Vertex AI (`@anthropic-ai/vertex-sdk`). Cloud Run's
  service account authenticates to Vertex, so there is **no second secret**. Same prompts and schemas, so the eval
  harness covers both with one golden set. It protects against an Anthropic API outage or key problem, not against a
  Claude model problem; a different model vendor would need its own prompts and evals.
- **Models (lean, D3):** Claude Haiku 5.5 for every feature at first; Sonnet 5.5 only for a feature where the eval
  harness shows Haiku is not good enough. The model per feature is a constant in `ai.ts`.
- Smaller option, named: plain `fetch` instead of the two SDKs (no dependency). Lean is the SDKs: typed errors,
  built-in retries, Vertex auth.

### 2.6 No training, retention and data leaving India

- Anthropic's commercial API terms say API data is not used for training by default (to confirm by the owner when
  accepting the terms, §8). Zero data retention is a separate agreement; it stays with OQ-31 (postponed to before
  the first paying customer). Noted here, not settled.
- OQ-20's lean is "Mumbai only for now". Every model call sends some tenant text out of India (Anthropic runs in the
  US; Vertex region for Claude in Asia not checked). Goal 10 keeps this small (§6.1) but it is still a change. Owner
  to confirm it is acceptable for the pilot (D9).

### 2.7 Evaluation harness

- `services/api/eval/`: golden cases (the messy Excel fixtures from Goal 8, a list of questions with their expected
  structured query, value-matching cases). `npm run eval` calls the real provider and prints a score per feature.
- CI never calls a provider: unit tests use a fake provider (`callModel` takes a provider argument in tests).
  Lean (D7): the owner runs `npm run eval` locally with their own key before a prompt or model change; the score is
  pasted in the PR.

### 2.8 Cost per tenant (estimate, Haiku 5.5, before caching)

| Use | Tokens per call (in / out incl. thinking) | Cost per call | Typical month | Month cost |
|---|---|---|---|---|
| Column mapping (10.3), only unmapped columns | 3,000 / 1,000 | $0.0008 | 4 imports | < $0.01 |
| Value matching (10.4), distinct values only | 15,000 / 5,000 | $0.004 | 4 imports | $0.02 |
| Question (10.7) | 5,000 / 1,500 | $0.0013 | 300 | $0.40 |
| Chat draft (10.9) | 5,000 / 1,500 | $0.0013 | 100 | $0.13 |
| **Total** | | | | **about $0.60** |

With Sonnet 5.5 for questions the same month is about $8. The default cap of $5 covers a heavy Haiku tenant many
times over and stops a runaway Sonnet tenant. Repeat imports with a saved template cost nothing.

---

## 3. AI usage tab (10.2)

- Settings gets an "AI" tab for `ai_usage.view` when the tenant has the add-on: spend this month against the cap
  (bar), calls per feature, and the last 50 calls (when, who, feature, status, cost). Reads `ai_call` under RLS. No
  question text in the list (it is visible in the row detail to the asker and `ai_usage.view` holders).
- No write. Changing the cap is the provisioning script (sales-led, OQ-16). `ai_usage.manage` stays unused.
- The screens file has no AI usage screen; the tab follows the Settings screen style (2.5).

---

## 4. Smart import (10.3, 10.4, 10.5)

### 4.1 Mapping (10.3)

- `aiMapper` is the last mapper in the 8.3 chain. It runs only when the tenant has the add-on, the user holds
  `excel_import.run`, and template and rules left at least one column without a target. A saved template means no
  call at all.
- Input: the unmapped headers, up to 5 sample values per column (each cut to 80 characters), and the catalog targets
  (key, label, kind). Output schema: `[{ column, target | 'ignore' | null, confidence 0..1 }]`.
- Deterministic checks after the model: the target must be in this user's catalog and unused; else it is dropped.
  Confidence under 0.5 is shown as "no suggestion".
- Storage: the existing `import_batch.mapping` entries get `source: 'ai'` and a new `confidence`. Nothing else. The
  Mapping step shows an "AI-suggested" tag with the confidence (screens file, Import review, "Column mapping" box).
  The user confirms with the existing `import_save_mapping`. "Save as template" stays, so the next file skips AI.
- As built (10.3): the AI mapper runs in its own route, `POST /imports/:id/ai-mapping`, not inside the upload, because
  the upload is one transaction and a model call never runs inside one (§2.2). The Mapping step calls it once for a
  staged batch; it returns the suggestions and stores nothing. `import_save_mapping` keeps `confidence` (0 to 1, `ai`
  entries only). A tenant without the add-on gets a silent refusal; cap, rate limit and failure show one line.

### 4.2 Value matching (10.4)

- After 8.4 validation, collect the **distinct** cell values with `not_found` or `ambiguous` on category, location,
  vendor and status (so 1,000 rows of "Comprsr" are one value). For each, the service picks up to 5 candidates the
  user can see, by `pg_trgm` similarity in SQL under `withUser`. Only values with candidates go to the model.
- Output schema: `[{ value, column, candidate_id | null, confidence, reason: 'name_variant' | 'abbreviation' |
  'similar' }]`. The id must be one of that value's candidates, else it is dropped.
- Storage: `import_batch.value_suggestions jsonb` (new column):
  `[{ column, raw, target_id, confidence, reason, status: 'suggested'|'accepted'|'rejected' }]`.
  `import_decide_values(batch, decisions)` (security invoker, checks `excel_import.review`) sets status. 8.4
  validation reads accepted suggestions as a raw-to-id map for that batch and re-runs. Commit (8.6) is unchanged.
- Review screen (screens file, Import review): the "Needs attention" table with AI suggestion, confidence and
  reason, "Accept all above 90%", Edit. A decision applies to every row with that raw value.
- **Never creates master data (lean, D5).** The mock's "New category proposed" becomes "not found: create it on
  Categories, then validate again". Creating a category or location is `category_config.manage` or
  `location_hierarchy.manage` and a structure decision; a person makes it on the normal screen.
- Dates and numbers stay deterministic (8.4). An ambiguous date like `03/04/24` cannot be resolved by a model either.
- As built (10.4): own route `POST /imports/:id/ai-values` on a validated batch (outside any transaction, like
  10.3). Columns are `category`, `location`, `vendor` (OEM and O&M share one lookup in 8.4) and `status`. Up to 50
  distinct values per call, each at most 80 characters; candidates go to the model by index, never by id, and the
  model answers `candidate: -1` for none. `import_decide_values` is **security definer** (not invoker as planned):
  users have no update on `import_batch` (8.2), so it checks by hand what the select policies would (record live,
  active, in a domain the caller may view). The service stores its picks there as `suggested`; values already
  stored are not sent again. A decision (accept or reject) sets the batch back to `mapped` and the screen re-runs
  validation. Edit is a choice among the same candidates; the user's own choice keeps no confidence.

### 4.3 Fuzzy duplicates (10.5, no model)

- 8.4 already flags exact duplicates (`tag_exists`, `duplicate_in_file`, `possible_duplicate`). 10.5 adds a warning
  `similar_asset` when name plus location (or serial) is very similar to a live asset, by `pg_trgm` in the 8.4
  statement chain. No AI, no `pgvector`, no cost.
- It is in Goal 10 because the knowledge base lists dedupe under smart import. It works without the add-on, so it
  could move to Goal 8 follow-ups (D8).

#### 4.3.1 Design at build (10.5)

- One new step in `import_validate` (new migration `10_5_similar_asset`, `create or replace` of the 10.4 body plus
  the step). No new table, column, extension or index: `pg_trgm` and the GIN index `asset_search_trgm`
  (tenant, name, tag, serial) exist since 3.2.
- Per distinct (name, location, serial) of the batch, one probe of live assets in the tenant with
  `name % row name` (index), then the rule below. The best match by name similarity gives the message
  `{code: 'similar_asset', col: name, params: {tag}}`. Warning only: the row still commits.
- The function is security definer, so the probe repeats the `asset_select` checks by hand: `asset_core.view` and
  view scope (`scope_all`, `scope_locations`, `scope_categories`, `scope_mixed_ids`). A user who cannot see an asset
  gets no warning about it and never its tag.
- Not gated by the AI add-on. No model call.
- Screen: the Import review table shows the new warning like `possible_duplicate`, with the tag in the text.

| # | Choice | Options | Lean | Cost to reverse |
|---|---|---|---|---|
| F1 | Rule | a name similarity ≥ 0.6 **and** (same location **or** serial similarity ≥ 0.6, both serials given); b name alone; c name and location only | **a** | Low (one function) |
| F2 | Threshold tenants see | a fixed 0.6 in the function; b tenant setting | **a** | Low |
| F3 | What the warning reveals | a the tag of the one best match, only among assets the caller may view (asset_select checks); b a count only; c no visibility check (like `tag_exists` today) | **a** | Low, but security: owner review |
| F4 | Which rows | a every row with a name, also rows with a tag; b only rows without a tag | **a** | Low |
| F5 | Exact `tag_exists` (8.4) | a leave as is (an error that says a tag is taken, even if the caller cannot see that asset; it must, or the commit fails on the unique key); b change it | **a** | — |

Owner accepted F1-F5 (6 Nov 2026). As built: the distinct keys get a temp trigram index, so the planner drives the
join from the smaller side (assets or keys). A probe per key into `asset_search_trgm` alone took 5 s for 20,000 keys.
`pg_trgm.similarity_threshold` is set with `set_config(..., true)` (a function `SET` of it needs superuser), and the
0.6 is also checked with `similarity()`, so the result does not depend on that setting.

### 4.4 AI-suggested marks after commit

The mark lives in the import: the batch keeps which mapping and which values came from AI, with confidence, and the
batch is audited. The committed asset does not carry a per-field "AI-suggested" flag (lean, D5b). A flag on asset
fields would need a new column or JSONB key on `asset` and a badge on Asset detail; it can be added later without
loss, since the batch holds the facts.

---

## 5. Insights (10.6, 10.7, 10.8)

### 5.1 The semantic layer (10.6)

A catalog in `services/api/src/insights.ts`, built **per request for this user**:

- **Subjects (v1):** `asset` (from `asset_view` with category, location, status, OEM and O&M vendor names, coverage
  state), `obligation` (the 5.3 maintenance list), `coverage` (`coverage_view`). Service records later.
- **Fields:** a fixed map in code: key, label (i18n), type (`text`, `number`, `money`, `date`, `ref`, `enum`),
  the SQL expression on the view, and the domain that must be held to see it (`asset_financials` for purchase value,
  `coverage_values` for contract value). Custom fields come from the field definitions the user may see (hidden
  keys removed), with their type.
- **Filtering:** fields whose domain the user does not hold are left out, using `my_permission`. Subjects whose
  entity domain the user does not hold are left out. This catalog, and only this, is what the model is shown.

### 5.2 The structured query

```json
{
  "subject": "asset",
  "filters": [
    { "field": "location", "op": "in_place", "value": "Pune" },
    { "field": "amc_end", "op": "within_next_days", "value": 60 }
  ],
  "group_by": [],
  "measures": [{ "fn": "count" }],
  "sort": [{ "field": "amc_end", "dir": "asc" }],
  "limit": 100
}
```

- Ops: `eq`, `neq`, `in`, `contains`, `gt`, `gte`, `lt`, `lte`, `between`, `is_empty`, `within_next_days`,
  `within_last_days`, `older_than_days`, and `in_place` for locations (the subtree via the 2.3 closure table).
- Measures `count`, `sum`, `avg`, `min`, `max` on number and money; money always groups by currency (CLAUDE.md §8).
  At most 2 `group_by` fields, dates bucketed by month, quarter or year. `limit` at most 1,000.
- Reference values (`location`, `category`, `vendor`, `status`) are text from the model. The compiler resolves them
  to ids among rows the user can see (exact code or name, then `pg_trgm`). Several matches return `needs_choice`
  with the options, for the user to pick; no second model call.
- 10.6 checks the coverage end-date fields against the 4.4 asset coverage state before fixing the field list.

### 5.3 The compiler (10.6)

- Validates the JSON (Ajv) and every field and op against **this user's** catalog. Unknown or hidden field:
  `422 field_not_allowed`. So a forged query is refused before SQL exists.
- Builds SQL from fixed fragments in the field map only. Every value, including a custom-field key, is a `$n`
  parameter (`custom_values ->> $3`). No text from the query is ever put into SQL.
- Runs under `withUser` in a `read only` transaction with `set local statement_timeout = '5s'`, against the secure
  views. So RLS, scope (6.1) and column masking (6.2) apply a third time even if the compiler had a bug.
- `POST /insights/run { query }` returns columns, rows and the resolved filters. **No model call and no AI
  metering**: chip edits and saved widgets re-run here. Needs `insights_query.ask` and the add-on (the screen is
  AI-only). The compiler itself works for any user, so a later non-AI report builder could reuse it.
- Lean (D10): the compiler in TypeScript in the service (parameterised `pg`, easy to unit-test). Option: a plpgsql
  function with dynamic SQL, callable from the web without the service.
- Tests: hand-written queries against the seed equal the Assets list counts; a user without `asset_financials.view`
  gets `422` on `sum(purchase_value)` and a forged run returns nulls; a Pune-scoped user never sees Mumbai rows;
  cross-tenant; SQL text never contains a value.

### 5.4 Ask Assetly and the Insights screen (10.7)

```
question --> POST /insights/ask --> callModel(feature 'insights', system: rules + catalog JSON (cached),
             input: question, schema: structured query) --> compiler --> rows
```

- The model sees the question and the user's catalog (field keys, labels, types, enum options). **No data rows, no
  record names.** The answer is only the structured query.
- The screen (screens file, Insights): question box, "I understood this as" chips rendered by our code from the
  query (never model prose), an editable chip per filter, the result table, Export (CSV with formula escaping, as
  8.5). Footer: "Results respect your permissions."
- Editing a chip re-runs through `/insights/run`, no model call. `ai_call.outcome` records `ran` or `edited`.
- The top-bar "Ask Assetly" opens Insights with the box focused. It and the Insights nav item also need
  `insights_query.ask` (today they check only the add-on).
- If the gateway refuses (cap, outage), the screen says so and offers the chip editor with an empty query: the manual
  fallback.
- No answer in sentences in v1. A model-written summary of numbers can be wrong; the table cannot.

### 5.5 Saved widgets (10.8, "Could")

`insight_widget` tenant table (1.4 pattern, domain `insights_widget`: `save` for own, `share` for the tenant), holding
the name and the structured query; it re-runs through `/insights/run` with the viewer's own permissions, so a shared
widget never shows more than the viewer may see. Shown on the Insights "Saved widgets" tab. Cut first under scope
pressure (CLAUDE.md §10.1). The weekly digest (KB F29) is not in Goal 10.

---

## 6. Security points

### 6.1 What leaves the database for the model

| Feature | Sent | Not sent |
|---|---|---|
| Mapping | unmapped headers, 5 samples per column (80 chars), catalog labels | other rows |
| Value matching | distinct unmatched values, up to 5 candidate names each | rows, other columns |
| Insights | question, the user's catalog | any data row or record name |
| Chat draft | message, the user's catalog (names are resolved after the model, in SQL) | data rows, record names |

### 6.2 Prompt injection

Cell text, header names, custom-field labels and user questions are untrusted (CLAUDE.md §11, OQ-31).

1. **The model cannot act.** No tools, no write path, no SQL. Its whole output is one schema-checked JSON object.
2. **Every output is checked by code:** a target must be in the user's catalog; an id must be one of the candidates
   we sent; a field must be allowed. Anything else is dropped or refused.
3. **Untrusted text goes in a JSON data block** in the user turn, after the fixed system rules, which say that text
   inside it is data. Control characters are already stripped at import (8.2).
4. **Results never go back to the model.** Insights rows are not summarised by AI, so injected text in an asset name
   cannot steer a later step.
5. Worst case of a successful injection: a wrong suggestion shown to a person for confirmation, inside data the user
   can already see. Never another tenant's data, never a hidden field, never a write.

### 6.3 Masked fields

Three layers: the catalog leaves the field out (the model never learns it exists); the compiler refuses it; the
secure view returns null. Value matching candidates and chat drafts use the same RLS reads. A test per layer.

### 6.4 Audit of AI suggestions

- Every call: `ai_call` (who, feature, model, cost, status, and for insights and chat the question and output for 90
  days).
- Import: suggestions, confidence and decisions on `import_batch` (`mapping`, `value_suggestions`), which the 1.5
  row trigger audits with the user.
- Insights and chat: `ai_call.outcome` (ran, edited, saved, discarded). A saved chat draft is a normal insert or
  update, audited as the user, like any form save.
- This is the KB §7.1 "AI action log (suggested, accepted, rejected)".

---

## 7. Proposal: chat actions in the app (10.9)

**This is a proposal. The owner asked for AI in the app that can search and create records; no planned story did
that. Decide with D11.**

### 7.1 What it does

The user types in "Ask Assetly", for example:
- "air compressors at Nashik out of warranty" (search)
- "add a Kirloskar compressor at Plant 2 Nashik, serial KC-4471, bought 3 March 2026" (create)
- "move PNE-0188 to Plant 2" (transfer), "mark PNE-0412 under maintenance" (status), "set the model of PNE-0188 to
  GA-37" (update)

### 7.2 How (lean: the AI drafts, the user saves on the normal form)

```
message --> POST /ai/assist --> callModel(feature 'assist', schema: one of
              { intent: 'search', query }                       -> 10.7 flow
              { intent: 'create_asset', draft: { target: value } }
              { intent: 'update_asset', asset_ref, changes }
              { intent: 'transfer_asset', asset_ref, location }
              { intent: 'change_status', asset_ref, status }
              { intent: 'unsupported', reason }) --> service resolves refs and checks the draft --> web
web opens the EXISTING Add asset form / Edit form / Transfer dialog / status dialog, prefilled,
every prefilled field tagged "AI-suggested"; the user checks, edits and presses Save
Save = today's path (RLS insert, transfer_asset, change_asset_status), audited as the user
```

- The service writes nothing. The model is offered only intents the user can do (no `create_asset` without
  `asset_core.create`) and only the 8.3 catalog targets the user may set. Refs (tag, location, status names) resolve
  in SQL under `withUser`; a miss or several matches is shown on the form, not guessed.
- One message, one draft, no chat memory (cheap; no history tokens). Assets only in v1; coverage and service records
  later with the same pattern. Bulk changes stay with import.
- Same permission engine as UI, `/v1` and MCP: no new write path, no new policy.

### 7.3 Options

| Option | For | Against |
|---|---|---|
| **a Draft, then the normal form** | Nothing committed silently (CLAUDE.md §11); the form's checks and screen rules apply; no new write code | One more click than a chat "Confirm" |
| b A confirm card in the chat that calls the write directly | Faster | A second UI for every write, skipping the form's field rules and help; harder to review |
| c Do not build; in-app AI only searches (10.7). Outside agents use MCP (9.5) | Smallest | The owner's ask stays open inside the app |

**Lean: a.** Cost to reverse: low (no schema).

---

## 8. Owner steps outside git (I never handle keys)

1. **Anthropic:** create an organisation and a workspace "assetly-staging" in the Anthropic Console, add billing, set
   a monthly spend limit (for example $20), create an API key, and put it in GCP Secret Manager as
   `ANTHROPIC_API_KEY` for the staging service. Read the commercial terms on training and retention (§2.6).
2. **Vertex AI fallback (if D2 a):** in the GCP project, enable the Vertex AI API, enable the Claude models in Model
   Garden (accept terms), grant the Cloud Run service account "Vertex AI User", and pick a region (check which
   regions serve Claude Haiku 5.5).
3. **Budget:** a GCP budget alert covering Vertex and Cloud Run.
4. **Entitlement:** the provisioning script sets `ai_addon` (and its cap) per pilot tenant. Staging demo tenant: on.
5. New env vars (added to `.env.example` in 10.1, values only in Secret Manager): `ANTHROPIC_API_KEY`, `AI_ENABLED`,
   `VERTEX_PROJECT`, `VERTEX_REGION`.

---

## 9. DECIDE (owner accepted every lean, 5 Nov 2026)

| # | Decision | Options | Lean | Cost to reverse |
|---|---|---|---|---|
| D1 | Where the gateway lives | a `services/api/src/ai.ts`; b Supabase Edge Function; c separate service | **a** | Low |
| D2 | Fallback provider (OQ-21 lean: second provider) | a Claude on Vertex AI (no second secret, same prompts); b a different vendor (OpenAI or Gemini: own prompts and evals); c none at first, retries only | **a** | Low (one module) |
| D3 | Models | a Haiku 5.5 everywhere, Sonnet 5.5 only where the eval shows need; b Sonnet 5.5 for insights from the start | **a** | Low (a constant) |
| D4 | Cap and metering (OQ-11 lean: monthly cap; unit stays open) | a cap = provider cost in US cents on `ai_addon.limit_value`, default $5, UTC month; b the same with the tenant's time zone month; c a new entitlement row per unit | **a** | Low |
| D5 | Value matching creates master data? | a never; suggests existing records only, "not found" sends the user to the screen; b proposes new categories and locations for the reviewer to create in import | **a** | Medium (b needs create rights in import) |
| D5b | "AI-suggested" mark after commit | a in the import batch and audit only; b also a per-field flag on the asset with a badge on Asset detail | **a** | Low (b can be added later from batch data) |
| D6 | What text `ai_call` keeps | a question and structured output for insights and chat, 90 days, no import cell text; b nothing but numbers; c everything, 1 year | **a** | Low |
| D7 | Eval harness | a golden set in git, run locally with the owner's key, score in the PR; CI uses a fake provider; b also a nightly CI run with a key in GitHub secrets | **a** | Low |
| D8 | Fuzzy duplicates (10.5) | a in Goal 10, deterministic, works without the add-on; b move to Goal 8 follow-ups; c `pgvector` embeddings | **a** | Low |
| D9 | Tenant text sent to a US provider (OQ-20 lean: Mumbai only; OQ-31 postponed) | a accept for pilots with the §6.1 minimisation, revisit with OQ-31; b wait for an India region before Goal 10 | **a** | Low (provider switch in one module) |
| D10 | Query compiler | a TypeScript in the service; b plpgsql with dynamic SQL | **a** | Medium |
| D11 | Chat actions (10.9, proposal) | a AI drafts, user saves on the normal form; b confirm card in chat; c do not build | **a** | Low |
| D12 | Saved widgets (10.8) | a keep as "Could", cut first; b drop from Goal 10 | **a** | Low |

---

## 10. Not in Goal 10

Weekly insights digest (F29), document-to-asset extraction (invoice, nameplate photo), setup copilot, embeddings and
`pgvector`, model-written answers in sentences, Batch API, AI on WhatsApp, AI on `/v1` or MCP, a background jobs
monitor (BL-1: AI calls are synchronous user calls, so not needed yet), changing the AI cap from the UI.

---

## 11. Revisit at build (owner, 5 Nov 2026)

Raised by the owner after the plan; not changed now, to settle when the story starts:

1. **10.6, a flexible semantic layer.** Users can ask anything, so the field list may be built automatically from every
   column of the secure views and every custom field the user may see, over more subjects (asset, coverage,
   obligation, service record, vendor, location, category) with links fixed in code, plus hand-written derived fields
   (asset age, days to warranty end, last service date, added on). Questions it cannot answer are logged to grow the
   list. Still no free SQL; the model returns the JSON query and the compiler checks it. Owner: revisit when 10.6
   starts.
2. **"Added on" and "last changed"** (`created_at`, `updated_at`) as asset fields, so "how many assets were added last
   week" works (10.6, 10.7).
3. **Copy an asset.** "Create a new asset by copying X" would be a `copy_from` on the 10.9 create draft. The app has
   no manual "Duplicate asset" today; a non-AI Duplicate button on Asset detail would come first (core works without
   AI), and 10.9 would reuse its prefill. Not added as a story yet.
