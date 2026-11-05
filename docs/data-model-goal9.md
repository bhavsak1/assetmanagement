# Goal 9 data model: notifications (story 9.1)

**Status:** built 4 Nov 2026, In review. The owner chose Resend for N5 and accepted the leans for N1 to N4 and N6 to
N11 (4 Nov 2026). Not pushed to staging; email needs the owner steps in §14 first.

**As built (differences from the design below):**
- Migrations: `9_1_coverage_events` (4.4/8.6 `refresh_coverage_state` plus the event), `9_1_notification` (helper
  `private.user_can`, table, RLS, switch, fan-out, `pg_cron` every minute), `9_1_notification_email` (summary table,
  hourly queue at minute 5, claim, finish, role `assetly_jobs`).
- The fan-out marks events no consumer wants (every `<table>.insert|update|delete`) published in one statement of
  up to 50,000 rows a run, so an import never backs up the alert queue.
- Email is plain text only (tenant data is untrusted; no HTML to escape). Dates use the tenant date format.
- The Alerts link sits in the top bar (text and count, no icon set exists). Rows open the asset page; the asset
  page has no tab in its URL, so it opens on Overview.
- Tests: `supabase/tests/9_1_notifications.test.sql` (49), `1_6_starter_groups` gains a notification fixture,
  `services/api/test/email.test.ts` (6), `apps/web/src/Notifications.test.tsx` (6). No `tests.cross_tenant` line:
  users cannot insert alerts, so the harness does not fit; the 9.1 file has its own cross-tenant checks.

**Goal (9.1):** an obligation that becomes due soon or overdue, or coverage that is about to expire or has
expired, produces an in-app notification for the right users, and a short email. Review point of Goal 9 (first half):
"an overdue service or expiring coverage produces an alert".

**Already decided, not reopened:**
1. Outbox (1.5): `private.outbox_event` is written in the same transaction as the change. Columns
   `published_at`, `attempts`, `last_error` are there for a poller.
2. Service host (OQ-28): Cloud Run, scale to zero, `pg_cron` or Cloud Scheduler calls it. No always-on machine.
3. 8.1 G9: no service-role key in the service. System jobs get their own role (`assetly_jobs`), named for 9.1.
4. CLAUDE.md §6.4: the service-role key is for system jobs only, never in web config.

**Reads with:** technical-architecture.md §2, §8; data-model-goal5.md (obligation state job), data-model-goal4.md
(coverage state job), data-model-goal6.md (scope), data-model-goal8.md §1 to §4 (the service).

**Facts checked (4 Nov 2026):**
- Events that exist now: `obligation.due_soon`, `obligation.overdue` (5.1 state job, one per entry into the state),
  plus `<table>.insert|update|delete` from the audit trigger. **There is no coverage event.** The 4.4 coverage
  state job changes `asset.coverage_state` without an audit row or outbox event (C12). So 9.1 must add one (N3).
- Obligation and coverage states move at tenant-local midnight (dates in the tenant zone, job every 15 minutes).
  Emailing on each event would send mail at midnight.
- The 6.1 scope helpers work for `auth.uid()` only. 6.5 added `private.profile_scope(profile_id)`, which works for
  any user. Recipient checks reuse it.
- No notifications screen exists in `docs/assetly-screens.html`. The UI follows the existing shell and cards.
- Prices (third-party and vendor pages, verify before a business case): Resend free 3,000 a month, 100 a day,
  Pro $20 for 50,000. Amazon SES $0.10 per 1,000; its free tier is now credits for new AWS accounts.
  Cloud Scheduler 3 free jobs per billing account, then $0.10 per job a month.

---

## 1. Flow

```
state job (pg_cron, 15 min) ──> outbox_event ──> fan-out (pg_cron, 1 min, SQL) ──> notification rows (in-app)
                                                                               └─> per-user daily email row
Cloud Scheduler (15 min) ──> POST /jobs/email (service, role assetly_jobs) ──> email provider (HTTPS)
```

## 2. Where the poller runs (N1)

| Option | For | Against |
|---|---|---|
| **a Split.** Fan-out in SQL by `pg_cron`; email sending in the service, called by Cloud Scheduler | Recipient checks need the permission tables and scope helpers, which live in Postgres. No network call from the database. Email keys stay in Secret Manager, never in Postgres | Two schedulers (one free Cloud Scheduler job) |
| b All in `pg_cron`, email through `pg_net` | One place | `pg_net` is a Supabase extension (portability, CLAUDE.md §3). The email key would sit in the database |
| c All in the service, Cloud Scheduler every minute | One language | The service must read raw outbox and permission tables across tenants: a much wider jobs role. Cold start per minute |

**Lean: a.** Cost to reverse: low. The fan-out function can be called from the service later unchanged.

## 3. Claim and retry, no double delivery (N2)

**In-app (fan-out, SQL).** One function `private.fan_out_events(batch 500)`:
- takes unpublished rows with `for update skip locked`, oldest first, so two runs never take the same row;
- inserts notifications with `unique (event_id, user_id)` and `on conflict do nothing`, so a re-run never doubles;
- sets `published_at` in the same transaction. One row fails: that row gets `attempts + 1` and `last_error`
  (per-row exception block), the rest go on. After 5 attempts the row is skipped (it stays visible, see N7).
- `published_at` means "handed to every consumer". 9.3 webhooks will fill their own delivery table in the same
  fan-out step, so the outbox keeps one publisher and one flag.

**Email (service).** One row per user per tenant per day in `private.notification_email`
(`unique (tenant_id, user_id, digest_date)`).
- `private.claim_emails(n)` (security definer) picks `pending` rows that are due, `for update skip locked`, sets
  `status = 'sending'`, `claimed_at = now()`, returns address and lines. A `sending` row older than 10 minutes is
  claimable again (crashed run).
