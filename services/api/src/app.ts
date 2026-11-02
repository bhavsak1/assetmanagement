import Fastify, { type FastifyServerOptions } from 'fastify';
import type { Verify } from './auth.ts';
import type { createDb } from './db.ts';

type Deps = { verify: Verify; withUser: ReturnType<typeof createDb>['withUser']; logger?: FastifyServerOptions['logger'] };

export function buildApp({ verify, withUser, logger = false }: Deps) {
  const app = Fastify({ logger });

  // No database call: health checks never wake Postgres or hold a connection.
  app.get('/health', async () => ({ ok: true }));

  // Who am I and which tenant, read inside Postgres under RLS (data-model-goal8.md §6).
  app.get('/me', async (req, reply) => {
    const token = /^Bearer (\S+)$/.exec(req.headers.authorization ?? '')?.[1];
    const claims = token ? await verify(token) : null;
    if (!claims) return reply.code(401).send({ error: 'unauthorized' });

    const me = await withUser(claims, async (q) => (await q<{ user_id: string; tenant_id: string | null; tenant_name: string | null }>(
      `select auth.uid() as user_id, private.current_tenant_id() as tenant_id,
              (select t.name from public.tenant t where t.id = private.current_tenant_id()) as tenant_name`,
    )).rows[0]!);
    req.log.info({ user_id: me.user_id, tenant_id: me.tenant_id }, 'me');
    // no tenant in the token, or RLS hides it (not an active member)
    if (!me.tenant_name) return reply.code(403).send({ error: 'forbidden' });
    return me;
  });

  return app;
}
