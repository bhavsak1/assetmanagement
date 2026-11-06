// Story 10.6: the semantic layer and query compiler (data-model-goal10.md §5.1 to §5.3, D10 a). No model call.
// OWNER REVIEW (CLAUDE.md §9): this file decides which fields a user, and later the model, may see.
// A structured query (JSON) is checked against the user's own catalog and compiled to parameterised SQL. Every SQL
// fragment below is fixed text in this file; every value, custom-field key and limit from a query is a $n
// parameter. The SQL runs under withUser over the secure views, so RLS, scope (6.1) and masking (6.2) still apply.
import { Ajv } from 'ajv';
import type { Query } from './db.ts';

export type FieldType = 'text' | 'number' | 'money' | 'date' | 'enum' | 'ref' | 'boolean' | 'tags';
type RefKind = 'location' | 'category' | 'status' | 'vendor';

type FieldDef = {
  label: string;
  type: FieldType;
  sql: string; // on the subject's aliases; '$KEY' is replaced by the custom-field key's parameter
  domains?: string[]; // view needed on each, besides the subject's domains
  join?: string[]; // keys into the subject's joins
  id?: string; // ref: the id expression filters match on
  ref?: RefKind;
  currency?: string; // money: the currency expression
  options?: string[]; // enum and tags
  key?: string; // custom field: its key, sent as a parameter
};
type SubjectDef = {
  label: string;
  domains: string[];
  from: string;
  where: string;
  id: string;
  joins: Record<string, string>;
  fields: Record<string, FieldDef>;
  defaults: string[];
  custom?: { entity: 'asset' | 'vendor'; column: string };
};

const TODAY = '(select private.tenant_today())';
// A timestamp as a date in the tenant's time zone.
const day = (col: string) =>
  `(${col} at time zone (select t.time_zone from public.tenant t where t.id = (select private.current_tenant_id())))::date`;
const ACTIVE_COVER = (types: string) => `(select max(cv.end_date) from public.coverage_asset ca
  join public.coverage_view cv on cv.id = ca.coverage_id
  where ca.tenant_id = a.tenant_id and ca.asset_id = a.id and ca.deleted_at is null and cv.coverage_type in (${types}))`;

// The asset's own place in the register, shared by every subject that joins asset_view as a.
const ASSET_JOINS = {
  cat: 'left join public.asset_category cat on cat.tenant_id = a.tenant_id and cat.id = a.category_id',
  loc: 'left join public.location loc on loc.tenant_id = a.tenant_id and loc.id = a.location_id',
};
const ASSET_PLACE: Record<string, FieldDef> = {
  asset_tag: { label: 'Asset tag', type: 'text', sql: 'a.tag' },
  asset_name: { label: 'Asset name', type: 'text', sql: 'a.name' },
  category: { label: 'Category', type: 'ref', ref: 'category', sql: 'cat.name', id: 'a.category_id', join: ['cat'], domains: ['category_config'] },
  location: { label: 'Location', type: 'ref', ref: 'location', sql: 'loc.name', id: 'a.location_id', join: ['loc'], domains: ['location_hierarchy'] },
};

