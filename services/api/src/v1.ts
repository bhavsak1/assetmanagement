// Story 9.2: the public API /v1 (docs/data-model-goal9.md §17, customer docs in docs/api-v1.md).
// API keys only. Every query runs as the key's integration user under RLS (withKey), so the database decides
// what it may see and change, exactly as for a person with the same groups and scope.
import { randomUUID } from 'node:crypto';
import type { FastifyError, FastifyInstance, FastifyReply, FastifyRequest } from 'fastify';
import { KeyError, type createDb, type Query } from './db.ts';

type WithKey = ReturnType<typeof createDb>['withKey'];

export const RATE_LIMIT = 120; // calls a minute per key (A6). shortcut: one constant, move to tenant_entitlement when a tenant needs more.
const TAG = 'v1';

// A10: RFC 9457 problem details. `code` is the stable string clients switch on.
const TITLES: Record<number, string> = { 401: 'Unauthorized', 403: 'Forbidden', 404: 'Not Found', 409: 'Conflict', 422: 'Unprocessable Content', 429: 'Too Many Requests' };
export function problem(reply: FastifyReply, status: number, code: string, detail?: string, extra?: object) {
  return reply.code(status).type('application/problem+json').send({ type: 'about:blank', title: TITLES[status] ?? 'Error', status, code, detail, ...extra });
}

class NotFound extends Error {}

// Timestamps as ISO 8601 UTC with microseconds (a JS Date would drop them and break the cursor);
// dates and money as text (a JS Date would shift a date by the server's zone; money keeps its scale).
const ts = (c: string) => `to_json(v.${c} at time zone 'UTC') #>> '{}' || 'Z' as ${c}`;
const ASSET_COLUMNS = [
  'v.id', 'v.tag', 'v.name', 'v.category_id', 'v.location_id', 'v.status', 'v.status_id', 'v.status_reason', ts('status_changed_at'),
  'v.quantity', 'v.parent_asset_id', 'v.criticality', 'v.serial_number', 'v.manufacturer', 'v.model',
  'v.purchase_date::text as purchase_date', 'v.purchase_value::text as purchase_value', 'v.purchase_currency',
  'v.in_service_date::text as in_service_date', 'v.custom_values', 'v.oem_vendor_id', 'v.om_vendor_id', 'v.coverage_state',
  ts('created_at'), ts('updated_at'),
].join(', ');

const str = (max: number) => ({ type: ['string', 'null'], maxLength: max });
const uuidOrNull = { type: ['string', 'null'], format: 'uuid' };
const dateOrNull = { type: ['string', 'null'], format: 'date' };
// The asset form's fields (3.3). Status and location change only through actions, so PATCH leaves them out.
const WRITABLE = {
  name: { type: 'string', minLength: 1, maxLength: 200 },
  tag: { type: 'string', pattern: '^[A-Za-z0-9][A-Za-z0-9._/-]{0,59}$', description: 'Left out on create: the tenant tag pattern makes one' },
  category_id: { type: 'string', format: 'uuid' },
  quantity: { type: 'integer', minimum: 1 },
  parent_asset_id: uuidOrNull,
  criticality: { type: ['string', 'null'], enum: ['A', 'B', 'C', null] },
  serial_number: str(200), manufacturer: str(200), model: str(200),
  purchase_date: dateOrNull, in_service_date: dateOrNull,
  purchase_value: { type: ['number', 'null'], minimum: 0, description: 'Needs asset_financials.update' },
  purchase_currency: { type: ['string', 'null'], pattern: '^[A-Z]{3}$' },
  custom_values: { type: 'object', additionalProperties: true, description: 'Keys are custom field keys' },
  oem_vendor_id: uuidOrNull, om_vendor_id: uuidOrNull,
} as const;
const CREATE_ONLY = { location_id: uuidOrNull, status_id: { type: 'string', format: 'uuid', description: 'Left out: the default active status' } };