- The service sends with the row `id` as the provider's idempotency key, then calls `private.finish_email(id, ok,
  error)`: `sent` and `provider_id`, or back to `pending` with `attempts + 1`, `last_error` and a backoff
  (`next_try_at`: 15 min, 1 h, 4 h). After 5 attempts: `failed`.
- A crash after the send and before `finish_email` resends the same id; the provider drops the duplicate (Resend
  keeps the key 24 hours). That is the one place "no double delivery" leans on the provider.

**Lean: as above.** Cost to reverse: low.

## 4. Which events notify whom (N3)

**Events in 9.1:**

| Event | From | Domain checked |
|---|---|---|
| `obligation.due_soon`, `obligation.overdue` | 5.1 state job (exists) | `obligation` |
| `coverage.expiring`, `coverage.expired` | **new**: 4.4 coverage job writes one event when `coverage_state` enters `expiring` or `out` (from `active` or `expiring`) | `coverage_contract` |

Nothing else in 9.1 (no transfer, retire, import or security events). Bulk import does not fire these events, since
they come only from the state jobs.

**Who:** active members of the event's tenant who hold the domain operation now, with the asset in their 6.1
scope for that operation. Checked once at fan-out with a new `private.user_sees_asset(tenant, user, domain, op,
asset)` built on `user_effective_permission` and `private.profile_scope`. Checked again when the inbox is read and
when the email is built (§5, §6), so a lost grant hides old notifications too.

| Option for the operation | For | Against |
|---|---|---|
| a `view` | Everyone who can see it is told | Noisy: every viewer of every asset gets every alert |
| **b `update`** | Tells the people who can act (complete a service, renew coverage) | A read-only manager is not told; they still see the dashboard |
| c a new seeded domain per alert type (`alert_obligation`, `alert_coverage`), assigned by group | Full control, domains are data | Two more domains and starter-group seeds to review (owner review area) |

**Lean: b.** Cost to reverse: low (one function; c is a later migration that seeds rows).

## 5. The in-app table and its RLS (N4)

`public.notification`:
`id, tenant_id, user_id, event_id (unique with user_id), event_type, domain, asset_id, aggregate_id, payload jsonb
(snapshot: asset name and tag, obligation name, dates), read_at, emailed_on, created_at`.
Composite FKs `(tenant_id, user_id)` to membership and `(tenant_id, asset_id)` to asset.

No `updated_at`, `created_by`, `deleted_at`: the job is the only writer and users never delete. No audit trigger
(an audit row per notification would be noise, and an outbox event per notification would loop).

Policies, all `to authenticated`:
- select: `tenant_id = current_tenant_id() and user_id = auth.uid() and has_permission(domain, 'view') and
  asset_in_scope(domain, 'view', asset_id)`. The last two hide rows after a lost grant.
- update: own rows only, and only `read_at` (column grant `update (read_at)`), `with check` the same.
  `tenant_can_write()` is **not** required: a read-only tenant can still mark read. (Say no if you want it.)
- no insert or delete policy; `revoke insert, delete, truncate`.

Text is built in the browser from `event_type` and `payload` through i18n, so no stored English.

**Lean: as above.** Cost to reverse: medium once rows exist (column changes on a live table).

## 6. Email provider and timing (N5, N6)

**Provider (N5):**

| Option | Free | Then | Setup | Code |
|---|---|---|---|---|
| **a Resend** | 3,000 a month, 100 a day | $20 for 50,000 | Account plus DNS records on a domain you own | Plain `fetch`, no new dependency. Idempotency key built in. Also offers SMTP (for N8) |
| b Amazon SES | Credits for new AWS accounts only | $0.10 per 1,000 (cheapest at scale) | AWS account, leave the sandbox (a request to AWS), DNS records | SigV4 signing: the AWS SDK (new dependency) or hand-rolled signing. No idempotency key |
| c Brevo | 300 a day | from about $9 | Account, DNS | Plain `fetch` |

**Decided (owner, 4 Nov 2026): a Resend** for staging and pilots; ZeptoMail (no daily cap, about $2.5 per 10,000) or SES are the later options, behind one `sendEmail()` function. Move to SES when volume passes the
free tier. Cost to reverse: low (one function, DNS records). `technical-architecture.md` §2 says SES; it becomes
out of date if you pick a.

**You need a domain you own** for any provider (the `pages.dev` name cannot be verified). Sending from
`alerts@<your domain>`. You create the account and the key; I never handle it (§9).

**Timing (N6):**

| Option | For | Against |
|---|---|---|
| **a One daily summary per user at 08:00 tenant time**, only when there is something new | One email a day at most; fits 100 a day free for about 100 active users; no midnight mail | Up to a day late for email (in-app is within a minute) |
| b A batch every 15 minutes | Faster | Mail at midnight, when states change |
| c One email per event | Simplest | Many emails, burns the free tier |

**Lean: a.** An hourly `pg_cron` step creates `notification_email` rows for tenants whose local time has passed
08:00 and users with notifications not yet emailed (`emailed_on is null`). Cost to reverse: low.

## 7. Per-user preferences (N7)

| Option | For | Against |
|---|---|---|
| a None in 9.1 | Smallest | No way to stop the daily email |
| **b One switch: "Email me a daily summary"**, default on, per user per tenant (column on `tenant_membership`, set by a small function for the caller's own row), and a link to it in every email | Basic email hygiene, small | One column, one function |
| c Per event type and channel | Fine control | A matrix screen nobody asked for yet |

**Lean: b.** In-app cannot be turned off. Cost to reverse: low.

## 8. How failures surface (N8)

| Option | What |
|---|---|
| **a In the data plus logs** | Outbox `attempts` and `last_error`; email row `status = 'failed'` with `last_error`. The service logs each failure at `ERROR` (Cloud Logging). A pgTAP-tested view for a later screen is not built |
| b a, plus a Cloud Monitoring alert | A log-based alert on `severity=ERROR` for the service that emails you. Free. A `gcloud` command in §9, run by you |
| c A jobs page | That is BL-1 (needs a platform-admin role). Not in 9.1 |

**Lean: b.** Cost to reverse: low.

## 9. Forgot password (N9)

Supabase Auth sends reset mail through its own SMTP setting (Auth settings, an owner-review area, CLAUDE.md §9),
plus a reset page in the web app. Resend and SES both offer SMTP, so it is small once N5 is done.

| Option | |
|---|---|
| **a Separate story 9.1b** (Auth SMTP in `config.toml`, reset page, "Forgot password" link shown) | Auth stays in its own reviewed change; one feature per session (CLAUDE.md §5.4) |
| b In 9.1 | One more owner-review area in one PR |

**Lean: a.** I add 9.1b to the tracker. Cost to reverse: none.

## 10. The jobs role and the jobs endpoint (N10)

- New login role `assetly_jobs`: no table rights, `execute` on `private.claim_emails` and `private.finish_email`
  only (both security definer, fixed `search_path`). No service-role key anywhere. Secret: a second connection
  string `JOBS_DATABASE_URL` in Secret Manager.
- `POST /jobs/email` is outside `/v1`. Cloud Scheduler calls it with a Google OIDC token; the service checks it with
  `jose` (already installed) against Google's keys, audience = service URL, email = the scheduler service account.
  No shared secret to rotate.

| Option | |
|---|---|
| **a As above** | Least power: the role can only claim and finish email rows |
| b Reuse `assetly_api` with a bypass | Mixes user and system paths |
| c Shared secret header instead of OIDC | Simpler locally; one more secret to rotate |

**Lean: a.** Locally and in tests, `/jobs/email` accepts a test-only check (env `JOBS_AUDIENCE` unset means the
route is off). Cost to reverse: low.

## 11. UI

- Bell in the top bar with the unread count. It refreshes on page change and every 2 minutes while the tab is
  visible (no Supabase Realtime: portability).
- `/notifications`: newest first, unread in bold, each row opens the asset (obligations or coverage tab).
  "Mark all as read". The email switch (N7 b) at the top.
- All text in `en.json`. Email text comes from a small strings file in the service (English only).

## 12. The smaller option

In-app only (fan-out plus inbox), no email: drops N5, N6, N7, N10, the jobs role, the scheduler and the endpoint,
about half the work. The Goal 9 review point says "an alert", which in-app meets. Email moves to 9.1b with forgot
password, both needing the same provider. **Say if you want this instead.**

## 13. DECIDE

| # | Decision | Options | Lean | Cost to reverse |
|---|---|---|---|---|
| N1 | Where the poller runs | a fan-out `pg_cron` + email in service via Cloud Scheduler, b all `pg_cron` + `pg_net`, c all in service | a | Low |
| N2 | Claim and retry | skip-locked claims, unique `(event_id, user_id)`, email row per user per day, provider idempotency key, 5 tries with backoff | as §3 | Low |
| N3 | Events and recipients | events: obligation due soon / overdue, coverage expiring / expired (new event). Recipients hold a `view`, b `update`, c new alert domains; plus 6.1 scope | b | Low |
| N4 | In-app table and RLS | own rows, rechecks domain and scope on read, update `read_at` only, no `tenant_can_write` for mark read | as §5 | Medium |
| N5 | Email provider | a Resend, b SES, c Brevo, d ZeptoMail | **a (owner, 4 Nov 2026)**; ZeptoMail or SES later if needed | Low |
| N6 | Email timing | a daily summary 08:00 tenant time, b every 15 min, c per event | a | Low |
| N7 | Preferences | a none, b one email switch, c matrix | b | Low |
| N8 | Failures | a data + logs, b plus a Cloud Monitoring email alert, c jobs page (BL-1) | b | Low |
| N9 | Forgot password | a separate story 9.1b, b in 9.1 | a | None |
| N10 | Jobs role and endpoint | a `assetly_jobs` with two functions + OIDC, b reuse `assetly_api`, c shared secret | a | Low |
| N11 | Size of 9.1 | a full (in-app + email), b in-app only, email to 9.1b (§12) | a | Low |

N1 to N4 and N6 to N11: owner accepted the leans, 4 Nov 2026.

## 14. Owner steps (before the next service deploy; I never handle the keys)

The deploy workflow now reads two new secrets. **Create them before running "Deploy API"**, or the deploy fails.
Until `API_URL` is set, the email route stays off.

1. Domain and Resend: pick or buy a domain, create the Resend account, add its DNS records (SPF, DKIM), create an
   API key with **sending access only**.
2. Staging database: set a password for the jobs role (SQL editor, not in git):
   `alter role assetly_jobs password '<new password>';`
3. Secrets (Secret Manager), readable by `assetly-api-run@<project>.iam.gserviceaccount.com`:
   - `assetly-api-jobs-db-url`: the pooler URL as `assetly_jobs.blhxyfgkkhpqbfuhpnww` with that password (same host
     and port 6543 as `assetly-api-db-url`).
   - `assetly-api-email-key`: the Resend key.
   ```
   printf '%s' '<url>' | gcloud secrets create assetly-api-jobs-db-url --data-file=-
   printf '%s' '<key>' | gcloud secrets create assetly-api-email-key --data-file=-
   for s in assetly-api-jobs-db-url assetly-api-email-key; do gcloud secrets add-iam-policy-binding $s      --member serviceAccount:assetly-api-run@$PROJECT.iam.gserviceaccount.com --role roles/secretmanager.secretAccessor; done
   ```
4. GitHub repository variables: `API_URL` (the service URL, `https://assetly-api-....run.app`) and `EMAIL_FROM`
   (`Assetly <alerts@your-domain>`).
