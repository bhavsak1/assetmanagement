// Story 9.5b: an MCP server over /v1 (docs/data-model-goal9.md §19, customer docs in docs/mcp.md).
// Each tool is a /v1 route. A call runs that route in-process (app.inject) with the caller's own key, so schemas,
// validation, RLS, masking, the rate limit, audit and errors exist once, in /v1. Stateless: one MCP server and
// transport per HTTP request, no session id, JSON answers (M2).
import { Server } from '@modelcontextprotocol/sdk/server/index.js';
import { WebStandardStreamableHTTPServerTransport } from '@modelcontextprotocol/sdk/server/webStandardStreamableHttp.js';
import { CallToolRequestSchema, ErrorCode, ListToolsRequestSchema, McpError, type CallToolResult, type Tool } from '@modelcontextprotocol/sdk/types.js';
import type { FastifyInstance, FastifyReply, FastifyRequest, FastifySchema } from 'fastify';
import { KeyError, type createDb } from './db.ts';
import { ASSET, RATE_LIMIT, problem } from './v1.ts';

type WithKey = ReturnType<typeof createDb>['withKey'];
export type RouteSchemas = Map<string, FastifySchema>; // 'GET /v1/assets' -> its schema, filled by an onRoute hook
type Schema = { properties?: Record<string, unknown>; required?: string[] };
type Inject = { statusCode: number; body: string; headers: Record<string, unknown> };

// M4: tool name -> /v1 route. `:id` comes from the arguments; the rest go to the query (GET) or the body.
const READ = { readOnlyHint: true, openWorldHint: false };
const WRITE = { readOnlyHint: false, destructiveHint: false, openWorldHint: false };
const TOOLS: Record<string, { route: string; annotations: Tool['annotations']; hint?: string }> = {
  whoami: { route: 'GET /v1/me', annotations: READ },
  list_assets: { route: 'GET /v1/assets', annotations: READ, hint: 'Use filters. If next_cursor is not null, pass it as cursor for the next page.' },
  get_asset: { route: 'GET /v1/assets/:id', annotations: READ, hint: 'Error code gone means the asset was deleted; not_found means it does not exist or is not visible.' },
  create_asset: { route: 'POST /v1/assets', annotations: WRITE, hint: 'Pass your own id (a new UUID) so a retry cannot create a second asset (409 conflict).' },
  update_asset: { route: 'PATCH /v1/assets/:id', annotations: { ...WRITE, idempotentHint: true }, hint: 'Give id and only the fields to change.' },
  list_categories: { route: 'GET /v1/categories', annotations: READ },
  list_locations: { route: 'GET /v1/locations', annotations: READ },
  list_asset_statuses: { route: 'GET /v1/asset-statuses', annotations: READ },
};

// The route's Asset $ref inlined, so the output schema stands alone.
const ASSET_INLINE = { ...ASSET, $id: undefined };
const inline = (s: unknown) => JSON.parse(JSON.stringify(s).replaceAll('{"$ref":"Asset#"}', JSON.stringify(ASSET_INLINE))) as Tool['outputSchema'];

function toolsFrom(schemas: RouteSchemas): Tool[] {
  return Object.entries(TOOLS).map(([name, t]) => {
    const s = schemas.get(t.route);
    if (!s) throw new Error(`mcp: no /v1 route ${t.route}`);
    const parts = [s.querystring, s.params, s.body] as (Schema | undefined)[];
    const ok = (s.response as Record<string, unknown> | undefined)?.[t.route.startsWith('POST') ? 201 : 200];
    return {
      name,
      description: [s.summary, s.description, t.hint].filter(Boolean).join('. '),
      inputSchema: {
        type: 'object', additionalProperties: false,
        properties: Object.assign({}, ...parts.map((p) => p?.properties)),
        required: parts.flatMap((p) => p?.required ?? []),
      },
      ...(ok ? { outputSchema: inline(ok) } : {}),
      annotations: t.annotations,
    };
  });
}