const SUBJECTS: Record<string, SubjectDef> = {
  asset: {
    label: 'Assets', domains: ['asset_core'], from: 'public.asset_view a', where: 'true', id: 'a.id',
    joins: {
      ...ASSET_JOINS,
      st: 'left join public.asset_status st on st.tenant_id = a.tenant_id and st.id = a.status_id',
      oem: 'left join public.vendor_view oem on oem.id = a.oem_vendor_id',
      om: 'left join public.vendor_view om on om.id = a.om_vendor_id',
    },
    fields: {
      tag: { label: 'Tag', type: 'text', sql: 'a.tag' },
      name: { label: 'Name', type: 'text', sql: 'a.name' },
      category: ASSET_PLACE.category!,
      location: ASSET_PLACE.location!,
      status: { label: 'Status', type: 'ref', ref: 'status', sql: 'st.label', id: 'a.status_id', join: ['st'] },
      criticality: { label: 'Criticality', type: 'enum', sql: 'a.criticality', options: ['A', 'B', 'C'] },
      serial_number: { label: 'Serial number', type: 'text', sql: 'a.serial_number' },
      manufacturer: { label: 'Manufacturer', type: 'text', sql: 'a.manufacturer' },
      model: { label: 'Model', type: 'text', sql: 'a.model' },
      purchase_date: { label: 'Purchase date', type: 'date', sql: 'a.purchase_date' },
      purchase_value: { label: 'Purchase value', type: 'money', sql: 'a.purchase_value', currency: 'a.purchase_currency::text', domains: ['asset_financials'] },
      in_service_date: { label: 'In service date', type: 'date', sql: 'a.in_service_date' },
      oem_vendor: { label: 'OEM vendor', type: 'ref', ref: 'vendor', sql: 'oem.name', id: 'a.oem_vendor_id', join: ['oem'], domains: ['vendor_core'] },
      om_vendor: { label: 'O&M vendor', type: 'ref', ref: 'vendor', sql: 'om.name', id: 'a.om_vendor_id', join: ['om'], domains: ['vendor_core'] },
      coverage_state: { label: 'Coverage', type: 'enum', sql: 'a.coverage_state', options: ['active', 'expiring', 'out', 'none'] },
      // Q3b: the latest end among live linked contracts, through coverage_view (contract scope applies).
      warranty_end: { label: 'Warranty end', type: 'date', sql: ACTIVE_COVER("'warranty', 'extended_warranty'"), domains: ['coverage_contract'] },
      amc_end: { label: 'AMC end', type: 'date', sql: ACTIVE_COVER("'amc'"), domains: ['coverage_contract'] },
      added_on: { label: 'Added on', type: 'date', sql: day('a.created_at') },
      last_changed: { label: 'Last changed', type: 'date', sql: day('a.updated_at') },
    },
    defaults: ['tag', 'name', 'category', 'location', 'status'],
    custom: { entity: 'asset', column: 'a.custom_values' },
  },
  obligation: {
    label: 'Maintenance obligations', domains: ['obligation', 'asset_core'],
    from: 'public.obligation o join public.asset_view a on a.tenant_id = o.tenant_id and a.id = o.asset_id',
    where: 'o.deleted_at is null', id: 'o.id', joins: ASSET_JOINS,
    fields: {
      name: { label: 'Name', type: 'text', sql: 'o.name' },
      type: { label: 'Type', type: 'enum', sql: 'o.obligation_type', options: ['service', 'calibration', 'inspection', 'certificate'] },
      next_due: { label: 'Next due', type: 'date', sql: 'o.next_due_date' },
      last_done: { label: 'Last done', type: 'date', sql: 'o.last_done_date' },
      due_state: { label: 'Due state', type: 'enum', sql: 'o.due_state', options: ['scheduled', 'due_soon', 'overdue', 'paused'] },
      ...ASSET_PLACE,
    },
    defaults: ['name', 'type', 'asset_tag', 'next_due', 'due_state'],
  },
  coverage: {
    label: 'Warranties and contracts', domains: ['coverage_contract'], from: 'public.coverage_view c', where: 'true', id: 'c.id',
    joins: { ven: 'left join public.vendor_view ven on ven.id = c.vendor_id' },
    fields: {
      reference: { label: 'Reference', type: 'text', sql: 'c.reference' },
      type: { label: 'Type', type: 'enum', sql: 'c.coverage_type', options: ['warranty', 'extended_warranty', 'amc', 'other'] },
      vendor: { label: 'Vendor', type: 'ref', ref: 'vendor', sql: 'ven.name', id: 'c.vendor_id', join: ['ven'], domains: ['vendor_core'] },
      start_date: { label: 'Start date', type: 'date', sql: 'c.start_date' },
      end_date: { label: 'End date', type: 'date', sql: 'c.end_date' },
      status: { label: 'Status', type: 'enum', sql: 'c.status', options: ['future', 'active', 'expiring', 'expired'] },
      contract_value: { label: 'Contract value', type: 'money', sql: 'c.contract_value', currency: 'c.contract_currency::text', domains: ['coverage_values'] },
      // coverage_asset RLS counts only the linked assets this user can see.
      asset_count: { label: 'Assets covered', type: 'number', sql: `(select count(*) from public.coverage_asset ca
        where ca.tenant_id = c.tenant_id and ca.coverage_id = c.id and ca.deleted_at is null)` },
    },
    defaults: ['reference', 'type', 'vendor', 'end_date', 'status'],
  },
  service_record: {
    label: 'Service records', domains: ['service_record', 'asset_core'],
    from: 'public.service_record_view r join public.asset_view a on a.tenant_id = r.tenant_id and a.id = r.asset_id',
    where: 'true', id: 'r.id',
    joins: {
      ...ASSET_JOINS,
      ven: 'left join public.vendor_view ven on ven.id = r.vendor_id',
      ob: 'left join public.obligation ob on ob.tenant_id = r.tenant_id and ob.id = r.obligation_id',
    },
    fields: {
      done_on: { label: 'Done on', type: 'date', sql: 'r.done_on' },
      outcome: { label: 'Outcome', type: 'enum', sql: 'r.outcome', options: ['pass', 'fail'] },
      vendor: { label: 'Vendor', type: 'ref', ref: 'vendor', sql: 'ven.name', id: 'r.vendor_id', join: ['ven'], domains: ['vendor_core'] },
      cost: { label: 'Cost', type: 'money', sql: 'r.cost_amount', currency: 'r.cost_currency::text', domains: ['service_values'] },
      certificate_expiry: { label: 'Certificate expiry', type: 'date', sql: 'r.certificate_expiry' },
      obligation_name: { label: 'Obligation', type: 'text', sql: 'ob.name', join: ['ob'], domains: ['obligation'] },
      obligation_type: { label: 'Obligation type', type: 'enum', sql: 'ob.obligation_type', join: ['ob'], domains: ['obligation'],
        options: ['service', 'calibration', 'inspection', 'certificate'] },
      ...ASSET_PLACE,
    },
    defaults: ['done_on', 'asset_tag', 'obligation_name', 'outcome', 'vendor'],
  },
  vendor: {
    label: 'Vendors', domains: ['vendor_core'], from: 'public.vendor_view v', where: 'true', id: 'v.id', joins: {},
    fields: {
      name: { label: 'Name', type: 'text', sql: 'v.name' },
      code: { label: 'Code', type: 'text', sql: 'v.code' },
      roles: { label: 'Roles', type: 'tags', sql: 'v.roles', options: ['oem', 'om', 'supplier'] },
      active: { label: 'Active', type: 'boolean', sql: 'v.is_active' },
      added_on: { label: 'Added on', type: 'date', sql: day('v.created_at') },
    },
    defaults: ['name', 'code', 'roles', 'active'],
    // Tax IDs (GSTIN, PAN) are custom fields in vendor_tax_ids: hidden_field_keys drops them without that domain.
    custom: { entity: 'vendor', column: 'v.custom_values' },
  },
  location: {
    label: 'Locations', domains: ['location_hierarchy'], from: 'public.location l', where: 'l.deleted_at is null', id: 'l.id',
    joins: { par: 'left join public.location par on par.tenant_id = l.tenant_id and par.id = l.parent_id' },
    fields: {
      name: { label: 'Name', type: 'text', sql: 'l.name' },
      code: { label: 'Code', type: 'text', sql: 'l.code' },
      type: { label: 'Type', type: 'text', sql: 'l.location_type' },
      parent: { label: 'Parent', type: 'ref', ref: 'location', sql: 'par.name', id: 'l.parent_id', join: ['par'] },
      active: { label: 'Active', type: 'boolean', sql: 'l.active' },
    },
    defaults: ['name', 'code', 'type', 'parent', 'active'],
  },
};

