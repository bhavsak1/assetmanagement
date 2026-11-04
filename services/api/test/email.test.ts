// Story 9.1: the email summary job, its OIDC check and the /jobs/email route.
import assert from 'node:assert/strict';
import { after, before, test } from 'node:test';
import { createLocalJWKSet, exportJWK, generateKeyPair, SignJWT } from 'jose';
import pg from 'pg';
import { buildApp } from '../src/app.ts';
import { createJobsDb } from '../src/db.ts';
import { createJobsVerifier, formatDate, render, runEmailJob, type Claimed, type Mail } from '../src/email.ts';
import { TENANT_A } from './helpers.ts';

const ADMIN_DATABASE_URL = process.env.ADMIN_DATABASE_URL ?? 'postgres://postgres:postgres@127.0.0.1:54322/postgres';
const JOBS_DATABASE_URL = process.env.JOBS_DATABASE_URL ?? 'postgres://assetly_jobs:assetly-local-jobs@127.0.0.1:54322/postgres';
const ADMIN_A = '00000000-0000-0000-0000-0000000a0001'; // admin.a, tenant admin: obligation view tenant-wide
const ASSET = '00000000-0000-0000-0000-00000091f0a1';

const claimed: Claimed = {
  id: 'x', email: 'a@example.com', display_name: 'Asha', tenant_name: 'Acme', date_format: 'dd-MM-yyyy',
  lines: [
    { event_type: 'obligation.overdue', asset_id: 'a', payload: { name: 'Service', asset_name: 'Pump\nX', asset_tag: 'P-1', next_due_date: '2026-11-01' } },
    { event_type: 'coverage.expiring', asset_id: 'a', payload: { asset_name: 'Boiler', end_date: '2026-12-31' } },
    { event_type: 'unknown.event', asset_id: 'a', payload: {} },
  ],
};

test('render: plain text lines in the tenant date format, control characters stripped', () => {
  const m = render(claimed, 'https://app.example');
  assert.equal(m.subject, 'Assetly: 2 new alerts for Acme');
  assert.equal(m.to, 'a@example.com');
  assert.match(m.text, /^- Overdue: Service on Pump X \(P-1\), due 01-11-2026$/m);
  assert.match(m.text, /^- Coverage expiring: Boiler, ends 31-12-2026$/m);
  assert.match(m.text, /https:\/\/app\.example\/notifications/);
  assert.doesNotMatch(m.text, /unknown/);
});

test('formatDate', () => {
  assert.equal(formatDate('2026-03-04', 'MM/dd/yyyy'), '03/04/2026');
  assert.equal(formatDate(null, 'dd-MM-yyyy'), '');
});

test('jobs verifier: Google-style OIDC token, audience and invoker checked', async () => {
  const { privateKey, publicKey } = await generateKeyPair('RS256');
  const jwks = createLocalJWKSet({ keys: [{ ...(await exportJWK(publicKey)), alg: 'RS256' }] });
  const verify = createJobsVerifier('https://api.example', 'sched@p.iam.gserviceaccount.com', jwks);
  const sign = (aud: string, email: string) => new SignJWT({ email, email_verified: true })
    .setProtectedHeader({ alg: 'RS256' }).setIssuer('https://accounts.google.com').setAudience(aud)
    .setExpirationTime('5m').sign(privateKey);
  assert.equal(await verify(await sign('https://api.example', 'sched@p.iam.gserviceaccount.com')), true);
  assert.equal(await verify(await sign('https://other.example', 'sched@p.iam.gserviceaccount.com')), false);
  assert.equal(await verify(await sign('https://api.example', 'someone@p.iam.gserviceaccount.com')), false);
  assert.equal(await verify('not-a-jwt'), false);
});