5. Scheduler (one of the 3 free jobs), every 15 minutes, with a Google OIDC token:
   ```
   gcloud iam service-accounts create assetly-scheduler
   gcloud scheduler jobs create http assetly-email --location asia-northeast1 --schedule '*/15 * * * *'      --uri "$API_URL/jobs/email" --http-method POST      --oidc-service-account-email assetly-scheduler@$PROJECT.iam.gserviceaccount.com --oidc-token-audience "$API_URL"
   ```
6. N8 b, the failure alert (free): a log-based alert on `resource.type="cloud_run_revision"
   resource.labels.service_name="assetly-api" severity>=ERROR`, emailing you (Cloud Monitoring, Alerting).
7. Then run "Deploy API", and push the migrations to staging (your usual `db push` from current `main`).

## 15. Not in 9.1

Webhooks (9.3), WhatsApp (9.4), the `/v1` API (9.2), escalation, quiet hours, per-event preferences, a jobs page
(BL-1), push notifications, notification retention or purge.

---

## 16. Story 9.1b: forgot password

**Status:** Done (owner, 5 Nov 2026). Config pushed to staging and the reset flow tested there by the owner.

**As built:** `supabase/config.toml` (staging SMTP, `otp_expiry`, `email_sent`; recovery template for every
environment; local `site_url` moved to the Vite port `http://localhost:5173` so local links work),
`supabase/templates/recovery.html`, `ForgotPasswordPage` and `ResetPasswordPage` in `apps/web/src/App.tsx`, strings
under `reset` in `en.json`, 4 new tests in `App.test.tsx`. The sender is an env var too
(`SUPABASE_AUTH_SMTP_ADMIN_EMAIL`), so the domain stays out of git like `EMAIL_FROM`.

**Goal:** a user who forgot the password asks for a link on the login page, gets one email through Resend, sets a
new password on `/reset-password`, and signs in. Lifts the CLAUDE.md §13 rule "Forgot password is hidden until email
sending exists". Auth settings: owner-review area (CLAUDE.md §9).

**Facts checked (4 Nov 2026):**
- `supabase/config.toml` has no `[auth.email.smtp]`. Local mail goes to Mailpit (`http://127.0.0.1:54324`), enough
  for local tests. Staging is set through `[remotes.staging.auth]` and `config push` (README, 1.6b).
- Staging is pinned to `max_frequency = "1m0s"` (one reset mail per address per minute) and `otp_length = 8`.
  `otp_expiry` is not pinned, so a push sends the base value 3600 (1 hour). `config diff` shows the real value first.
- The web client uses the default implicit flow (`apps/web/src/supabase.ts`). The screens file shows only a
  "Forgot password?" link under Sign in; there is no reset screen, so the two new screens reuse `LoginFrame`.
- Supabase answers `resetPasswordForEmail` with success for an unknown address, but with a 429 for a known address
  asked again inside `max_frequency`. So the error itself can reveal the account (F6).
- With custom SMTP, Supabase's own email limit (`email_sent`, per hour, whole project) applies. Resend free is
  100 a day, shared with the 9.1 daily summary.

### Flow

```
Login ──"Forgot password?"──> /forgot-password (email) ──resetPasswordForEmail──> Supabase Auth ──SMTP──> Resend ──> inbox
inbox link: <site>/reset-password?token_hash=...&type=recovery
/reset-password ──verifyOtp(token_hash, 'recovery')──> recovery session ──updateUser({ password })──> sign out ──> /login "Password changed"
```

No table, no migration, no token store: Supabase Auth issues, checks and expires the token (CLAUDE.md §14).

### F1 Where SMTP settings live

| Option | For | Against |
|---|---|---|
| **a `[remotes.staging.auth.email.smtp]` in `config.toml`, `pass = "env(SUPABASE_AUTH_SMTP_PASS)"`, applied with `config push`** | In git and reviewed; same path as every other Auth setting (1.6b); local keeps Mailpit | The owner sets the env var in the shell for each push, or the push fails |
| b Dashboard only | No env var | Breaks CLAUDE.md §14 (no dashboard-only Auth changes); drifts from git |

Settings: host `smtp.resend.com`, port `465`, user `resend`, pass = a Resend API key. **Lean: a**, with a **second
Resend key, sending access only, just for Auth SMTP**, so it can be revoked without stopping the 9.1 summary. Cost to
reverse: low.

### F2 Sender

| Option | |
|---|---|
| **a `Assetly <no-reply@<9.1 domain>>`** | Same verified domain, no new DNS. Tells users not to reply |
| b `Assetly <alerts@<9.1 domain>>` | Same address as the summary; mixes alerts and security mail |

**Lean: a.** Cost to reverse: none (one config line). **Owner: tell me the domain** (it is in the `EMAIL_FROM`
GitHub variable, not in git).

### F3 Email template

`[auth.email.template.recovery]` with `subject` and `content_path = "./supabase/templates/recovery.html"` (in git,
English only, like the 9.1 email). Short HTML:

> **Subject:** Reset your Assetly password
>
> Someone asked to reset the password for your Assetly account. Use this link within 1 hour:
> Set a new password (`{{ .SiteURL }}/reset-password?token_hash={{ .TokenHash }}&type=recovery`)
>
> If you did not ask, ignore this email. Your password stays the same.

| Option for the link | For | Against |
|---|---|---|
| **a `token_hash` link to our page; the page calls `verifyOtp`** | Mail scanners (Outlook Safe Links and similar) that open links do not burn the token, since only our page's script uses it. Works on any device | The template builds the URL itself |
| b `{{ .ConfirmationURL }}` (Supabase verifies, redirects with tokens in the URL hash) | Default | A scanner's visit uses the one-time token; the user then sees "link expired" |
| c PKCE flow | Token not in the URL | Works only in the browser that asked; a link opened on the phone fails |

**Lean: a.** Cost to reverse: low (template and one page).

### F4 Redirect URLs

With F3 a the link uses `{{ .SiteURL }}`, so only `site_url` matters. Staging already has `site_url` and
`additional_redirect_urls` = `https://assetly-staging.pages.dev`. Cloudflare preview URLs
(`*.assetly-staging.pages.dev`) are **not** added: a reset link always lands on the main staging site.
**Lean: no change.** Cost to reverse: none.

### F5 Reset page

- `/forgot-password` and `/reset-password` sit outside the signed-in guard, in `LoginFrame`.
- `/reset-password` calls `verifyOtp` once on load. Bad, used or expired link: one message, "This link has expired
  or was already used", and a link to ask again.
- New password twice, must match. Length is checked by Auth (`minimum_password_length`, now 6). A weak-password
  error from Auth shows one message.

**Lean: as above.** Cost to reverse: low.

### F6 Not revealing whether an email exists (CLAUDE.md §13)

| Option | |
|---|---|
| **a Always the same message** after submit, whatever Auth returns (success, unknown, 429): "If an account exists for this email, we sent a link. Check your inbox." Only a network failure shows "Could not send. Try again." | Nothing leaks, including the 429 |
| b Show the 429 as "Wait a minute" | Friendlier, but tells a stranger the address has an account |

**Lean: a.** Cost to reverse: none.

### F7 Rate limits

| Setting | Now (staging) | Lean |
|---|---|---|
| `max_frequency` (per address) | 1 minute (pinned) | keep |
| `email_sent` (per hour, whole project, applies once SMTP is on) | default 30 | **pin 30** in `[remotes.staging.auth.rate_limit]` |
| `sign_in_sign_ups`, `token_verifications` (per IP, 5 min) | 30 | keep |
| CAPTCHA on the forgot form | off | keep off for pilots (Turnstile later if abused; new account and secret) |