// Reference values the user may see, matched by name or code. RLS decides which rows.
const REF_SQL: Record<RefKind, string> = {
  location: 'select id, name as label, code from public.location where deleted_at is null',
  category: 'select id, name as label, null::text as code from public.asset_category where deleted_at is null',
  status: 'select id, label, code from public.asset_status',
  vendor: 'select id, name as label, code from public.vendor_view',
};

const OPS: Record<FieldType, string[]> = {
  text: ['eq', 'neq', 'in', 'contains', 'is_empty'],
  number: ['eq', 'neq', 'gt', 'gte', 'lt', 'lte', 'between', 'is_empty'],
  money: ['eq', 'neq', 'gt', 'gte', 'lt', 'lte', 'between', 'is_empty'],
  date: ['eq', 'gt', 'gte', 'lt', 'lte', 'between', 'is_empty', 'within_next_days', 'within_last_days', 'older_than_days'],
  enum: ['eq', 'neq', 'in', 'is_empty'],
  ref: ['eq', 'neq', 'in', 'is_empty'],
  boolean: ['eq'],
  tags: ['eq'],
};
const CAST: Partial<Record<FieldType, string>> = { number: 'numeric', money: 'numeric', date: 'date', boolean: 'boolean' };

// ---- The catalog ---------------------------------------------------------------------------------------------

