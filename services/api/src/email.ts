// Story 9.1: the daily email summary job (docs/data-model-goal9.md §3, §6, §10). Runs as role assetly_jobs,
// which can only call private.claim_emails and private.finish_email. Plain text only: tenant data (asset
// names) is untrusted, so nothing is rendered as HTML.
import { createRemoteJWKSet, errors, jwtVerify, type JWTVerifyGetKey } from 'jose';
import type { Query } from './db.ts';

export type Line = { event_type: string; asset_id: string; payload: Record<string, unknown> };
export type Claimed = { id: string; email: string; display_name: string; tenant_name: string; date_format: string; lines: Line[] };
export type Mail = { to: string; subject: string; text: string; idempotencyKey: string };
export type Send = (mail: Mail) => Promise<string>;

// English only for now (CLAUDE.md §3); the web app's strings are in apps/web/src/i18n/en.json.
const EN = {
  subject: (n: number, tenant: string) => `Assetly: ${n} new ${n === 1 ? 'alert' : 'alerts'} for ${tenant}`,
  hello: (name: string) => `Hello ${name},`,
  intro: (n: number, tenant: string) => `${tenant} has ${n} new ${n === 1 ? 'alert' : 'alerts'}:`,
  'obligation.overdue': (p: P) => `Overdue: ${p.name} on ${p.asset}, due ${p.date}`,
  'obligation.due_soon': (p: P) => `Due soon: ${p.name} on ${p.asset}, due ${p.date}`,
  'coverage.expiring': (p: P) => `Coverage expiring: ${p.asset}, ends ${p.date}`,
  'coverage.expired': (p: P) => `Coverage expired: ${p.asset}, ended ${p.date}`,
  open: (url: string) => `Open your alerts: ${url}/notifications`,
  stop: 'To stop these emails, turn off "Email me a daily summary" on that page.',
};
type P = { name: string; asset: string; date: string };

// One line of untrusted text: no control characters (no fake lines), bounded length.
// eslint-disable-next-line no-control-regex -- stripping control characters is the point
const clean = (v: unknown) => String(v ?? '').replace(/[\u0000-\u001F\u007F]/g, ' ').trim().slice(0, 120);

// Tenant date format tokens used by Settings (dd, MM, yyyy) on an ISO date.
export function formatDate(iso: unknown, format: string) {
  const m = /^(\d{4})-(\d{2})-(\d{2})$/.exec(String(iso ?? ''));
  return m ? format.replace('yyyy', m[1]!).replace('MM', m[2]!).replace('dd', m[3]!) : '';
}

export function render(c: Claimed, appUrl: string): Omit<Mail, 'idempotencyKey'> {
  const tenant = clean(c.tenant_name);
  const lines = c.lines.map((l) => {
    const p = l.payload;
    const tag = clean(p.asset_tag);
    const asset = clean(p.asset_name) + (tag ? ` (${tag})` : '');
    const date = formatDate(p.next_due_date ?? p.end_date, c.date_format);
    const line = EN[l.event_type as keyof typeof EN];
    return typeof line === 'function' ? `- ${(line as (p: P) => string)({ name: clean(p.name), asset, date })}` : null;
  }).filter((l) => l !== null);
  return {
    to: c.email,
    subject: EN.subject(lines.length, tenant),
    text: [EN.hello(clean(c.display_name)), '', EN.intro(lines.length, tenant), '', ...lines, '', EN.open(appUrl), EN.stop, ''].join('\n'),
  };
}

// Claim, send, finish. A failure is recorded on the row (retry with backoff, failed after 5) and logged by
// the caller; one bad address never stops the batch. The row id is the idempotency key (N2).
export async function runEmailJob(query: Query, send: Send, appUrl: string, limit = 50) {
  const claimed = (await query<Claimed>('select * from private.claim_emails($1)', [limit])).rows;
  const failures: string[] = [];
  let sent = 0;
  for (const c of claimed) {
    try {
      const providerId = await send({ ...render(c, appUrl), idempotencyKey: c.id });
      await query('select private.finish_email($1, $2, null)', [c.id, providerId]);
      sent++;
    } catch (e) {
      const message = e instanceof Error ? e.message : String(e);
      failures.push(`${c.id}: ${message}`);
      await query('select private.finish_email($1, null, $2)', [c.id, message]);
    }
  }
  return { sent, failed: failures.length, failures };
}

// Resend's HTTP API (owner choice N5, 4 Nov 2026). Swapping provider is this function only.
export function createResend(apiKey: string, from: string): Send {
  return async (mail) => {
    const r = await fetch('https://api.resend.com/emails', {
      method: 'POST',
      headers: { authorization: `Bearer ${apiKey}`, 'content-type': 'application/json', 'idempotency-key': mail.idempotencyKey },
      body: JSON.stringify({ from, to: [mail.to], subject: mail.subject, text: mail.text }),
      signal: AbortSignal.timeout(15_000),
    });
    const body = await r.text();
    if (!r.ok) throw new Error(`resend ${r.status} ${body.slice(0, 200)}`);
    return String((JSON.parse(body) as { id?: unknown }).id ?? '');
  };
}

// Cloud Scheduler's Google OIDC token (N10 a): signed by Google, for this service's URL, from the scheduler's
// service account. No shared secret.
export type JobsVerify = (token: string) => Promise<boolean>;
const GOOGLE_JWKS = createRemoteJWKSet(new URL('https://www.googleapis.com/oauth2/v3/certs'));

export function createJobsVerifier(audience: string, invoker: string, jwks: JWTVerifyGetKey = GOOGLE_JWKS): JobsVerify {
  return async (token) => {
    try {
      const { payload } = await jwtVerify(token, jwks, { issuer: ['https://accounts.google.com', 'accounts.google.com'], audience });
      return payload.email === invoker && payload.email_verified === true;
    } catch (e) {
      if (e instanceof errors.JOSEError && e.code !== 'ERR_JWKS_TIMEOUT') return false;
      throw e;
    }
  };
}