Resend free is 100 a day for summaries and resets together; 30 an hour stops one burst from using it all.
Cost to reverse: none.

### F8 Link expiry

| Option | |
|---|---|
| **a 1 hour** (`otp_expiry = 3600`, pin it on staging) | Supabase default; matches the email text |
| b 15 minutes | Safer; users with slow mail miss it |
| c 24 hours | Convenient; a long-lived key in an inbox |

`otp_expiry` also sets other email links (invites, email change). **Lean: a.** Cost to reverse: none.

### F9 Other sessions after a reset

Supabase revokes the user's other refresh tokens when the password changes. Their access tokens still work until
they expire (`jwt_expiry`, 1 hour).

| Option | |
|---|---|
| a Stay signed in here, others out (Supabase default) | Smoothest |
| **b Sign out everywhere (`signOut({ scope: 'global' })`), then the login page says "Password changed. Sign in with your new password."** | Clear; proves the new password works; the recovery session never becomes a working session |
| c b, plus Supabase's "password changed" notice email (`[auth.email.notification.password_changed]`) | Tells the account owner if someone else did it; one more email against the quota |

**Lean: b.** c is cheap; say if you want it. Cost to reverse: none.

### Owner steps (after you answer; I never handle keys or passwords)

1. Resend: create a second API key, **sending access only**, named `supabase-auth-smtp`.
2. In your own shell (not in git, not in the repo `.env`): `export SUPABASE_AUTH_SMTP_PASS=<that key>` and
   `export SUPABASE_AUTH_SMTP_ADMIN_EMAIL=no-reply@<9.1 domain>`.
3. `npx supabase config diff --project-ref blhxyfgkkhpqbfuhpnww`: check that only SMTP, the recovery template,
   `otp_expiry` and `email_sent` change. Then `npx supabase config push --project-ref blhxyfgkkhpqbfuhpnww`.
4. Merge the PR; Cloudflare deploys the web app. Then try a reset on staging with your own account.

No migration, no `db push`, no service deploy.

### DECIDE (9.1b)

| # | Decision | Options | Lean | Cost to reverse |
|---|---|---|---|---|
| F1 | SMTP settings | a `config.toml` + `env()` + `config push`, b dashboard | a, separate send-only Resend key | Low |
| F2 | Sender | a `no-reply@<domain>`, b `alerts@<domain>` | a (tell me the domain) | None |
| F3 | Template and link | a `token_hash` to our page, b `ConfirmationURL`, c PKCE | a, text as above | Low |
| F4 | Redirect URLs | staging site only, no preview URLs | no change | None |
| F5 | Reset page | `verifyOtp`, two fields, one message per case | as above | Low |
| F6 | Generic message | a always the same, b show the 429 | a | None |
| F7 | Rate limits | keep 1 min per address, pin `email_sent` 30/h, no CAPTCHA | as table | None |
| F8 | Link expiry | a 1 h, b 15 min, c 24 h | a | None |
| F9 | Other sessions | a default, b sign out everywhere, c b + changed-password email | b | None |

**Not in 9.1b:** CAPTCHA, invites or signup, password rules beyond Auth's length check (raising
`minimum_password_length` is a separate Auth change), MFA, SSO (Phase 2).

---

## 17. Story 9.2: public REST API `/v1`, API keys, integration users

**Status:** built 5 Nov 2026, In review. The owner accepted every lean, A1 to A14 (5 Nov 2026), with A2 a: no group
is made automatically with an integration user (an "own group per integration user" option is for a later review).
Not on staging. **API keys are an owner-review area (CLAUDE.md §9).**

**As built (differences from the design below):**
- Migrations: `9_2_integration_user` (`user_profile.kind`, `audit_log.api_key_id` and `audit_row` filling it,
  `private.audit_security`, `create_integration_user`, `set_integration_user_status`, `security_members` with `kind`,
  last-admin guard and fan-out count people only) and `9_2_api_key` (`private.api_key`, `private.api_key_usage`,
  `create_api_key`, `revoke_api_key`, `api_keys()`, `private.api_key_identity`, daily purge
  `assetly_purge_api_key_usage` at 03:41 UTC).
- `api_key_identity` takes the whole key and splits it in SQL. The auth user is banned until `2999-12-31`, not
  `infinity`, to stay a plain date for Auth's own parsing. No new index: the 3.1 `asset_updated_idx` serves the cursor.
- Key and integration-user changes are audited by `private.audit_security` (no secret, no hash), not the row
  trigger, so the hash never reaches the audit log or the outbox (and 9.3 webhooks).
- The asset domain is `asset_core` (the design said `asset`).
- Service: `withKey` in `src/db.ts`, routes in `src/v1.ts`, `@fastify/swagger` 9.9.3. Fastify's Ajv now refuses
  unknown body fields instead of stripping them (`removeAdditional: false`), so a `PATCH` with `status` is a 422, not a
  silent no-op. Writing `purchase_value` without `asset_financials.update` is a 403 (the 3.3 trigger).
- `/v1/me` returns `user_id, name, tenant_id, tenant_name`. Master-data lists are one page (`next_cursor: null`).
- Web: an "Integrations" tab on `/security`, shown with `api_keys.view`. Member pickers show "(Integration)" instead
  of the placeholder email.
- Customer docs: `docs/api-v1.md`. No new environment variable.
- Tests: `supabase/tests/9_2_api_keys.test.sql` (52), `services/api/test/v1.test.ts` (12),
  `apps/web/src/Security.test.tsx` (+3).

**Goal:** an admin creates an integration user, gives it groups like any user, and issues an API key. An external
script calls `/v1` with the key and reads (and, if its groups allow, writes) assets. It sees exactly what a person
with the same groups and scope would see. Review point of Goal 9 (second half): "an external script reads assets
through the API".

**Already decided, not reopened:**
1. CLAUDE.md §6.7: `/v1` is its own contract, not Supabase's auto API. §7.3: one engine for UI, API, integration users.
2. 8.1: every query goes through `withUser` (role `assetly_api`, `noinherit`, `set_config(..., true)` per
   transaction). No service-role key. No minted JWTs (8.1 §2 rejected minting: too much power).
3. technical-architecture.md §6: `/v1`, OpenAPI documented, cursor paging, keys per tenant, hashed, shown once,
   revocable, mapped to an integration user, rate limits and usage logs per key.
4. Webhooks are 9.3.

**Facts checked (5 Nov 2026):**
- Domain `api_keys` (platform, `view`, `manage`) is seeded since 1.2. Starter groups: Administrator holds both,
  Auditor holds `view`. No new domain is needed for the keys screen.
- Every identity is a `user_profile` row, and `user_profile.id` references `auth.users (id)`. Every `created_by`,
  `updated_by`, membership, group assignment, scope profile and `user_effective_permission` row points at
  `user_profile`. `auth.uid()` reads `sub` from the claims the service sets.
- `has_permission`, the 6.1 scope helpers and the 6.2 secure views (`asset_view`, `hidden_field_keys`) read only
  `auth.uid()` and `tenant_id`. So an identity that is a `user_profile` with a membership gets the whole engine
  with **no policy change**.
- The UI writes assets with plain `insert` and `update` on `public.asset` under RLS (3.3 write-rule triggers),
  status through `change_asset_status`, location through `transfer_asset`. `asset.tag` is unique per tenant.
- 9.1 fan-out notifies every active member who holds `obligation.update` or `coverage_contract.update`, and queues a
  daily email to `user_profile.email`. The 6.3 last-admin guard counts active members with `users_security.manage`.
  An integration user would be caught by both unless excluded (A12).
- `docs/assetly-screens.html` has no API keys or integrations screen. The Security screen exists (6.3).
- The service already registers `@fastify/cors` with an allowlist for the web app (8.2).

### Flow

```
script -- Authorization: Bearer asly_<prefix>_<secret> --> service /v1/...
  begin
    as assetly_api, no role set:  select * from private.api_key_identity(prefix, secret)
                                  (hash check, expiry, revoke, membership, rate count)
    set_config('role', 'authenticated', true), set_config('request.jwt.claims', {sub, tenant_id, ...}, true)
    the route's queries, under RLS, as the integration user
  commit
```