export type Field = FieldDef & { ops: string[] };
export type Catalog = Record<string, SubjectDef & { fields: Record<string, Field> }>;
export type CustomDef = { entity: string; key: string; label: string; type: string; options: { code: string }[] };

const CUSTOM: Record<string, (col: string) => Pick<FieldDef, 'type' | 'sql'>> = {
  text: (c) => ({ type: 'text', sql: `(${c} ->> $KEY)` }),
  list: (c) => ({ type: 'enum', sql: `(${c} ->> $KEY)` }),
  // Safe casts: a value stored under an older type gives null, not an error.
  number: (c) => ({ type: 'number', sql: `(case when pg_input_is_valid(${c} ->> $KEY, 'numeric') then (${c} ->> $KEY)::numeric end)` }),
  date: (c) => ({ type: 'date', sql: `(case when pg_input_is_valid(${c} ->> $KEY, 'date') then (${c} ->> $KEY)::date end)` }),
  boolean: (c) => ({ type: 'boolean', sql: `(case when pg_input_is_valid(${c} ->> $KEY, 'boolean') then (${c} ->> $KEY)::boolean end)` }),
};

// Pure: the subjects and fields a holder of `rights` ('domain.operation') may see. Custom fields arrive already
// filtered (RLS on field_definition, minus hidden_field_keys); they are added only to subjects the user may see.
export function buildCatalog(rights: Set<string>, custom: CustomDef[]): Catalog {
  const can = (domains: string[] = []) => domains.every((d) => rights.has(`${d}.view`));
  const catalog: Catalog = {};
  for (const [name, s] of Object.entries(SUBJECTS)) {
    if (!can(s.domains)) continue;
    const fields: Record<string, Field> = {};
    for (const [key, f] of Object.entries(s.fields)) {
      if (!can(f.domains)) continue;
      const ops = f.type === 'ref' && f.ref === 'location' ? [...OPS.ref, 'in_place'] : OPS[f.type];
      fields[key] = { ...f, ops };
    }
    for (const c of custom) {
      const make = s.custom && c.entity === s.custom.entity ? CUSTOM[c.type] : undefined;
      if (!make || !s.custom) continue;
      const f = make(s.custom.column);
      fields[`custom.${c.key}`] = { label: c.label, ...f, key: c.key, ops: OPS[f.type],
        ...(c.type === 'list' ? { options: c.options.map((o) => o.code) } : {}) };
    }
    catalog[name] = { ...s, fields };
  }
  return catalog;
}

export async function loadRights(q: Query) {
  const rows = (await q<{ domain: string; operation: string }>('select domain, operation from public.my_permission')).rows;
  return new Set(rows.map((r) => `${r.domain}.${r.operation}`));
}

export async function loadCatalog(q: Query, rights: Set<string>): Promise<Catalog> {
  const custom = (await q<CustomDef>(`select f.entity, f.key, f.label, f.type, f.options from public.field_definition f
    where f.deleted_at is null and f.is_active and f.entity in ('asset', 'vendor')
      and not f.key = any (private.hidden_field_keys(f.entity))
    order by f.entity, f.sort_order, f.key`)).rows;
  return buildCatalog(rights, custom);
}

// What 10.7 shows the model and the chip editor: keys, labels, types, ops and options. Never SQL, never data.
export function publicCatalog(catalog: Catalog) {
  return Object.entries(catalog).map(([key, s]) => ({
    key, label: s.label,
    fields: Object.entries(s.fields).map(([k, f]) => ({ key: k, label: f.label, type: f.type, ops: f.ops,
      ...(f.options ? { options: f.options } : {}), ...(f.ref ? { ref: f.ref } : {}) })),
  }));
}

// ---- The query -----------------------------------------------------------------------------------------------

