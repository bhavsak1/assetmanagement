import cors from '@fastify/cors';
import swagger from '@fastify/swagger';
import Fastify, { type FastifyReply, type FastifyRequest, type FastifyServerOptions } from 'fastify';
import { AiError, type CallModel } from './ai.ts';
import type { Verify } from './auth.ts';
import type { createDb } from './db.ts';
import type { JobsVerify } from './email.ts';
import { HEADER_SCAN, stageXlsx } from './imports.ts';
import { allowed, loadCatalog, loadRights, publicCatalog, QueryError, run } from './insights.ts';
import { aiMapper, loadChain, matchTemplate, rulesMapper, suggestMapping, templateLists, templateXlsx, type Target } from './mapping.ts';
import { mcp, type RouteSchemas } from './mcp.ts';
import { askModel, candidates, key, openValues, type Stored, type Value } from './values.ts';
import { v1 } from './v1.ts';
import { ImportError, type Cell } from './xlsx.ts';

type Deps = {
  verify: Verify;
  withUser: ReturnType<typeof createDb>['withUser'];
  // 9.2: /v1 is on only when given (tests of other routes leave it out).
  withKey?: ReturnType<typeof createDb>['withKey'];
  logger?: FastifyServerOptions['logger'];
  corsOrigins?: string[];
  maxParses?: number;
  // 9.1: off (no route) unless configured.
  jobs?: { verify: JobsVerify; email: () => Promise<{ sent: number; failed: number; failures: string[] }> };
  // 10.1: the AI gateway. Without it every AI route answers ai_off.
  callModel?: CallModel;
};

// 10.1: gateway refusal codes to HTTP. The body carries the code for the web app's i18n text.
const AI_STATUS = { ai_off: 503, ai_not_licensed: 403, ai_no_right: 403, ai_cap_reached: 429, ai_rate_limited: 429, ai_failed: 502 } as const;

const XLSX = 'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet';
const MAX_FILE = 10 * 2 ** 20; // I2
const ACTION_TIMEOUT = '280s';
const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;