One transaction, one extra statement. The key never leaves the service; Postgres stores only its hash.

### A1 What an integration user is

| Option | For | Against |
|---|---|---|
| **a A real `auth.users` row with no password and no identity, plus `user_profile.kind = 'integration'`, plus a normal `tenant_membership`** | Every FK, group assignment, scope profile, secure view, audit `created_by` and the explainer (6.5) work unchanged. It cannot sign in: no password, no identity, `banned_until = 'infinity'`. Same SQL insert as `seed.sql` | Writes to `auth.users` from a migration-owned function (a Supabase table; on a move to self-hosting this becomes a plain `users` row). Placeholder email `<id>@integration.invalid` |
| b A separate `integration_user` table | Clean split from people | Every FK to `user_profile` (dozens), `user_effective_permission`, scope and the explainer must accept a second identity type. Large, risky change to the security engine |
| c No integration user: a key acts as the person who made it | Smallest | The key dies when the person leaves; audit shows the person; breaks security-model.md §3 |

**Lean: a.** One integration user belongs to one tenant only. Cost to reverse: **high** once keys and audit rows exist.

### A2 Who creates them, and how they get rights

- `public.create_integration_user(name)` and `public.set_integration_user_status(id, active|disabled)`: need
  `users_security.manage` and `tenant_can_write()`, because an integration user is an identity that will hold groups.
- Groups and scope are assigned on the existing Security screen (6.3), through the 6.4 change sets, like a person.
  No new path to grant rights.
- Keys (A3, A4) need `api_keys.manage`.

| Option | |
|---|---|
| **a Two domains as above** (`users_security.manage` for the identity and its groups, `api_keys.manage` for keys) | A key holder can only use rights a security admin gave the integration user |
| b `api_keys.manage` for everything | One domain; but a key admin could create an identity and (with 6.3) grant it rights |

Note for a: a holder of `api_keys.manage` can issue a key for **any** integration user in the tenant, so gets that
user's rights in a script. Fine for pilots (only Administrator holds it). **Lean: a.** No new starter group: the admin
assigns an existing group (for example Auditor for read-only) or makes one. Cost to reverse: low.

### A3 Key format and storage

- Format: `asly_` + 12-character public prefix + `_` + 32 random bytes (base64url, 43 characters). The `asly_`
  start lets secret scanners (GitHub push protection) spot leaked keys later.
- Made in Postgres by `public.create_api_key(integration_user_id, name, expires_at)` with `gen_random_bytes`
  (`pgcrypto`, already on). Returns the full key **once**. The web app shows it once with a copy button.
- Stored: `private.api_key (id, tenant_id, integration_user_id, name, prefix unique, secret_hash bytea, expires_at,
  revoked_at, revoked_by, last_used_at, created_at, created_by)`. `secret_hash = sha256(secret)`. Plain SHA-256 is
  enough for 256-bit random secrets (bcrypt only helps against guessable passwords, and costs CPU per request).
- The table is in `private`: no grants to `authenticated`. Admins read it through `public.api_keys()` (needs
  `api_keys.view`), which never returns the hash.

| Option | |
|---|---|
| **a As above** | Fast lookup by prefix; nothing secret at rest |
| b Generated in the service | Needs a service route for the web app; the hash would still be in Postgres |
| c Hash with HMAC and a pepper in Secret Manager | A stolen database dump cannot be checked against guesses; but 256-bit secrets cannot be guessed anyway; one more secret |

**Lean: a.** Cost to reverse: low before customers hold keys, medium after (a format change means new keys).

### A4 Expiry, rotate, revoke

| Option for expiry | |
|---|---|
| a Optional, default never | Common, convenient |
| **b Required: 90 days, 1 year (default) or a date up to 2 years** | A forgotten key ends by itself |
| c 90 days fixed | Safest; pilots rotate often |

- Rotate = create a second key, switch the script, revoke the old one. Up to 5 active keys per integration user.
  No in-place rotate.
- `public.revoke_api_key(id)`: sets `revoked_at`; takes effect on the next request (every request checks).
- Disabling the integration user or its membership stops all its keys. A suspended tenant stops all keys.
- `last_used_at` is updated at most once a minute per key (no extra write per request; it rides on the A6 counter).

**Lean: b.** Cost to reverse: none.

### A5 How a key becomes a database identity

`private.api_key_identity(prefix, secret)`: `security definer`, fixed `search_path`, `execute` granted to
`assetly_api` only (not `authenticated`, not `anon`). It runs before the role switch, so it is the one function the
base role can use. It returns `user_id, tenant_id, key_id, calls_this_minute` only if the hash matches, the key is
not revoked or expired, the integration user and membership are active and the tenant is not suspended. Otherwise no
row, and the service answers `401` with one generic message (no hint whether the prefix exists).

`db.ts` gains `withKey(key, fn)`, next to `withUser`: same transaction, the lookup first, then the same
`set_config` call with claims `{sub: user_id, tenant_id, role: 'authenticated', aud: 'authenticated',
api_key_id}`. Postgres sees an ordinary user. The 8.1 leak test gains key requests.

| Option | |
|---|---|
| **a As above** | No service-role key, no signing key in the service, no new role |
| b Mint a short Supabase JWT per key | Needs the signing key in the service: rejected in 8.1 §2 |
| c Look up keys with the service-role key | Forbidden (CLAUDE.md §6.4) |

Header: `Authorization: Bearer <key>`. **Lean: a.** Cost to reverse: low (one module).

### A6 Rate limits and metering (Postgres only)

| Option | For | Against |
|---|---|---|
| **a One counter row per key per minute** in `private.api_key_usage (key_id, tenant_id, minute, calls)`, upserted inside A5. Over the limit: `429` with `Retry-After`. Daily usage = sum of rows | Exact across instances; the same rows are the usage log; no Redis | One small write per request (at 120 a minute per key it is nothing for Postgres) |
| b In-memory counter in each instance | No write | Not exact (2 instances, scale to zero resets); still needs a usage table |
| c Only Cloud Run `--max-instances` | Nothing to build | No per-key limit |

Limit: **120 calls a minute per key**, one constant in the service for now (per-tenant limits later, via
`tenant_entitlement`). Rows older than 90 days are deleted by a daily `pg_cron` job. **Lean: a.** Cost to reverse: low.

### A7 Audit

- Data changes made through the API are audited as today: the audit trigger records the integration user as actor.
  Also `api_key_id` from the claims in the audit row, so it shows which key did it (small; **lean: yes**).
- Key create and revoke, and integration user create and disable, write `security` audit rows and outbox events,
  like 6.3 changes.
- Per-request lines go to Cloud Logging (time, method, path, status, ms, tenant, key prefix; never the key). No
  per-request row in Postgres beyond the A6 counter.

**Lean: as above.** Cost to reverse: low.

### A8 First resources (minimal)

| Route | Reads or calls | Domain checked (by RLS, not the service) |
|---|---|---|
| `GET /v1/me` | the key's integration user and tenant | none |
| `GET /v1/assets` | `asset_view` (masked fields null, custom fields filtered, 6.1 scope) | `asset.view` |
| `GET /v1/assets/{id}` | `asset_view` | `asset.view` |
| `POST /v1/assets` | `insert into asset` (same write-rule triggers as the UI form) | `asset.create` |
| `PATCH /v1/assets/{id}` | `update asset`; no status or location change (those are actions) | `asset.update` |
| `GET /v1/categories`, `/v1/locations`, `/v1/asset-statuses` | the same tables or functions the UI reads | their own `view` |

Asset fields in and out are the asset form's fields, by name, with `category_id` and `location_id` as ids.
Not in v1: status change, transfer, retire, vendors, coverage, obligations, service records, attachments, import,
upsert by tag. Each is an additive endpoint later.

| Option | |
|---|---|
| a Read only (`me`, assets, master data) | Meets the review point; smallest |
| **b a, plus asset create and update** | A real integration (an ERP sends new assets); same triggers as the UI |
| c b, plus `PUT /v1/assets/by-tag/{tag}` upsert | Inbound sync by external reference (technical-architecture.md §6); more edge cases |