const KEY = { type: 'string', minLength: 1, maxLength: 100 } as const;
export const QUERY_SCHEMA = {
  type: 'object', additionalProperties: false, required: ['subject'],
  properties: {
    subject: { type: 'string', maxLength: 40 },
    fields: { type: 'array', maxItems: 20, items: KEY },
    filters: { type: 'array', maxItems: 10, items: { type: 'object', additionalProperties: false, required: ['field', 'op'],
      properties: { field: KEY, op: { type: 'string', maxLength: 30 }, value: {} } } },
    group_by: { type: 'array', maxItems: 2, items: { type: 'object', additionalProperties: false, required: ['field'],
      properties: { field: KEY, bucket: { enum: ['month', 'quarter', 'year'] } } } },
    measures: { type: 'array', maxItems: 5, items: { type: 'object', additionalProperties: false, required: ['fn'],
      properties: { fn: { enum: ['count', 'sum', 'avg', 'min', 'max'] }, field: KEY } } },
    sort: { type: 'array', maxItems: 3, items: { type: 'object', additionalProperties: false, required: ['field'],
      properties: { field: KEY, dir: { enum: ['asc', 'desc'] } } } },
    limit: { type: 'integer', minimum: 1, maximum: 1000 },
  },
} as const;

export type Filter = { field: string; op: string; value?: unknown };
export type InsightQuery = {
  subject: string; fields?: string[]; filters?: Filter[];
  group_by?: { field: string; bucket?: 'month' | 'quarter' | 'year' }[];
  measures?: { fn: 'count' | 'sum' | 'avg' | 'min' | 'max'; field?: string }[];
  sort?: { field: string; dir?: 'asc' | 'desc' }[]; limit?: number;
};

export class QueryError extends Error {
  readonly code: 'bad_query' | 'subject_not_allowed' | 'field_not_allowed' | 'bad_op' | 'bad_value';
  readonly at: string;
  constructor(code: QueryError['code'], at = '') {
    super(`${code} ${at}`);
    this.code = code;
    this.at = at;
  }
}

const validateShape = new Ajv({ strict: false }).compile<InsightQuery>(QUERY_SCHEMA);
const DATE = /^\d{4}-(0[1-9]|1[0-2])-(0[1-9]|[12]\d|3[01])$/;

// One scalar of this field's type, or a QueryError.
function scalar(f: Field, v: unknown, at: string): unknown {
  const ok = (() => {
    switch (f.type) {
      case 'text': case 'ref': return typeof v === 'string' && v.length >= 1 && v.length <= 200;
      case 'number': case 'money': return typeof v === 'number' && Number.isFinite(v);
      case 'date': return typeof v === 'string' && DATE.test(v) && !Number.isNaN(Date.parse(v));
      case 'enum': case 'tags': return typeof v === 'string' && (f.options ?? []).includes(v);
      case 'boolean': return typeof v === 'boolean';
    }
  })();
  if (!ok) throw new QueryError('bad_value', at);
  return v;
}

// Checks the shape, then every subject, field, op and value against this user's catalog. A field the user may
// not see is refused exactly like an unknown one, so a forged query learns nothing.
export function check(input: unknown, catalog: Catalog): InsightQuery {
  if (!validateShape(input)) throw new QueryError('bad_query', validateShape.errors?.[0]?.instancePath ?? '');
  const q = input;
  const s = Object.hasOwn(catalog, q.subject) ? catalog[q.subject]! : undefined;
  if (!s) throw new QueryError('subject_not_allowed', 'subject');
  const field = (key: string, at: string) => {
    if (!Object.hasOwn(s.fields, key)) throw new QueryError('field_not_allowed', at);
    return s.fields[key]!;
  };
  q.fields?.forEach((k, i) => field(k, `fields/${i}`));
  q.filters?.forEach((flt, i) => {
    const at = `filters/${i}`;
    const f = field(flt.field, at);
    if (!f.ops.includes(flt.op)) throw new QueryError('bad_op', at);
    const v = flt.value;
    switch (flt.op) {
      case 'in':
        if (!Array.isArray(v) || v.length < 1 || v.length > 50) throw new QueryError('bad_value', at);
        v.forEach((x) => scalar(f, x, at)); break;
      case 'between':
        if (!Array.isArray(v) || v.length !== 2) throw new QueryError('bad_value', at);
        v.forEach((x) => scalar(f, x, at)); break;
      case 'is_empty':
        if (typeof v !== 'boolean') throw new QueryError('bad_value', at); break;
      case 'within_next_days': case 'within_last_days': case 'older_than_days':
        if (!Number.isInteger(v) || (v as number) < 0 || (v as number) > 3650) throw new QueryError('bad_value', at); break;
      case 'in_place':
        if (Array.isArray(v) ? v.length < 1 || v.length > 50 || v.some((x) => typeof x !== 'string') : typeof v !== 'string') {
          throw new QueryError('bad_value', at);
        }
        (Array.isArray(v) ? v : [v]).forEach((x) => scalar(f, x, at)); break;
      default: scalar(f, v, at);
    }
  });
  q.group_by?.forEach((g, i) => {
    const f = field(g.field, `group_by/${i}`);
    if ((g.bucket !== undefined) !== (f.type === 'date')) throw new QueryError('bad_query', `group_by/${i}`);
    if (f.type === 'tags') throw new QueryError('bad_query', `group_by/${i}`);
  });
  q.measures?.forEach((m, i) => {
    const at = `measures/${i}`;
    if (m.fn === 'count') { if (m.field !== undefined) throw new QueryError('bad_query', at); return; }
    if (m.field === undefined) throw new QueryError('bad_query', at);
    const t = field(m.field, at).type;
    const okTypes = m.fn === 'sum' || m.fn === 'avg' ? ['number', 'money'] : ['number', 'money', 'date'];
    if (!okTypes.includes(t)) throw new QueryError('bad_op', at);
  });
  if (q.fields?.length && (q.measures?.length || q.group_by?.length)) throw new QueryError('bad_query', 'fields');
  q.sort?.forEach((o, i) => {
    const at = `sort/${i}`;
    if (q.measures?.length || q.group_by?.length) {
      const currencies = (q.measures ?? []).filter((m) => m.field && s.fields[m.field]!.type === 'money').map((m) => `${m.field}_currency`);
      if (![...outKeys(q), ...currencies].includes(o.field)) throw new QueryError('field_not_allowed', at);
    } else if (field(o.field, at).type === 'tags') throw new QueryError('bad_query', at);
  });
  return q;
}

