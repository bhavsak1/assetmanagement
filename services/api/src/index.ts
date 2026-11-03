import { buildApp } from './app.ts';
import { createVerifier } from './auth.ts';
import { createDb } from './db.ts';

function env(name: string): string {
  const value = process.env[name];
  if (!value) throw new Error(`${name} is not set`);
  return value;
}

const db = createDb(env('DATABASE_URL'));
const app = buildApp({
  verify: createVerifier(env('SUPABASE_URL')),
  withUser: db.withUser,
  corsOrigins: (process.env.CORS_ORIGINS ?? '').split(',').map((s) => s.trim()).filter(Boolean),
  // JSON lines on stdout; Cloud Logging reads `severity`. Pino logs no headers, so no token in logs.
  logger: { messageKey: 'message', formatters: { level: (label) => ({ severity: label.toUpperCase() }) } },
});

// Cloud Run sends SIGTERM before it stops an instance.
process.on('SIGTERM', async () => {
  await app.close();
  await db.pool.end();
});

await app.listen({ host: '0.0.0.0', port: Number(process.env.PORT ?? 8080) });
