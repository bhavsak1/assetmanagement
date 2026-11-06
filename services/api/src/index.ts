import { createGateway, providersFromEnv } from './ai.ts';
import { buildApp } from './app.ts';
import { createVerifier } from './auth.ts';
import { createDb, createJobsDb } from './db.ts';
import { createJobsVerifier, createResend, runEmailJob } from './email.ts';

function env(name: string): string {
  const value = process.env[name];
  if (!value) throw new Error(`${name} is not set`);
  return value;
}

const db = createDb(env('DATABASE_URL'));
// Story 9.1: the email job is on only when JOBS_AUDIENCE (this service's URL) is set.
const jobsDb = process.env.JOBS_AUDIENCE ? createJobsDb(env('JOBS_DATABASE_URL')) : undefined;
let jobs;
if (jobsDb) {
  const send = createResend(env('EMAIL_API_KEY'), env('EMAIL_FROM'));
  const appUrl = env('APP_URL');
  jobs = { verify: createJobsVerifier(env('JOBS_AUDIENCE'), env('JOBS_INVOKER')), email: () => runEmailJob(jobsDb.query, send, appUrl) };
}
// Story 10.1: AI is off unless AI_ENABLED=true (the kill switch) and a provider is configured.
const callModel = createGateway({ withUser: db.withUser, providers: providersFromEnv(), enabled: process.env.AI_ENABLED === 'true' });
const app = buildApp({
  verify: createVerifier(env('SUPABASE_URL')),
  withUser: db.withUser,
  withKey: db.withKey,
  jobs,
  callModel,
  corsOrigins: (process.env.CORS_ORIGINS ?? '').split(',').map((s) => s.trim()).filter(Boolean),
  // JSON lines on stdout; Cloud Logging reads `severity`. Pino logs no headers, so no token in logs.
  logger: { messageKey: 'message', formatters: { level: (label) => ({ severity: label.toUpperCase() }) } },
});

// Cloud Run sends SIGTERM before it stops an instance.
process.on('SIGTERM', async () => {
  await app.close();
  await db.pool.end();
  await jobsDb?.pool.end();
});

await app.listen({ host: '0.0.0.0', port: Number(process.env.PORT ?? 8080) });