const measureKey = (m: { fn: string; field?: string }) => (m.field ? `${m.fn}_${m.field}` : m.fn);
const outKeys = (q: InsightQuery) => [...(q.group_by ?? []).map((g) => g.field), ...(q.measures ?? [{ fn: 'count' }]).map(measureKey)];

// ---- Reference values ----------------------------------------------------------------------------------------

const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
export type Option = { id: string; label: string };
export type Resolved = { ids: string[][]; resolved: { filter: number; value: string; match: Option }[];
  needs_choice: { filter: number; value: string; options: Option[] }[] };

// Text values of ref filters to ids among rows this user can see (Q7): an id, an exact name or code, then
// a name containing the text, then pg_trgm at 0.4. One match is used; none or several come back as needs_choice for the user. No model call.
export async function resolveRefs(q: Query, query: InsightQuery, catalog: Catalog): Promise<Resolved> {
  const out: Resolved = { ids: [], resolved: [], needs_choice: [] };
  const fields = catalog[query.subject]!.fields;
  for (const [i, flt] of (query.filters ?? []).entries()) {
    const f = fields[flt.field]!;
    if (f.type !== 'ref' || flt.op === 'is_empty') continue;
    out.ids[i] = [];
    for (const value of (Array.isArray(flt.value) ? flt.value : [flt.value]) as string[]) {
      const src = REF_SQL[f.ref!];
      let found: Option[];
      if (UUID.test(value)) {
        found = (await q<Option>(`select id, label from (${src}) s where id = $1`, [value])).rows;
      } else {
        found = (await q<Option>(`select id, label from (${src}) s where lower(label) = lower($1) or lower(code) = lower($1)
          order by label limit 6`, [value])).rows;
        // 10.7: a word inside a longer name ("Pune" in "Plant 1 · Pune (Chakan)") scores under 0.4 by trigram.
        if (!found.length) {
          found = (await q<Option>(`select id, label from (${src}) s where label ilike $1 order by label limit 6`,
            [`%${likeEscape(value)}%`])).rows;
        }
        if (!found.length) {
          found = (await q<Option>(`select id, label from (${src}) s where extensions.similarity(label, $1) >= 0.4
            order by extensions.similarity(label, $1) desc, label limit 6`, [value])).rows;
        }
      }
      if (found.length === 1) {
        out.ids[i]!.push(found[0]!.id);
        out.resolved.push({ filter: i, value, match: found[0]! });
      } else {
        out.needs_choice.push({ filter: i, value, options: found.slice(0, 5) });
      }
    }
  }
  return out;
}

// ---- The compiler --------------------------------------------------------------------------------------------