export function buildApp({ verify, withUser, withKey, logger = false, corsOrigins = [], maxParses = 3, jobs, callModel }: Deps) {
  // 9.2: refuse unknown fields (Fastify's default strips them, so a PATCH of status would silently do nothing).
  const app = Fastify({ logger, ajv: { customOptions: { removeAdditional: false } } });

  // I12, I13: only the listed web origins; the token goes in a header, never a cookie.
  // 9.2 A14: /v1 is server to server, so it sends no CORS headers and a browser page cannot call it. 9.5 M3: /mcp too.
  app.register(cors, {
    delegator: async (req: FastifyRequest) => /^\/(v1|mcp)(\/|$|\?)/.test(req.url) ? { origin: false } : {
      origin: corsOrigins,
      methods: ['GET', 'POST'],
      allowedHeaders: ['Authorization', 'Content-Type', 'X-File-Name'],
    },
  });
  // 9.2 A11: the OpenAPI document is built from the /v1 route schemas (tagged routes only), at /v1/openapi.json.
  app.register(swagger, {
    hideUntagged: true,
    openapi: {
      info: { title: 'Assetly API', version: '1', description: 'See docs/api-v1.md. Errors are application/problem+json.' },
      components: { securitySchemes: { apiKey: { type: 'http', scheme: 'bearer', description: 'An API key: asly_...' } } },
    },
  });
  if (withKey) {
    // 9.5 M4: MCP tools take their schemas from the /v1 routes, so both stay one source of truth.
    const schemas: RouteSchemas = new Map();
    app.addHook('onRoute', (r) => { if (typeof r.method === 'string' && r.url.startsWith('/v1/')) schemas.set(`${r.method} ${r.url}`, r.schema ?? {}); });
    app.register(v1(withKey), { prefix: '/v1' });
    app.register(mcp(withKey, schemas, corsOrigins), { prefix: '/mcp' });
  }
  // The request body is the file itself; no multipart.
  app.addContentTypeParser(XLSX, { parseAs: 'buffer', bodyLimit: MAX_FILE }, (_req, body, done) => done(null, body));

  async function claimsOf(req: FastifyRequest, reply: FastifyReply) {
    const token = /^Bearer (\S+)$/.exec(req.headers.authorization ?? '')?.[1];
    const claims = token ? await verify(token) : null;
    if (!claims) reply.code(401).send({ error: 'unauthorized' });
    return claims;
  }

  // No database call: health checks never wake Postgres or hold a connection.
  app.get('/health', async () => ({ ok: true }));

  // Who am I and which tenant, read inside Postgres under RLS (data-model-goal8.md §6).
  app.get('/me', async (req, reply) => {
    const claims = await claimsOf(req, reply);
    if (!claims) return reply;

    const me = await withUser(claims, async (q) => (await q<{ user_id: string; tenant_id: string | null; tenant_name: string | null }>(
      `select auth.uid() as user_id, private.current_tenant_id() as tenant_id,
              (select t.name from public.tenant t where t.id = private.current_tenant_id()) as tenant_name`,
    )).rows[0]!);
    req.log.info({ user_id: me.user_id, tenant_id: me.tenant_id }, 'me');
    // no tenant in the token, or RLS hides it (not an active member)
    if (!me.tenant_name) return reply.code(403).send({ error: 'forbidden' });
    return me;
  });

  // Upload one .xlsx and stage its rows (data-model-goal8.md §13). RLS refuses users without excel_import.run.
  let parsing = 0;
  app.post<{ Querystring: { sheet?: string; header_row?: string }; Body: Buffer }>('/imports', { bodyLimit: MAX_FILE }, async (req, reply) => {
    const claims = await claimsOf(req, reply);
    if (!claims) return reply;
    if (!Buffer.isBuffer(req.body)) return reply.code(415).send({ error: 'not_xlsx' });
    // The name is display text only: no path, no control characters.
    let name = '';
    try { name = decodeURIComponent(String(req.headers['x-file-name'] ?? '')); } catch { /* keep empty */ }
    // eslint-disable-next-line no-control-regex -- stripping control characters is the point
    name = name.replace(/^.*[\\/]/, '').replace(/[\u0000-\u001F\u007F]/g, '').slice(0, 255).trim();
    if (!/\.xlsx$/i.test(name)) return reply.code(415).send({ error: 'not_xlsx' });
    const headerRow = req.query.header_row === undefined ? undefined : Number(req.query.header_row);
    if (headerRow !== undefined && !(Number.isInteger(headerRow) && headerRow >= 1 && headerRow <= HEADER_SCAN)) {
      return reply.code(400).send({ error: 'bad_header_row' });
    }
    // Bounds memory on a small instance: each parse holds its file and shared strings.
    if (parsing >= maxParses) return reply.code(429).send({ error: 'busy' });

    parsing++;
    try {
      const result = await withUser(claims, (q) => stageXlsx(q, req.body, name, req.query.sheet, headerRow));
      req.log.info({ user_id: claims.sub, tenant_id: claims.tenant_id, batch_id: result.batch_id, rows: result.row_count }, 'import staged');
      return reply.code(201).send(result);
    } catch (e) {
      if (e instanceof ImportError) return reply.code(e.status).send({ error: e.code });
      if ((e as { code?: string }).code === '42501') return reply.code(403).send({ error: 'forbidden' }); // RLS
      throw e;
    } finally {
      parsing--;
    }
  });

  // The blank import file: one header per field this user may set (§14.8). It maps itself on upload.
  app.get('/imports/template', async (req, reply) => {
    const claims = await claimsOf(req, reply);
    if (!claims) return reply;
    const { catalog, lists, dateFormat } = await withUser(claims, async (q) => ({
      catalog: (await q<Target>('select target, label, kind, required, category_id from public.import_target_catalog()')).rows,
      ...await templateLists(q), // §16: drop-down values as this user may see them
    }));
    if (!catalog.length) return reply.code(403).send({ error: 'forbidden' }); // no excel_import
    return reply
      .header('content-type', XLSX)
      .header('content-disposition', 'attachment; filename="assetly-import-template.xlsx"')
      .send(templateXlsx(catalog, lists, dateFormat));
  });

  // Commit and undo (§18). Here, not as web rpc calls: every row goes through the asset triggers one by one,
  // far past the 8 s statement timeout of the web role (K1). The SQL functions do every check.
  for (const action of ['commit', 'undo'] as const) {
    app.post<{ Params: { id: string } }>(`/imports/:id/${action}`, async (req, reply) => {
      const claims = await claimsOf(req, reply);
      if (!claims) return reply;
      if (!UUID.test(req.params.id)) return reply.code(404).send({ error: 'not_found' });
      try {
        const outcome = await withUser(claims, async (q) => {
          await q(`set local statement_timeout = '${ACTION_TIMEOUT}'`); // inside Cloud Run's 300 s request timeout
          return (await q<{ r: unknown }>(`select public.import_${action}($1) as r`, [req.params.id])).rows[0]!.r;
        });
        req.log.info({ user_id: claims.sub, tenant_id: claims.tenant_id, batch_id: req.params.id, outcome }, `import ${action}`);
        return outcome;
      } catch (e) {
        const code = (e as { code?: string }).code ?? '';
        if (code === '42501') return reply.code(403).send({ error: 'forbidden' });
        if (code === 'P0002') return reply.code(404).send({ error: 'not_found' });
        // The batch moved on, or a trigger refused a row (something changed since the check).
        if (code === '22023' || code === 'P0001' || code.startsWith('23')) return reply.code(409).send({ error: 'changed' });
        if (code === '54000') return reply.code(413).send({ error: 'too_many_rows' }); // K8
        if (code === '57014') return reply.code(504).send({ error: 'timeout' });
        throw e;
      }
    });
  }

  // Story 10.3: AI column mapping for a staged batch (data-model-goal10.md §4.1). The chain runs again with the
  // AI mapper last; nothing is stored. The user confirms through import_save_mapping, as for rules (M4). A saved
  // template, or no column left without a target, means no model call. Reads in one short transaction; the model
  // call runs outside it (the gateway's own rule, §2.2).
  app.post<{ Params: { id: string } }>('/imports/:id/ai-mapping', async (req, reply) => {
    const claims = await claimsOf(req, reply);
    if (!claims) return reply;
    if (!UUID.test(req.params.id)) return reply.code(404).send({ error: 'not_found' });
    const read = await withUser(claims, async (q) => {
      const batch = (await q<{ columns: string[]; status: string; mapping_template_id: string | null }>(
        'select columns, status, mapping_template_id from public.import_batch where id = $1', [req.params.id])).rows[0];
      if (!batch) return undefined;
      const samples = (await q<{ cells: Cell[] }>(
        'select cells from public.import_row where batch_id = $1 order by row_number limit 20', [req.params.id])).rows.map((r) => r.cells);
      return { batch, samples, ...await loadChain(q) };
    });
    if (!read || !read.catalog.length) return reply.code(404).send({ error: 'not_found' }); // RLS: not theirs, or no excel_import
    const { batch, samples, catalog, templates } = read;
    if (batch.status !== 'staged') return reply.code(409).send({ error: 'changed' });
    if (batch.mapping_template_id || matchTemplate(batch.columns, templates)) return { mapping: null };
    if (!callModel) return reply.code(503).send({ error: 'ai_off' });
    try {
      const mapping = await suggestMapping({ columns: batch.columns, samples, catalog },
        [rulesMapper, aiMapper(callModel, claims, req.params.id)]);
      req.log.info({ user_id: claims.sub, tenant_id: claims.tenant_id, batch_id: req.params.id,
        ai: mapping.filter((m) => m.source === 'ai').length }, 'import ai mapping');
      return { mapping };
    } catch (e) {
      if (e instanceof AiError) return reply.code(AI_STATUS[e.code]).send({ error: e.code });
      throw e;
    }
  });

  // Story 10.4 (data-model-goal10.md §4.2): AI matches for values 8.4 could not find, on a validated batch. Values
  // already suggested or decided are not sent again. Returns every stored suggestion with its candidates (the
  // screen's Edit list). Like 10.3 it runs outside any transaction that holds the model call.
  app.post<{ Params: { id: string } }>('/imports/:id/ai-values', async (req, reply) => {
    const claims = await claimsOf(req, reply);
    if (!claims) return reply;
    if (!UUID.test(req.params.id)) return reply.code(404).send({ error: 'not_found' });
    const id = req.params.id;
    // 'gone': not theirs, or no excel_import (RLS). 'changed': not validated now.
    const read = async () => withUser(claims, async (q) => {
      const batch = (await q<{ status: string; mapping: { target: string }[] | null; value_suggestions: Stored[] | null }>(
        'select status, mapping, value_suggestions from public.import_batch where id = $1', [id])).rows[0];
      if (!batch) return 'gone' as const;
      if (batch.status !== 'validated' || !batch.mapping) return 'changed' as const;
      const stored = batch.value_suggestions ?? [];
      const seen = new Set(stored.map(key));
      const open = (await openValues(q, id, batch.mapping)).filter((v) => !seen.has(key(v)));
      const found = await candidates(q, [...stored, ...open]);
      return { stored, found, ask: open.map((v) => ({ ...v, candidates: found.get(key(v)) ?? [] })).filter((v) => v.candidates.length) };
    });
    let r = await read();
    if (r === 'gone') return reply.code(404).send({ error: 'not_found' });
    if (r === 'changed') return reply.code(409).send({ error: 'changed' });
    if (r.ask.length) {
      if (!callModel) return reply.code(503).send({ error: 'ai_off' });
      try {
        const got = await askModel(callModel, claims, id, r.ask);
        req.log.info({ user_id: claims.sub, tenant_id: claims.tenant_id, batch_id: id, asked: r.ask.length, ai: got.length }, 'import ai values');
        if (got.length) {
          await withUser(claims, (q) => q('select public.import_decide_values($1, $2)', [id, JSON.stringify(got)]));
          r = await read();
          if (typeof r === 'string') return reply.code(409).send({ error: 'changed' });
        }
      } catch (e) {
        if (e instanceof AiError) return reply.code(AI_STATUS[e.code]).send({ error: e.code });
        throw e;
      }
    }
    const { stored, found } = r;
    return { values: stored.map((s): Value => ({ ...s, candidates: found.get(key(s)) ?? [] })) };
  });

  // Story 10.1: one tiny model call that proves the gateway end to end (key, entitlement, cap, ai_call row with
  // cost). For ai_usage.view holders only; it is not a feature. Costs well under a tenth of a US cent.
  app.post('/ai/check', async (req, reply) => {
    const claims = await claimsOf(req, reply);
    if (!claims) return reply;
    if (!callModel) return reply.code(503).send({ error: 'ai_off' });
    try {
      const { output, ai_call_id } = await callModel<{ ok: boolean }>({
        claims, feature: 'check', maxTokens: 200,
        system: 'You are a health check. Answer with the JSON object {"ok": true}.',
        input: 'Health check.',
        schema: { type: 'object', properties: { ok: { type: 'boolean' } }, required: ['ok'], additionalProperties: false },
      });
      req.log.info({ user_id: claims.sub, tenant_id: claims.tenant_id, ai_call_id }, 'ai check');
      return { ok: output.ok, ai_call_id };
    } catch (e) {
      if (e instanceof AiError) return reply.code(AI_STATUS[e.code]).send({ error: e.code });
      throw e;
    }
  });

  // Story 10.6 (data-model-goal10.md §5): the user's own catalog, and a structured query run under their rights.
  // No model call and no AI metering: 10.7 chip edits and 10.8 widgets re-run here. Q9: insights_query.ask and
  // a live ai_addon, else 403. A refused query is 422 before any SQL exists.
  app.get('/insights/catalog', async (req, reply) => {
    const claims = await claimsOf(req, reply);
    if (!claims) return reply;
    const out = await withUser(claims, async (q) => {
      const rights = await loadRights(q);
      return await allowed(q, rights) ? publicCatalog(await loadCatalog(q, rights)) : null;
    });
    if (!out) return reply.code(403).send({ error: 'forbidden' });
    return { subjects: out };
  });

  app.post<{ Body: unknown }>('/insights/run', async (req, reply) => {
    const claims = await claimsOf(req, reply);
    if (!claims) return reply;
    try {
      const out = await withUser(claims, async (q) => {
        const rights = await loadRights(q);
        return await allowed(q, rights) ? run(q, req.body, await loadCatalog(q, rights)) : null;
      });
      if (!out) return reply.code(403).send({ error: 'forbidden' });
      req.log.info({ user_id: claims.sub, tenant_id: claims.tenant_id, rows: 'rows' in out ? out.rows.length : null }, 'insights run');
      return out;
    } catch (e) {
      if (e instanceof QueryError) return reply.code(422).send({ error: e.code, at: e.at });
      if ((e as { code?: string }).code === '57014') return reply.code(504).send({ error: 'timeout' });
      throw e;
    }
  });

  // Story 9.1: the daily email summary, called by Cloud Scheduler with a Google OIDC token. Outside /v1.
  if (jobs) {
    app.post('/jobs/email', async (req, reply) => {
      const token = /^Bearer (\S+)$/.exec(req.headers.authorization ?? '')?.[1];
      if (!token || !(await jobs.verify(token))) return reply.code(401).send({ error: 'unauthorized' });
      const { sent, failed, failures } = await jobs.email();
      for (const f of failures) req.log.error({ job: 'email' }, `email failed ${f}`);
      req.log.info({ job: 'email', sent, failed }, 'email job');
      return { sent, failed };
    });
  }

  return app;
}
