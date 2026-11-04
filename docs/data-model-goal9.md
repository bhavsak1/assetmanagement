# Goal 9 data model: notifications (story 9.1)

**Status:** design, waiting for the owner's answers to §10 (4 Nov 2026). Nothing built yet.

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

**Lean: a Resend for staging and pilots**, behind one `sendEmail()` function. Move to SES when volume passes the
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
| N5 | Email provider | a Resend, b SES, c Brevo | a (SES later) | Low |
| N6 | Email timing | a daily summary 08:00 tenant time, b every 15 min, c per event | a | Low |
| N7 | Preferences | a none, b one email switch, c matrix | b | Low |
| N8 | Failures | a data + logs, b plus a Cloud Monitoring email alert, c jobs page (BL-1) | b | Low |
| N9 | Forgot password | a separate story 9.1b, b in 9.1 | a | None |
| N10 | Jobs role and endpoint | a `assetly_jobs` with two functions + OIDC, b reuse `assetly_api`, c shared secret | a | Low |
| N11 | Size of 9.1 | a full (in-app + email), b in-app only, email to 9.1b (§12) | a | Low |

## 14. Owner steps (after §13, only if email is in)

1. Pick or buy a domain. Create the Resend account, add its DNS records, create an API key with send rights only.
2. Put the key in Secret Manager as `EMAIL_API_KEY`; I add the variable to `.env.example` and the deploy workflow.
3. Create the `assetly_jobs` password secret and the Cloud Scheduler job (I write the `gcloud` commands).
4. Optional (N8 b): the log alert command.

## 15. Not in 9.1

Webhooks (9.3), WhatsApp (9.4), the `/v1` API (9.2), escalation, quiet hours, per-event preferences, a jobs page
(BL-1), push notifications, notification retention or purge.