const nullable = (type: string, extra: object = {}) => ({ type: [type, 'null'], ...extra });
const ASSET = {
  $id: 'Asset', type: 'object',
  properties: {
    id: { type: 'string', format: 'uuid' }, tag: { type: 'string' }, name: { type: 'string' },
    category_id: { type: 'string', format: 'uuid' }, location_id: nullable('string', { format: 'uuid' }),
    status: { type: 'string', enum: ['in_stock', 'active', 'under_maintenance', 'inactive', 'disposed'] },
    status_id: { type: 'string', format: 'uuid' }, status_reason: nullable('string'), status_changed_at: nullable('string', { format: 'date-time' }),
    quantity: { type: 'integer' }, parent_asset_id: nullable('string', { format: 'uuid' }), criticality: nullable('string'),
    serial_number: nullable('string'), manufacturer: nullable('string'), model: nullable('string'),
    purchase_date: nullable('string', { format: 'date' }),
    purchase_value: nullable('string', { description: 'Decimal as text. Null without asset_financials.view' }),
    purchase_currency: nullable('string'), in_service_date: nullable('string', { format: 'date' }),
    custom_values: { type: 'object', additionalProperties: true, description: 'Only the fields this key may view' },
    oem_vendor_id: nullable('string', { format: 'uuid' }), om_vendor_id: nullable('string', { format: 'uuid' }),
    coverage_state: nullable('string'),
    created_at: { type: 'string', format: 'date-time' }, updated_at: { type: 'string', format: 'date-time' },
  },
};
const LIST = (item: object) => ({ type: 'object', properties: { data: { type: 'array', items: item }, next_cursor: { type: ['string', 'null'] } } });
const PROBLEM = { description: 'Problem details (RFC 9457), content type application/problem+json', type: 'object', properties: { type: { type: 'string' }, title: { type: 'string' }, status: { type: 'integer' }, code: { type: 'string' }, detail: { type: 'string' },
  errors: { type: 'array', items: { type: 'object', properties: { field: { type: 'string' }, code: { type: 'string' } } } } } };
const ERRORS = { 401: PROBLEM, 404: PROBLEM, 422: PROBLEM, 429: PROBLEM };
const security = [{ apiKey: [] }];
const idParam = { type: 'object', required: ['id'], properties: { id: { type: 'string', format: 'uuid' } } };

const cursorOf = (row: { updated_at: string; id: string }) => Buffer.from(JSON.stringify([row.updated_at, row.id])).toString('base64url');
function parseCursor(cursor: string): [string, string] | null {
  try {
    const v: unknown = JSON.parse(Buffer.from(cursor, 'base64url').toString());
    if (Array.isArray(v) && v.length === 2 && typeof v[0] === 'string' && !Number.isNaN(Date.parse(v[0])) && typeof v[1] === 'string' && /^[0-9a-f-]{36}$/i.test(v[1])) return [v[0], v[1]];
  } catch { /* not a cursor */ }
  return null;
}

type AssetQuery = { limit: number; cursor?: string; updated_since?: string; category_id?: string; location_id?: string; status?: string; tag?: string };
type AssetBody = Record<string, unknown>;