**Lean: b**, c later. Cost to reverse: low (endpoints are additive).

### A9 Versioning rule

- Major version in the path: `/v1`. Inside v1 only additive changes: new endpoints, new optional parameters, new
  response fields. Clients must ignore unknown fields.
- A breaking change means `/v2`. `/v1` keeps working at least 12 months after `/v2` ships, with a `Deprecation`
  header.
- JSON field names are `snake_case`, same as the database. Dates ISO 8601, timestamps UTC.

**Lean: as above.** Cost to reverse: none now; high after customers rely on it.

### A10 Paging, filtering, errors

- **Cursor paging (lean):** `?limit=` (default 50, max 200) and `?cursor=` (opaque, base64url of the last
  `(updated_at, id)`). Response `{ "data": [...], "next_cursor": "..." | null }`. Ordered by `updated_at, id`, so a
  sync script can page with `?updated_since=` and never misses or repeats rows. No total count (costly on large
  tenants). Offset paging is simpler but skips or repeats rows when data changes, and deep pages are slow.
- Filters on `GET /v1/assets`: `updated_since`, `category_id`, `location_id` (with descendants, like the UI),
  `status`, `tag`. Nothing else in v1.
- **Errors: `application/problem+json` (RFC 9457) (lean):** `{ "type", "title", "status", "detail", "code" }`, where
  `code` is a stable string (`unauthorized`, `forbidden`, `not_found`, `validation_failed`, `rate_limited`,
  `conflict`). Validation errors add `errors: [{ "field", "code" }]`. The existing non-`/v1` routes keep
  `{ "error": code }`. The other option is plain `{ "error": code }` for `/v1` too: simpler, not a standard.
- Not found and not allowed to see both answer `404` (no hint that the row exists). Allowed to see but not to write:
  `403`.

**Lean: cursor and problem+json.** Cost to reverse: medium after customers rely on it.

### A11 OpenAPI spec

| Option | |
|---|---|
| **a Generated from the Fastify route schemas with `@fastify/swagger`** (official plugin, one new dependency), served at `GET /v1/openapi.json`. The same JSON schemas validate requests | Spec and code cannot drift; validation for free |
| b Hand-written `openapi.yaml` | No dependency; drifts |
| c No spec in 9.2 | Smallest; breaks technical-architecture.md §6 |

No Swagger UI in the service (customers open the JSON in any viewer). A test checks the spec builds. **Lean: a.**
Cost to reverse: low.

### A12 Integration users and the rest of the product

- 9.1 fan-out and the daily email skip `kind = 'integration'` (they cannot read mail; the address is fake).
- The 6.3 last-admin guard does not count integration users (an integration user cannot be the last security admin).
- The Security screen lists them with an "Integration" tag. They cannot be invited, sign in or pick a tenant.

**Lean: as above.** Cost to reverse: low.

### A13 The keys screen

No screen in `docs/assetly-screens.html`. Lean: a new tab **"Integrations"** on the existing `/security` page
(`/security?tab=integrations`), shown with `api_keys.view`:
- List of integration users (name, status, groups, number of keys). "New integration user" (needs
  `users_security.manage`). Groups are edited in the existing member panel, so no second editor.
- Per integration user: keys (name, prefix, created, expires, last used, status). "New key" opens a dialog: name and
  expiry; then shows the key once with Copy and the line "You will not see this key again". "Revoke" with a confirm.
- Manage buttons need `api_keys.manage`. All text in `en.json`.

Option b: a separate `/settings/api` page. Lean a, since identities and groups already live on Security. Cost to
reverse: low.

### A14 CORS, user tokens, customer documentation

- **CORS:** `/v1` is server to server. The existing CORS plugin skips `/v1` (no `Access-Control-Allow-Origin`), so a
  browser page cannot call it. **Lean: yes.** Cost to reverse: none.
- **User tokens on `/v1`:** `/v1` accepts only API keys in 9.2; a signed-in user's token there is `401`. Accepting
  both later (for the web app or the AI assistant) is additive. **Lean: keys only.**
- **Docs for customers:** `docs/api-v1.md` in the repo (quick start with `curl`, auth, paging, errors, limits,
  versioning) plus `GET /v1/openapi.json`. A public docs site comes when the first customer asks. **Lean: as above.**

### Owner steps after the build (I never handle keys or passwords)

1. Push the migrations to staging (your usual `db push` from current `main`).
2. Run "Deploy API". No new secret: the service uses the existing `assetly-api-db-url`.
3. On staging, create an integration user and a key on the Security screen, then try the `curl` in the demo note.

### DECIDE (9.2)

| # | Decision | Options | Lean | Cost to reverse |
|---|---|---|---|---|
| A1 | Integration user | a `auth.users` row with no password + `user_profile.kind` + membership, b own table, c key acts as its creator | a | **High** |
| A2 | Who creates | a `users_security.manage` for identity and groups, `api_keys.manage` for keys, b `api_keys.manage` for all | a, no new starter group | Low |
| A3 | Key format, storage | a `asly_<prefix>_<secret>`, made in Postgres, SHA-256 hash in `private`, shown once, b made in service, c HMAC + pepper | a | Low now, medium later |
| A4 | Expiry | a optional, b required (90 d / 1 y default / date up to 2 y), c 90 d fixed; rotate = new key + revoke, max 5 active | b | None |
| A5 | Key to identity | a `private.api_key_identity` for `assetly_api` only, then `withKey` sets claims, b mint JWT, c service-role key | a, `Bearer` header | Low |
| A6 | Rate limit, metering | a per-minute counter rows in Postgres, 120/min per key, 90-day purge, b in-memory, c none | a | Low |
| A7 | Audit | data via the existing trigger (+ `api_key_id`), key and identity changes as security audit, requests in Cloud Logging | as A7 | Low |
| A8 | First resources | a read only, b read + asset create and update, c b + upsert by tag | b | Low |
| A9 | Versioning | `/v1` in path, additive only, `/v2` for breaks with 12 months overlap, snake_case | as A9 | None now |
| A10 | Paging, errors | cursor on `(updated_at, id)`, limit 50/200, problem+json, 404 for unseen | as A10 | Medium later |
| A11 | OpenAPI | a `@fastify/swagger` from route schemas, b hand-written, c none | a (new dependency) | Low |
| A12 | Rest of product | skip in notifications and email, not counted as last admin, tagged on Security | as A12 | Low |
| A13 | Keys screen | a "Integrations" tab on `/security`, b `/settings/api` | a | Low |
| A14 | CORS, tokens, docs | no CORS on `/v1`; keys only on `/v1`; `docs/api-v1.md` + `/v1/openapi.json` | as A14 | None |

**Smaller option:** A8 a (read only) and no screen; an admin makes keys with a SQL function on staging. Meets the
review point with about half the work, but you create keys by hand. **Say if you want this instead.**

**Not in 9.2:** webhooks (9.3), upsert by tag, actions through the API (transfer, status, retire), bulk import by
API, per-tenant rate limits, key scopes narrower than the integration user's groups, IP allowlists, a public docs
site, OAuth client credentials, user tokens on `/v1`.

---

## 18. Story 9.3: webhooks with signing and retries

**Status:** design, 5 Nov 2026. Nothing built. **Webhook signing and secrets are an owner-review area (CLAUDE.md §9).**

**Goal:** an admin points a webhook at an HTTPS URL for chosen events. Each event is sent once per subscription,
signed, retried on failure, and carries only what the subscriber identity may see (6.2 R3). Review point: "an
external receiver gets a signed `asset.created` and can verify it; a field the identity cannot see is not in it".

**Already decided, not reopened:**
1. §3 N2: the 9.1 fan-out is the one outbox publisher. Webhooks fill their own delivery table in the same step.
2. §17 A1: integration users are real identities with groups and scope. §17 A5: the service runs queries as an
   identity by setting claims per transaction (`withUser`, `withKey`). One engine (CLAUDE.md §7.3).
3. §10 N10: system jobs run as role `assetly_jobs` with execute on named definer functions only, called by Cloud
   Scheduler with OIDC. No service-role key.
4. 6.2 R3: outbox rows carry raw `old` and `new`. They must never be sent as they are.