export type Column = { key: string; label: string; type: FieldType | 'currency' };
export type Compiled = { sql: string; params: unknown[]; columns: Column[] };

const likeEscape = (s: string) => s.replace(/[\\%_]/g, (c) => `\\${c}`);

// Pure. `refIds[i]` holds the resolved ids of filter i when its field is a ref.
export function compile(input: unknown, catalog: Catalog, refIds: string[][] = []): Compiled {
  const q = check(input, catalog);
  const s = catalog[q.subject]!;
  const params: unknown[] = [];
  const val = (v: unknown) => { params.push(v); return `$${params.length}`; };
  const keyParams = new Map<string, string>();
  const used = new Set<string>();
  // The field's expression with its custom key as a parameter; records the joins it needs.
  const expr = (k: string, part: 'sql' | 'id' | 'currency' = 'sql') => {
    const f = s.fields[k]!;
    f.join?.forEach((j) => used.add(j));
    const text = part === 'sql' ? f.sql : part === 'id' ? f.id! : f.currency!;
    if (f.key === undefined) return text;
    if (!keyParams.has(f.key)) keyParams.set(f.key, `${val(f.key)}::text`);
    return text.replaceAll('$KEY', keyParams.get(f.key)!);
  };

  const where = [s.where];
  for (const [i, flt] of (q.filters ?? []).entries()) {
    const f = s.fields[flt.field]!;
    const v = flt.value;
    const cast = CAST[f.type] ? `::${CAST[f.type]}` : '';
    if (f.type === 'ref' && flt.op !== 'is_empty') {
      const id = expr(flt.field, 'id');
      const ids = refIds[i] ?? [];
      if (flt.op === 'in_place') where.push(`(${ids.map((x) => `${id} = any ((select private.location_subtree_ids(${val(x)}::uuid))::uuid[])`).join(' or ') || 'false'})`);
      else if (flt.op === 'neq') where.push(`(${id} is null or ${id} <> all (${val(ids)}::uuid[]))`);
      else where.push(`${id} = any (${val(ids)}::uuid[])`);
      continue;
    }
    const e = expr(flt.field);
    const lower = f.type === 'text';
    const one = (x: unknown) => (lower ? `lower(${val(x)})` : `${val(x)}${cast}`);
    const col = lower ? `lower(${e})` : e;
    switch (flt.op) {
      case 'eq': where.push(f.type === 'tags' ? `${val(v)}::text = any (${e})` : `${col} = ${one(v)}`); break;
      case 'neq': where.push(`${col} is distinct from ${one(v)}`); break;
      case 'in': where.push(`${col} = any (${val(lower ? (v as string[]).map((x) => x.toLowerCase()) : v)}${cast || '::text'}[])`); break;
      case 'contains': where.push(`${e} ilike ${val(`%${likeEscape(v as string)}%`)}`); break;
      case 'gt': where.push(`${e} > ${one(v)}`); break;
      case 'gte': where.push(`${e} >= ${one(v)}`); break;
      case 'lt': where.push(`${e} < ${one(v)}`); break;
      case 'lte': where.push(`${e} <= ${one(v)}`); break;
      case 'between': where.push(`${e} between ${one((v as unknown[])[0])} and ${one((v as unknown[])[1])}`); break;
      case 'is_empty': where.push(v ? (lower ? `coalesce(${e}, '') = ''` : `${e} is null`) : (lower ? `coalesce(${e}, '') <> ''` : `${e} is not null`)); break;
      case 'within_next_days': where.push(`${e} between ${TODAY} and ${TODAY} + ${val(v)}::int`); break;
      case 'within_last_days': where.push(`${e} between ${TODAY} - ${val(v)}::int and ${TODAY}`); break;
      case 'older_than_days': where.push(`${e} < ${TODAY} - ${val(v)}::int`); break;
    }
  }

  const select: string[] = [];
  const columns: Column[] = [];
  // 10.7: dates go out as 'YYYY-MM-DD' text; pg would make a JS Date at the server's local midnight (a day off east of UTC).
  const add = (sql: string, col: Column) => { select.push(`${col.type === 'date' ? `(${sql})::text` : sql} as c${select.length}`); columns.push(col); };
  const order: string[] = [];
  const dir = (d?: string) => (d === 'desc' ? 'desc nulls last' : 'asc nulls last');
  let group = '';

  if (q.measures?.length || q.group_by?.length) {
    const measures = q.measures?.length ? q.measures : [{ fn: 'count' as const }];
    const groupIds: string[] = [];
    for (const g of q.group_by ?? []) {
      const f = s.fields[g.field]!;
      add(g.bucket ? `date_trunc('${g.bucket}', ${expr(g.field)})::date` : expr(g.field), { key: g.field, label: f.label, type: f.type });
      if (f.type === 'ref') groupIds.push(expr(g.field, 'id')); // two places with one name stay apart
    }
    // CLAUDE.md §8: money never adds across currencies, so each money measure groups by its currency.
    const currencies = new Set<string>();
    for (const m of measures) {
      const f = m.field ? s.fields[m.field]! : undefined;
      if (f?.type === 'money' && !currencies.has(f.currency!)) {
        currencies.add(f.currency!);
        add(expr(m.field!, 'currency'), { key: `${m.field}_currency`, label: 'Currency', type: 'currency' });
      }
    }
    const groupCount = select.length;
    for (const m of measures) {
      const f = m.field ? s.fields[m.field]! : undefined;
      add(m.fn === 'count' ? 'count(*)' : `${m.fn}(${expr(m.field!)})`,
        { key: measureKey(m), label: f ? `${m.fn} ${f.label}` : 'count', type: f?.type === 'date' ? 'date' : f?.type === 'money' ? 'money' : 'number' });
    }
    if (groupCount) group = ` group by ${[...Array.from({ length: groupCount }, (_, i) => String(i + 1)), ...groupIds].join(', ')}`;
    for (const o of q.sort ?? []) order.push(`c${columns.findIndex((c) => c.key === o.field)} ${dir(o.dir)}`);
    for (let i = 0; i < groupCount; i++) order.push(`c${i} asc nulls last`);
  } else {
    add(s.id, { key: 'id', label: 'id', type: 'text' });
    for (const k of q.fields?.length ? q.fields : s.defaults.filter((d) => Object.hasOwn(s.fields, d))) {
      const f = s.fields[k]!;
      add(expr(k), { key: k, label: f.label, type: f.type });
      if (f.type === 'money') add(expr(k, 'currency'), { key: `${k}_currency`, label: 'Currency', type: 'currency' });
    }
    for (const o of q.sort ?? []) order.push(`${expr(o.field)} ${dir(o.dir)}`);
    order.push(s.id); // a stable order
  }

  const joins = Object.entries(s.joins).filter(([k]) => used.has(k)).map(([, j]) => j);
  const sql = `select ${select.join(', ')} from ${s.from} ${joins.join(' ')} where ${where.join(' and ')}${group}`
    + (order.length ? ` order by ${order.join(', ')}` : '') + ` limit ${val(q.limit ?? 100)}`;
  return { sql, params, columns };
}