export function v1(withKey: WithKey) {
  return async function routes(app: FastifyInstance) {
    app.addSchema(ASSET);

    const keyOf = (req: FastifyRequest) => /^Bearer (asly_\S+)$/.exec(req.headers.authorization ?? '')?.[1] ?? '';
    const db = <T>(req: FastifyRequest, fn: (q: Query) => Promise<T>) => withKey(keyOf(req), RATE_LIMIT, (q, who) => {
      req.log.info({ tenant_id: who.tenant_id, key_id: who.key_id }, 'api key'); // never the key itself
      return fn(q);
    });
    const one = async (q: Query, id: string) => (await q(`select ${ASSET_COLUMNS} from public.asset_view v where v.id = $1`, [id])).rows[0];

    app.setNotFoundHandler((_req, reply) => problem(reply, 404, 'not_found'));
    app.setErrorHandler((e: FastifyError & { code?: string }, req, reply) => {
      if (e instanceof KeyError && e.code === 'rate_limited') {
        return problem(reply.header('retry-after', String(60 - new Date().getUTCSeconds())), 429, 'rate_limited', `At most ${RATE_LIMIT} calls a minute per key`);
      }
      if (e instanceof KeyError) return problem(reply, 401, 'unauthorized', 'Missing, unknown, expired or revoked API key');
      if (e instanceof NotFound) return problem(reply, 404, 'not_found');
      if (e.validation) {
        const errors = e.validation.map((v) => ({ field: (v.instancePath.slice(1) || String(v.params.missingProperty ?? v.params.additionalProperty ?? '')).replaceAll('/', '.'), code: v.keyword }));
        return problem(reply, 422, 'validation_failed', e.message, { errors });
      }
      if (e.statusCode && e.statusCode < 500) return problem(reply, e.statusCode, 'bad_request', e.message);
      // Database refusals: RLS and the 3.3 write rules. Their messages are the reason (no data in them).
      if (e.code === '42501') return problem(reply, 403, 'forbidden', e.message);
      if (e.code === '23505') return problem(reply, 409, 'conflict', 'Tag or another unique value is already used');
      if (e.code && /^(22|23)/.test(e.code)) return problem(reply, 422, 'validation_failed', e.message);
      req.log.error(e);
      return reply.code(500).type('application/problem+json').send({ type: 'about:blank', title: 'Internal Server Error', status: 500, code: 'internal' });
    });

    app.get('/openapi.json', { schema: { hide: true } }, async () => app.swagger());

    app.get('/me', { schema: { tags: [TAG], summary: 'The integration user and tenant of this key', security, response: { ...ERRORS } } }, (req) =>
      db(req, async (q) => (await q(
        `select p.id as user_id, p.display_name as name, t.id as tenant_id, t.name as tenant_name
         from public.user_profile p, public.tenant t where p.id = auth.uid() and t.id = private.current_tenant_id()`,
      )).rows[0]));

    app.get<{ Querystring: AssetQuery }>('/assets', {
      schema: {
        tags: [TAG], summary: 'List assets, oldest change first', security,
        description: 'Pages by `(updated_at, id)`. To sync, keep the last `updated_at` you saw and pass it as `updated_since` next time.',
        querystring: {
          type: 'object', additionalProperties: false,
          properties: {
            limit: { type: 'integer', minimum: 1, maximum: 200, default: 50 },
            cursor: { type: 'string', maxLength: 200, description: '`next_cursor` from the previous page' },
            updated_since: { type: 'string', format: 'date-time', description: 'Changed at or after this time' },
            category_id: { type: 'string', format: 'uuid', description: 'With its subcategories' },
            location_id: { type: 'string', format: 'uuid', description: 'With its sublocations' },
            status: { type: 'string', enum: ['in_stock', 'active', 'under_maintenance', 'inactive', 'disposed'] },
            tag: { type: 'string', maxLength: 60 },
          },
        },
        response: { 200: LIST({ $ref: 'Asset#' }), ...ERRORS },
      },
    }, async (req, reply) => {
      const { limit, cursor, updated_since, category_id, location_id, status, tag } = req.query;
      const after = cursor === undefined ? null : parseCursor(cursor);
      if (cursor !== undefined && !after) return problem(reply, 422, 'validation_failed', 'Bad cursor', { errors: [{ field: 'cursor', code: 'format' }] });
      const rows = await db(req, async (q) => (await q<{ updated_at: string; id: string }>(
        `select ${ASSET_COLUMNS} from public.asset_view v
         where ($1::timestamptz is null or v.updated_at >= $1)
           and ($2::uuid is null or v.category_id = any ((select private.category_subtree_ids($2))::uuid[]))
           and ($3::uuid is null or v.location_id = any ((select private.location_subtree_ids($3))::uuid[]))
           and ($4::text is null or v.status = $4)
           and ($5::text is null or v.tag = upper($5))
           and ($6::timestamptz is null or (v.updated_at, v.id) > ($6, $7::uuid))
         order by v.updated_at, v.id limit $8`,
        [updated_since ?? null, category_id ?? null, location_id ?? null, status ?? null, tag ?? null, after?.[0] ?? null, after?.[1] ?? null, limit + 1],
      )).rows);
      const more = rows.length > limit;
      const data = more ? rows.slice(0, limit) : rows;
      return { data, next_cursor: more ? cursorOf(data[data.length - 1]!) : null };
    });

    app.get<{ Params: { id: string } }>('/assets/:id', {
      schema: { tags: [TAG], summary: 'One asset', security, params: idParam, response: { 200: { $ref: 'Asset#' }, ...ERRORS } },
    }, (req) => db(req, async (q) => (await one(q, req.params.id)) ?? Promise.reject(new NotFound())));

    app.post<{ Body: AssetBody }>('/assets', {
      schema: {
        tags: [TAG], summary: 'Create an asset (asset_core.create)', security,
        body: { type: 'object', additionalProperties: false, required: ['name', 'category_id'], properties: { ...WRITABLE, ...CREATE_ONLY } },
        response: { 201: { $ref: 'Asset#' }, 403: PROBLEM, 409: PROBLEM, ...ERRORS },
      },
    }, async (req, reply) => {
      const id = randomUUID(); // no RETURNING: a key may create without view (RLS would refuse the returned row)
      const row = { ...req.body, ...(typeof req.body.tag === 'string' && { tag: req.body.tag.toUpperCase() }) };
      const cols = Object.keys(row); // only schema properties reach here (additionalProperties: false)
      const asset = await db(req, async (q) => {
        await q(`insert into public.asset (id, tenant_id, ${cols.join(', ')}) values ($1, private.current_tenant_id(), ${cols.map((_, i) => `$${i + 2}`).join(', ')})`, [id, ...Object.values(row)]);
        return (await one(q, id)) ?? { id };
      });
      return reply.code(201).send(asset);
    });

    app.patch<{ Params: { id: string }; Body: AssetBody }>('/assets/:id', {
      schema: {
        tags: [TAG], summary: 'Change an asset (asset_core.update). Status and location change through actions, not here', security, params: idParam,
        body: { type: 'object', additionalProperties: false, minProperties: 1, properties: WRITABLE },
        response: { 200: { $ref: 'Asset#' }, 403: PROBLEM, 409: PROBLEM, ...ERRORS },
      },
    }, (req) => db(req, async (q) => {
      const row = { ...req.body, ...(typeof req.body.tag === 'string' && { tag: req.body.tag.toUpperCase() }) };
      const cols = Object.keys(row);
      const r = await q(`update public.asset set ${cols.map((c, i) => `${c} = $${i + 2}`).join(', ')} where id = $1 and deleted_at is null`, [req.params.id, ...Object.values(row)]);
      if (!r.rowCount) {
        // RLS hid the row from the update: 403 if this key can see it, 404 if not (no hint it exists).
        if (await one(q, req.params.id)) throw Object.assign(new Error('No permission to change this asset'), { code: '42501' });
        throw new NotFound();
      }
      return (await one(q, req.params.id)) ?? { id: req.params.id };
    }));

    // Master data the asset fields point at. Same tables the UI reads, under their own view domains.
    // shortcut: no paging, these lists are small; page them like /assets when a tenant passes a few thousand.
    const lists = {
      '/categories': ['Categories (category_config.view)', `select id, parent_id, name, code, is_active from public.asset_category where deleted_at is null order by name, id`],
      '/locations': ['Locations (location_hierarchy.view)', `select id, parent_id, name, code, location_type, active as is_active from public.location where deleted_at is null order by name, id`],
      '/asset-statuses': ['Asset statuses (asset_core.view)', `select id, code, label, system_status, is_active from public.asset_status where deleted_at is null order by label, id`],
    } as const;
    for (const [path, [summary, sql]] of Object.entries(lists)) {
      app.get(path, { schema: { tags: [TAG], summary, security, response: { 200: LIST({ type: 'object', additionalProperties: true }), ...ERRORS } } },
        (req) => db(req, async (q) => ({ data: (await q(sql)).rows, next_cursor: null })));
    }
  };
}