**Facts checked (5 Nov 2026):**
- Outbox event types now: `<table>.insert|update|soft_delete|delete` (audit trigger), `obligation.due_soon|overdue`
  (5.1), `coverage.expiring|expired` (9.1). Coverage-state refreshes write no event (4.4 C12). Status changes and
  transfers update `asset`, so they arrive as `asset.update`. An import commit (8.6) writes one `asset.insert` per row.
- The fan-out marks every event no consumer wants as published, up to 50,000 a run (§3). It must stop doing that for
  events a live subscription wants.
- `public.asset_view` (6.2) already masks money fields and filters custom-field keys for `auth.uid()`. `/v1`
  builds its asset object from it (`ASSET_COLUMNS` in `services/api/src/v1.ts`).
- Domain `api_keys` (`view`, `manage`) exists; Administrator holds both, Auditor `view`.
- No webhook screen in `docs/assetly-screens.html` (open-items Section D lists it as missing).
- Cloud Scheduler: 3 free jobs per billing account; 9.1 uses one.

### Flow

```
change ──> outbox_event ──> fan-out (pg_cron, 1 min) ──> webhook_delivery rows (one per live subscription that wants the type)
Cloud Scheduler (1 min) ──> POST /jobs/webhooks (service)
   as assetly_jobs:  private.claim_webhooks(200)  -> delivery, url, secret(s), event, identity
   as assetly_api:   withUser({sub: integration user, tenant_id}) -> build payload from asset_view etc. (RLS + 6.2 masks)
   HTTPS POST, signed ──> receiver
   as assetly_jobs:  private.finish_webhook(id, ok, status_code, error, ms) -> succeeded | retry later | failed
```

### W1 Who owns a webhook (the subscriber identity)

| Option | For | Against |
|---|---|---|
| **a An integration user (9.2).** The subscription names one; payloads are built as that identity | Masking, scope and lost grants come from the existing engine. Same identity as the customer's API key, so webhook and `/v1` show the same fields | The admin must make an integration user first (already needed for a key) |
| b The person who created it | No extra step | Breaks when the person leaves or changes groups; rejected for keys in A1 c |
| c No identity, mask everything sensitive | Simple | Not "masked by the subscriber's field domains"; useless for finance integrations |

**Lean: a.** Disabling the integration user, its membership or the tenant (suspended) stops its webhooks.
Cost to reverse: medium once customers rely on it.

### W2 Who manages webhooks

| Option | |
|---|---|
| **a Reuse `api_keys`** (`view` lists subscriptions and deliveries, `manage` creates, edits, rotates, disables) | Same people, same screen, same owner-review area. No new domain or starter-group seed |
| b New domain `webhooks` (`view`, `manage`) | Finer control; a seed migration and starter-group change to review |

**Lean: a.** Cost to reverse: low (b is a later seed migration plus a function change). Note: as with keys (A2), a
`manage` holder can point any integration user's data at any URL.

### W3 Event types (v1 catalogue)

| Webhook type | From outbox | Payload `data` |
|---|---|---|
| `asset.created` | `asset.insert` | `{ asset }` |
| `asset.updated` | `asset.update` (includes status change, transfer, retire) | `{ asset }` |
| `asset.deleted` | `asset.soft_delete` | `{ asset }` (soft-deleted rows stay readable) |
| `obligation.due_soon`, `obligation.overdue` | 5.1 | `{ asset, obligation: { id, name, due_date } }` |
| `coverage.expiring`, `coverage.expired` | 9.1 | `{ asset, coverage: { id, vendor_id, end_date } }` |
| `webhook.test` | the "Send test" button | `{}` |

A subscription picks one or more types (no wildcard). Nothing else in 9.3: no vendor, location, category, service
record, security or import-level events. Each is additive later. `asset.updated` has **no list of changed fields**
in v1: the raw diff can name a hidden field (W4).

| Option | |
|---|---|
| **a As above** | Matches the knowledge base F17 (asset created, coverage expiring, service overdue) plus update and delete for sync |
| b Alerts only (obligation and coverage) | Smallest; no sync use |
| c Every table event | Large masking surface; one object shape per table |

**Lean: a.** Cost to reverse: low (types are additive).

### W4 Payload shape and masking (6.2 R3)

The outbox payload is **never sent**. The sender uses only `event_type`, `aggregate_id` (and the asset id for alert
events) from the outbox row, then reads the object **as the integration user** through `withUser` on the
`assetly_api` pool: the same `asset_view` select and `ASSET_COLUMNS` as `GET /v1/assets/{id}`, and RLS selects for
obligation and coverage. So:
- money fields come out null without `asset_financials.view`, hidden custom keys are absent, scope applies;
- a row the identity cannot see (no `view`, out of scope) gives no object: the delivery is marked `skipped`, not sent;
- the object is its state **at send time**, so a retry carries the newest state.

Body (Standard Webhooks shape, W5):

```json
{ "type": "asset.updated", "timestamp": "2026-11-05T10:00:00Z",
  "data": { "event_id": "<outbox id>", "occurred_at": "...", "tenant_id": "...", "asset": { "...": "same as GET /v1/assets/{id}" } } }
```

| Option | For | Against |
|---|---|---|
| **a Fat event, built at send time as the identity** (above) | Masking by the one engine, no second mask list; same shape as `/v1` | One extra read per delivery; not a snapshot of the moment |
| b Thin event (`type` + ids only); the receiver calls `/v1` | No masking question at all; smallest | Every receiver needs a key and a second call; alert details not in `/v1` yet |
| c Mask the outbox diff in SQL per subscriber | Snapshot of the change | A second mask implementation that can drift from 6.2: the leak R3 warns about |

**Lean: a.** Not stored: bodies are rebuilt on each attempt, so no masked data sits in the delivery log. Cost to
reverse: medium after customers rely on the shape.

### W5 Signing

**Standard Webhooks** (an open spec; receivers can use its published libraries):
- Headers `webhook-id` (the delivery id, same on every retry, for dedupe), `webhook-timestamp` (Unix seconds),
  `webhook-signature: v1,<base64 HMAC-SHA256(secret, id + "." + timestamp + "." + body)>`.
- Secret `whsec_` + base64 of 32 random bytes, made in Postgres with `gen_random_bytes` (like A3), **shown once**
  at create and at rotate.
- Replay window: the receiver rejects a timestamp more than 5 minutes old (stated in `docs/api-v1.md`, with a
  Node and a Python verify snippet).
- Rotate: a new secret; the old one keeps signing for 24 hours. During the overlap the header carries both
  signatures (`v1,<new> v1,<old>`), which the spec allows. Receivers swap at their pace.

| Option for storing the secret | For | Against |
|---|---|---|
| **a Plain in a `private` table**, readable only by `claim_webhooks` (jobs role) and never by any `authenticated` path | Simple; HMAC needs the raw secret, so a hash cannot work. A leaked secret lets someone forge webhooks to the customer; it reads no data | A database dump holds the secrets |
| b Encrypted with a key in Secret Manager (service encrypts and decrypts, `node:crypto` AES-GCM) | A dump alone is useless | One more secret; creation and rotate must go through the service (a new user route), not a SQL function |
| c Supabase Vault | Encrypted at rest, in SQL | Supabase-only (portability, CLAUDE.md §3) |

**Lean: a,** with the reasons above. Cost to reverse: low (b is a migration plus a re-encrypt of a few rows).

### W6 Who sends, how often

| Option | For | Against |
|---|---|---|
| **a Service, `POST /jobs/webhooks`, Cloud Scheduler every minute with OIDC** (second of three free jobs) | Same path as 9.1 email (N1, N10); signing secret and HTTP calls stay out of Postgres | Cold start once a minute (Cloud Run free tier covers it); about 1 to 2 minutes from change to delivery |
| b `pg_cron` + `pg_net` | No scheduler job | Supabase-only; HTTP from the database; hard SSRF control |
| c Every 5 minutes | Fewer cold starts | Up to 6 minutes late |

**Lean: a.** One run claims up to 200 deliveries, sends 10 at a time, 10 s timeout each, stops after 50 s. A run
that hits the cap leaves the rest for the next minute. Cost to reverse: low.

### W7 Enqueue, claim, retry, dead letter, auto-disable