export function mcp(withKey: WithKey, schemas: RouteSchemas, allowedOrigins: string[]) {
  return async function routes(app: FastifyInstance) {
    let tools: Tool[] | undefined; // built on first use: every /v1 route is registered by then

    const keyOf = (req: FastifyRequest) => /^Bearer (asly_\S+)$/.exec(req.headers.authorization ?? '')?.[1] ?? '';
    const unauthorized = (reply: FastifyReply) =>
      problem(reply.header('www-authenticate', 'Bearer'), 401, 'unauthorized', 'Missing, unknown, expired or revoked API key');

    // Runs one tool's /v1 route with the caller's Authorization header.
    function run(name: string, args: Record<string, unknown>, req: FastifyRequest) {
      const [method, path] = TOOLS[name]!.route.split(' ') as ['GET' | 'POST' | 'PATCH', string];
      const { id, ...rest } = args;
      const url = path.includes(':id') ? path.replace(':id', encodeURIComponent(String(id ?? ''))) : path;
      const fields = path.includes(':id') ? rest : args;
      return app.inject({
        method, url, headers: { authorization: req.headers.authorization ?? '' },
        ...(method === 'GET'
          ? { query: Object.fromEntries(Object.entries(fields).map(([k, v]) => [k, String(v)])) }
          : { payload: fields }),
      }) as Promise<Inject>;
    }

    function toResult(r: Inject): CallToolResult {
      if (r.statusCode < 300) {
        const json = JSON.parse(r.body) as Record<string, unknown>;
        return { structuredContent: json, content: [{ type: 'text', text: r.body }] };
      }
      // M8: a /v1 problem is a tool error the model can read and act on.
      const p = r.statusCode >= 500 ? { status: r.statusCode, code: 'internal' } : JSON.parse(r.body) as Record<string, unknown>;
      if (r.statusCode === 429) p.retry_after = Number(r.headers['retry-after']);
      return { isError: true, content: [{ type: 'text', text: JSON.stringify(p) }] };
    }

    app.post('/', async (req, reply) => {
      // MCP spec: refuse foreign origins (DNS rebinding). Server-to-server clients send no Origin.
      const origin = req.headers.origin;
      if (origin && !allowedOrigins.includes(origin)) return problem(reply, 403, 'forbidden', 'Origin not allowed');

      // M7, M8: one count per request. tools/call counts through its /v1 call; anything else checks the key here.
      // A bad key is HTTP 401 before any JSON-RPC work.
      const msg = req.body as { method?: unknown; params?: { name?: unknown; arguments?: unknown } } | null;
      const name = msg?.method === 'tools/call' && typeof msg.params?.name === 'string' && Object.hasOwn(TOOLS, msg.params.name) ? msg.params.name : undefined;
      const args = msg?.params?.arguments;
      let call: Inject | undefined;
      if (name && (args === undefined || (typeof args === 'object' && args !== null && !Array.isArray(args)))) {
        call = await run(name, (args ?? {}) as Record<string, unknown>, req);
        if (call.statusCode === 401) return unauthorized(reply);
        req.log.info({ tool: name, status: call.statusCode }, 'mcp tool'); // tenant and key id: the /v1 'api key' line
      } else {
        try {
          await withKey(keyOf(req), RATE_LIMIT, async () => undefined);
        } catch (e) {
          if (!(e instanceof KeyError)) throw e;
          if (e.code === 'rate_limited') return problem(reply.header('retry-after', String(60 - new Date().getUTCSeconds())), 429, 'rate_limited', `At most ${RATE_LIMIT} calls a minute per key`);
          return unauthorized(reply);
        }
      }

      tools ??= toolsFrom(schemas);
      const server = new Server({ name: 'assetly', version: '1' }, {
        capabilities: { tools: {} },
        instructions: 'Assetly asset register. Every call runs with the rights of the API key\'s integration user. Look up ids with list_categories, list_locations and list_asset_statuses before creating assets.',
      });
      server.setRequestHandler(ListToolsRequestSchema, () => ({ tools: tools! }));
      server.setRequestHandler(CallToolRequestSchema, (r) => {
        if (!call) throw new McpError(ErrorCode.InvalidParams, `Unknown tool or bad arguments: ${r.params.name}`);
        return toResult(call);
      });
      const transport = new WebStandardStreamableHTTPServerTransport({ sessionIdGenerator: undefined, enableJsonResponse: true });
      await server.connect(transport);
      const headers = new Headers();
      for (const [k, v] of Object.entries(req.headers)) if (typeof v === 'string') headers.set(k, v);
      const res = await transport.handleRequest(new Request('http://mcp.local/mcp', { method: 'POST', headers, body: JSON.stringify(req.body) }), { parsedBody: req.body });
      const body = await res.text();
      await server.close();
      reply.code(res.status);
      res.headers.forEach((v, k) => reply.header(k, v));
      return reply.send(body);
    });

    // M2: stateless, so no SSE stream (GET) and no session to end (DELETE).
    app.route({ method: ['GET', 'DELETE'], url: '/', handler: (_req, reply) => reply.code(405).header('allow', 'POST').send() });
  };
}