test('/jobs/email: 401 without a valid token, runs the job with one; absent when not configured', async () => {
  let runs = 0;
  const app = buildApp({
    verify: async () => null, withUser: async () => { throw new Error('unused'); },
    jobs: { verify: async (t) => t === 'good', email: async () => { runs++; return { sent: 1, failed: 0, failures: [] }; } },
  });
  assert.equal((await app.inject({ method: 'POST', url: '/jobs/email' })).statusCode, 401);
  assert.equal((await app.inject({ method: 'POST', url: '/jobs/email', headers: { authorization: 'Bearer bad' } })).statusCode, 401);
  const r = await app.inject({ method: 'POST', url: '/jobs/email', headers: { authorization: 'Bearer good' } });
  assert.equal(r.statusCode, 200);
  assert.deepEqual(r.json(), { sent: 1, failed: 0 });
  assert.equal(runs, 1);
  const off = buildApp({ verify: async () => null, withUser: async () => { throw new Error('unused'); } });
  assert.equal((await off.inject({ method: 'POST', url: '/jobs/email' })).statusCode, 404);
});

// Against the local database, as assetly_jobs. Fixtures by postgres; removed afterwards.
const admin = new pg.Client({ connectionString: ADMIN_DATABASE_URL });
const jobs = createJobsDb(JOBS_DATABASE_URL);
const status = async () => (await admin.query(
  `select status, attempts, provider_id, last_error from private.notification_email where user_id = $1`, [ADMIN_A])).rows[0];

before(async () => {
  await admin.connect();
  await admin.query(`insert into public.asset_category (id, tenant_id, name) values ($1, $2, 'S91 job pumps')`, [ASSET, TENANT_A]);
  await admin.query(`insert into public.asset (id, tenant_id, name, category_id) values ($1, $2, 'S91 job pump', $1)`, [ASSET, TENANT_A]);
  await admin.query(`insert into public.notification (tenant_id, user_id, event_id, event_type, domain, asset_id, payload, emailed_on)
    values ($1, $2, gen_random_uuid(), 'obligation.overdue', 'obligation', $3, '{"name": "Service", "asset_name": "S91 job pump", "next_due_date": "2026-11-01"}', '2026-11-05')`,
  [TENANT_A, ADMIN_A, ASSET]);
  await admin.query(`insert into private.notification_email (tenant_id, user_id, digest_date) values ($1, $2, '2026-11-05')`, [TENANT_A, ADMIN_A]);
});
after(async () => {
  await admin.query(`delete from private.notification_email where user_id = $1`, [ADMIN_A]);
  await admin.query(`delete from public.notification where asset_id = $1`, [ASSET]);
  await admin.query(`delete from public.asset where id = $1`, [ASSET]);
  await admin.query(`delete from public.asset_category where id = $1`, [ASSET]);
  await admin.end();
  await jobs.pool.end();
});

test('email job: a failed send is recorded for retry, then a good send is recorded once', async () => {
  const fail = await runEmailJob(jobs.query, async () => { throw new Error('provider down'); }, 'https://app.example');
  assert.equal(fail.failed, 1);
  assert.deepEqual(await status(), { status: 'pending', attempts: 1, provider_id: null, last_error: 'provider down' });

  const nothing = await runEmailJob(jobs.query, async () => 'never', 'https://app.example');
  assert.equal(nothing.sent, 0, 'backoff: not retried at once');

  await admin.query(`update private.notification_email set next_try_at = now() - interval '1 second' where user_id = $1`, [ADMIN_A]);
  const mails: Mail[] = [];
  const ok = await runEmailJob(jobs.query, async (m) => { mails.push(m); return 'prov-1'; }, 'https://app.example');
  assert.equal(ok.sent, 1);
  assert.equal(mails[0]!.to, 'admin.a@example.com');
  assert.match(mails[0]!.text, /Overdue: Service on S91 job pump, due 01-11-2026/);
  assert.equal(mails[0]!.idempotencyKey.length, 36, 'the row id is the idempotency key');
  assert.deepEqual(await status(), { status: 'sent', attempts: 1, provider_id: 'prov-1', last_error: null });
});

test('assetly_jobs reads no tables', async () => {
  await assert.rejects(jobs.query('select 1 from public.asset limit 1'), /permission denied/);
  await assert.rejects(jobs.query('select 1 from private.notification_email limit 1'), /permission denied/);
});