- **Enqueue** (in `private.fan_out_events`, before the bulk "published" mark): one `insert ... select` of
  `private.webhook_delivery` rows for every unpublished event whose tenant has a live subscription for its mapped
  type, `unique (subscription_id, event_id)`, `on conflict do nothing`. No permission check here; it happens at send
  (W4), so a grant lost in between counts too.
- **Claim:** `private.claim_webhooks(n)`, security definer, `for update skip locked`, rows `pending` and due, or
  `sending` older than 2 minutes (crashed run). Oldest first. At most 20 per subscription per run, so one big import
  for one customer does not starve the others.
- **Success:** any 2xx within 10 s. Redirects are not followed (W8). Everything else, timeouts and network errors
  are failures.
- **Retry backoff** (from the first try): 1 min, 5 min, 30 min, 2 h, 6 h, 12 h, 24 h, 24 h: 9 attempts over about
  3 days. Then `failed` (the dead letter: the row stays, visible in the log, W9). A `410 Gone` fails at once.
- **Auto-disable:** a subscription whose deliveries have all failed for 3 days (no 2xx since, at least one `failed`)
  is set `disabled_failing`. New events stop queuing for it. The admin sees it on the screen and re-enables it;
  missed events are not re-sent.
- **Ordering:** none promised. Receivers order by `occurred_at` or `asset.updated_at`. At least once: dedupe on
  `webhook-id`.

| Option | |
|---|---|
| **a As above** | Industry-normal (Stripe, Svix retry for about 3 days) |
| b 5 tries over 1 day, like 9.1 email | Simpler; a weekend outage at the receiver loses events |
| c a plus "Resend" on a failed delivery | Useful; one more function and button. Later |

**Lean: a.** Cost to reverse: low.

### W8 Target URL and SSRF guards

- `https://` only, port 443 only, no user and password in the URL, at most 2,000 characters. Checked in SQL on
  create and edit, and again in the service.
- The service resolves the host itself and refuses private, loopback, link-local (`169.254.0.0/16`, the cloud
  metadata server), CGNAT, multicast and IPv6 local ranges, then connects to the checked address (`node:https` with
  a `lookup` hook, so DNS rebinding cannot swap it). Stdlib only, no new dependency.
- Redirects are not followed. The response body is read up to 1 KB for the log, then dropped.
- Locally and in tests, `WEBHOOK_ALLOW_INSECURE=1` allows `http://` and loopback. Never set on Cloud Run.

| Option | |
|---|---|
| **a As above** | Blocks the known SSRF paths with stdlib |
| b a, plus an egress proxy or VPC firewall | Stronger; costs money and setup |
| c Only the scheme check | Smallest; the metadata server is reachable |

**Lean: a.** Cost to reverse: low.

### W9 Data, limits, retention

- `private.webhook_subscription (id, tenant_id, integration_user_id, url, event_types text[], status
  active|disabled|disabled_failing, secret, previous_secret, previous_until, last_success_at, created_at,
  created_by, updated_at, updated_by, deleted_at)`. RLS on, no policies, no grants to `authenticated` (like
  `api_key`). Composite FK `(tenant_id, integration_user_id)` to membership.
- `private.webhook_delivery (id, tenant_id, subscription_id, event_id, event_type, status
  pending|sending|succeeded|failed|skipped, attempts, next_try_at, claimed_at, last_status_code, last_error,
  last_ms, created_at, finished_at)`. No body stored (W4).
- Public functions (security definer, fixed `search_path`, checking `api_keys` and `tenant_can_write()` for writes):
  `webhooks()`, `create_webhook(integration_user_id, url, event_types)` returns the secret once,
  `update_webhook(id, url, event_types)`, `set_webhook_status(id, active|disabled)`,
  `rotate_webhook_secret(id)` returns the new secret once, `delete_webhook(id)` (soft), `webhook_deliveries(id)`
  (last 100, no body), `test_webhook(id)` (queues a `webhook.test`).
- Limits: 10 live subscriptions per tenant; body at most 256 KB (larger: delivery `failed` with "too large", which
  only an asset with huge custom fields could hit).
- Delivery rows older than 30 days are deleted by a daily `pg_cron` job (like the 9.2 usage purge).

**Lean: as above.** Cost to reverse: low before customers, medium after.

### W10 Audit

Subscription create, edit, status change, rotate and delete write `security` audit rows through
`private.audit_security` (9.2), **never the secret**. No row trigger on the two tables, so the secret never reaches
`audit_log` or the outbox (and a webhook about webhooks cannot loop). Deliveries are not audited (the delivery log is
the record); each failure is also logged at `ERROR` by the service, so the 9.1 N8 b alert covers it.

### W11 UI

No screen in `docs/assetly-screens.html`. Lean: a **Webhooks** section in each integration user's panel on the
existing Integrations tab (`/security?tab=integrations`), under its keys:
- List: URL, events, status tag (Active, Disabled, Failing), last success.
- "New webhook": URL and event checkboxes; then the secret once, with Copy and "You will not see this secret again".
- Per row: Edit, Send test, Rotate secret (secret once), Disable or Enable, Delete (confirm).
- "Deliveries": the last 100 (time, event, status, HTTP code, attempts, error).
- Buttons need `api_keys.manage`; the list needs `api_keys.view`. All text in `en.json`.

Option b: its own `/security?tab=webhooks` tab listing all subscriptions. Lean a: a webhook belongs to an
integration user, like a key. Cost to reverse: low.

### W12 Jobs role, endpoint, owner steps

- `assetly_jobs` gains execute on `private.claim_webhooks` and `private.finish_webhook` only. Payload reads run on
  the `assetly_api` pool as the integration user (W4), so the jobs role still reads no table.
- `POST /jobs/webhooks`, same OIDC check as `/jobs/email`, on only when `JOBS_AUDIENCE` is set.
- **Owner steps after the build:** push the migrations; deploy the API (no new secret); create the second Cloud
  Scheduler job, every minute, OIDC, URI `$API_URL/jobs/webhooks` (command in the demo note).

### Smaller option

W3 b (alerts only) plus W4 b (thin events) and no screen (SQL functions on staging): drops masking and the UI,
about a third of the work. It does not meet "payloads masked by the subscriber's field domains" in any useful way.
**Say if you want it.**

### DECIDE (9.3)

| # | Decision | Options | Lean | Cost to reverse |
|---|---|---|---|---|
| W1 | Subscriber identity | a integration user, b creator, c none (mask all) | a | Medium later |
| W2 | Managing domain | a reuse `api_keys`, b new `webhooks` domain | a | Low |
| W3 | Event types | a asset created / updated / deleted + 4 alerts + test, b alerts only, c every table | a, no changed-field list | Low |
| W4 | Payload and masking | a fat, built at send as the identity from `asset_view`, b thin ids only, c mask the diff in SQL | a, not stored | Medium later |
| W5 | Signing and secret | Standard Webhooks headers, `whsec_`, 5 min replay window, 24 h rotate overlap; store a plain in `private`, b encrypted with a service key, c Vault | a | Low |
| W6 | Sender | a service via Cloud Scheduler every minute, b `pg_cron` + `pg_net`, c every 5 min | a, 200 a run, 10 parallel, 10 s timeout | Low |
| W7 | Retry and disable | a 9 tries over ~3 days, `failed` dead letter, auto-disable after 3 days of failure, b 5 tries / 1 day, c a + Resend | a | Low |
| W8 | SSRF | a https:443, resolve and block private ranges, pin address, no redirects, b + egress proxy, c scheme only | a | Low |
| W9 | Data, limits | two `private` tables, definer functions, 10 subscriptions a tenant, 256 KB body, 30-day log | as W9 | Low now |
| W10 | Audit | `audit_security`, no secret, no row trigger | as W10 | Low |
| W11 | UI | a Webhooks section per integration user on Integrations, b own tab | a | Low |
| W12 | Jobs path | `assetly_jobs` + 2 functions, `/jobs/webhooks` OIDC, second scheduler job | as W12 | Low |

**Not in 9.3:** Resend or replay of a failed delivery, changed-field lists, wildcard or filtered subscriptions
(by location or category), events for vendors, locations, service records, imports or security, ordering
guarantees, mTLS or IP allowlists for receivers, an egress proxy, per-tenant delivery quotas, notifying admins when
a webhook is auto-disabled (shown on the screen only), WhatsApp (9.4), MCP (9.5).