// ---- Running it ----------------------------------------------------------------------------------------------

export const ASK_RIGHT = 'insights_query.ask';

// Q9: insights_query.ask and a live ai_addon. Read under RLS like every other read here.
export async function allowed(q: Query, rights: Set<string>) {
  if (!rights.has(ASK_RIGHT)) return false;
  return (await q<{ ok: boolean }>(`select exists (select 1 from public.tenant_entitlement e
    where e.tenant_id = private.current_tenant_id() and e.feature_code = 'ai_addon' and e.deleted_at is null
      and e.valid_from <= now() and (e.valid_to is null or e.valid_to > now())) as ok`)).rows[0]!.ok;
}

export type RunResult =
  | { needs_choice: Resolved['needs_choice']; resolved: Resolved['resolved'] }
  | { columns: Column[]; rows: unknown[][]; resolved: Resolved['resolved'] };

// Inside withUser: read only, 5 s (Q6). Throws QueryError before any SQL is built for a refused query.
export async function run(q: Query, input: unknown, catalog: Catalog): Promise<RunResult> {
  await q('set transaction read only');
  await q("set local statement_timeout = '5s'");
  const query = check(input, catalog);
  const refs = await resolveRefs(q, query, catalog);
  if (refs.needs_choice.length) return { needs_choice: refs.needs_choice, resolved: refs.resolved };
  const { sql, params, columns } = compile(query, catalog, refs.ids);
  const rows = (await q<Record<string, unknown>>(sql, params)).rows.map((r) => columns.map((_, i) => r[`c${i}`]));
  return { columns, rows, resolved: refs.resolved };
}
