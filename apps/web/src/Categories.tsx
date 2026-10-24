import { useEffect, useState, type FormEvent } from 'react'
import { loadStatuses, type Status } from './Assets'
import { t } from './i18n'
import { StatusesCard, StatusSetPicker, validateSet } from './Statuses'
import { supabase } from './supabase'
import { buildTree, lineage } from './tree'
import type { Json, Tables } from './types/database'

type Category = Pick<Tables<'asset_category'>, 'id' | 'parent_id' | 'name' | 'code' | 'is_active' | 'status_ids' | 'oem_vendor_ids' | 'om_vendor_ids'>
type Vendor = { id: string; name: string; roles: string[]; is_active: boolean }
const vendorRoles = ['oem', 'om'] as const
type VendorRole = (typeof vendorRoles)[number]
type Field = Tables<'field_definition'>
type Domain = { id: string; code: string }
type Option = { code: string; label: string; is_active: boolean }
type FieldType = keyof typeof t.categories.types

export const fieldTypes = Object.keys(t.categories.types) as FieldType[]
const keyPattern = /^[a-z][a-z0-9_]*$/
// Same as the asset_category.code check (migration 3_1_category_code).
export const codePattern = /^[A-Za-z0-9._-]{1,20}$/

// One option per line, 'code = Label'. Options dropped from the text stay stored as inactive,
// because values keep the code (data-model-goal2.md §1.2).
export function parseOptions(text: string, existing: Option[]): Option[] {
  const active = text
    .split('\n')
    .map((l) => l.trim())
    .filter(Boolean)
    .map((l) => {
      const [code = '', ...rest] = l.split('=')
      return { code: code.trim(), label: rest.join('=').trim() || code.trim(), is_active: true }
    })
  return [...active, ...existing.filter((o) => !active.some((a) => a.code === o.code)).map((o) => ({ ...o, is_active: false }))]
}

export type FieldInput = { key: string; label: string; type: string; options: Option[]; domainId: string }

// Deterministic checks before the write. The table's own checks still run.
export function validateField(f: FieldInput): string | undefined {
  const e = t.categories.errors
  if (!keyPattern.test(f.key) || f.key.length > 63) return e.key
  if (!f.label.trim()) return e.label
  if (!fieldTypes.includes(f.type as FieldType)) return e.type
  const active = f.options.filter((o) => o.is_active)
  if (f.type === 'list' && active.length === 0) return e.optionsRequired
  if (f.type === 'list' && active.some((o) => !keyPattern.test(o.code))) return e.optionCode
  if (new Set(f.options.map((o) => o.code)).size !== f.options.length) return e.optionDuplicate
  if (!f.domainId) return e.domain
  return undefined
}

// Fast feedback only: Postgres regex is close to, not the same as, JS. The database compiles it on save.
export function validPattern(p: string): boolean {
  try {
    new RegExp(p)
    return true
  } catch {
    return false
  }
}

// Postgres and PostgREST errors to one clear message each.
export function errorMessage(error: { code?: string; message?: string } | null, duplicate: string): string {
  const e = t.categories.errors
  const message = error?.message ?? ''
  if (error?.code === '42501') return e.noPermission
  if (error?.code === '2201B') return e.pattern
  if (error?.code === '23505')
    return message.includes('asset_category_code_uq') ? e.duplicateCode : message.includes('asset_status_label_uq') ? e.duplicateStatusLabel : duplicate
  // The 3.7 set trigger's messages all name the status set.
  if (error?.code === '23514' && message.includes('tagged')) return e.vendorTag
  if (error?.code === '23514') return message.includes('status set') ? e.setInvalid : message.includes('asset_status') ? e.statusInvalid : e.invalid
  if (error?.code === '22023') return e.defaultStatus
  return e.generic
}

const asOptions = (j: Json): Option[] => (Array.isArray(j) ? (j as Option[]) : [])

type Editing =
  | { kind: 'category'; row?: Category }
  | { kind: 'field'; row?: Field }

export function CategoriesPage({ tenantId, canManage }: { tenantId: string; canManage: boolean }) {
  const [categories, setCategories] = useState<Category[]>([])
  const [fields, setFields] = useState<Field[]>([])
  const [domains, setDomains] = useState<Domain[]>([])
  const [statuses, setStatuses] = useState<Status[]>([])
  const [vendors, setVendors] = useState<Vendor[]>([])
  const [selected, setSelected] = useState<string>()
  const [editing, setEditing] = useState<Editing>()
  const [error, setError] = useState<string>()
  const [reload, setReload] = useState(0)

  useEffect(() => {
    let live = true
    void Promise.all([
      supabase.from('asset_category').select('id, parent_id, name, code, is_active, status_ids, oem_vendor_ids, om_vendor_ids').is('deleted_at', null),
      supabase.from('field_definition').select('*').eq('entity', 'asset').is('deleted_at', null).order('sort_order'),
      supabase.rpc('field_domains', { p_entity: 'asset' }),
      loadStatuses(),
      supabase.from('vendor_view').select('id, name, roles, is_active').order('name'),
    ]).then(([c, f, d, s, vn]) => {
      if (!live) return
      setCategories(c.data ?? [])
      setFields(f.data ?? [])
      setDomains(d.data ?? [])
      setStatuses(s.data ?? [])
      setVendors((vn.data ?? []).map((x) => ({ id: x.id ?? '', name: x.name ?? '', roles: x.roles ?? [], is_active: x.is_active ?? false })))
      if (c.error || f.error || s.error) setError(t.categories.errors.load)
    })
    return () => {
      live = false
    }
  }, [reload])

  const tree = buildTree(categories)
  const current = categories.find((c) => c.id === selected) ?? tree[0]?.row
  const line = current ? lineage(categories, current.id) : []
  const own = fields.filter((f) => f.category_id === current?.id)
  // Inherited (G3): every-asset fields first, then furthest ancestor first, each by sort_order.
  const inherited = fields
    .filter((f) => f.category_id === null || (f.category_id !== current?.id && line.includes(f.category_id)))
    .sort((a, b) => rank(b) - rank(a) || a.sort_order - b.sort_order)
  function rank(f: Field) {
    return f.category_id === null ? line.length : line.indexOf(f.category_id)
  }
  const nameOf = (id: string | null) => (id ? categories.find((c) => c.id === id)?.name : t.categories.allAssets)
  const domainLabel = (id: string) => {
    const code = domains.find((d) => d.id === id)?.code ?? ''
    return (t.categories.domains as Record<string, string>)[code] ?? code
  }

  async function run(write: PromiseLike<{ data: unknown[] | null; error: { code?: string; message?: string } | null }>, duplicate: string) {
    setError(undefined)
    const { data, error } = await write
    // An update RLS filters out returns no rows and no error.
    if (error || !data?.length) {
      setError(errorMessage(error ?? { code: '42501' }, duplicate))
      return false
    }
    setEditing(undefined)
    setReload((n) => n + 1)
    return true
  }

  async function move(index: number, by: -1 | 1) {
    const order = [...own]
    const [f] = order.splice(index, 1)
    if (!f) return
    order.splice(index + by, 0, f)
    for (const [i, row] of order.entries()) {
      if (row.sort_order === i) continue
      const ok = await run(supabase.from('field_definition').update({ sort_order: i }).eq('id', row.id).select('id'), t.categories.errors.generic)
      if (!ok) return
    }
  }

  return (
    <>
      <title>{`${t.pages.categories} · ${t.app.name}`}</title>
      <div className="page-head">
        <div>
          <h1>{t.pages.categories}</h1>
          <span className="muted">{t.categories.subtitle}</span>
        </div>
        <div className="spacer" />
        {canManage && (
          <button className="btn btn-main" type="button" onClick={() => setEditing({ kind: 'category' })}>
            {t.categories.addCategory}
          </button>
        )}
      </div>
      {error && (
        <p className="login-error" role="alert">
          {error}
        </p>
      )}
      <div className="split">
        <div className="card tree" role="list" aria-label={t.pages.categories}>
          {tree.length === 0 && <p className="muted">{t.categories.none}</p>}
          {tree.map(({ row, depth }) => (
            <button
              key={row.id}
              type="button"
              role="listitem"
              className={`li${row.id === current?.id ? ' on' : ''}`}
              style={{ paddingLeft: 12 + depth * 20 }}
              aria-current={row.id === current?.id}
              onClick={() => {
                setSelected(row.id)
                setEditing(undefined)
              }}
            >
              {row.name}
              {!row.is_active && <span className="tag">{t.categories.inactive}</span>}
            </button>
          ))}
        </div>
        <div className="stack">
          {editing?.kind === 'category' && (
            <CategoryForm
              row={editing.row}
              categories={categories}
              statuses={statuses}
              vendors={vendors}
              onCancel={() => setEditing(undefined)}
              onError={setError}
              onSave={(v) =>
                run(
                  editing.row
                    ? supabase.from('asset_category').update(v).eq('id', editing.row.id).select('id')
                    : supabase.from('asset_category').insert({ ...v, tenant_id: tenantId }).select('id'),
                  t.categories.errors.duplicateName,
                )
              }
            />
          )}
          {editing?.kind === 'field' && current && (
            <FieldForm
              row={editing.row}
              domains={domains}
              onCancel={() => setEditing(undefined)}
              onError={setError}
              onSave={(v) =>
                run(
                  editing.row
                    ? supabase.from('field_definition').update(v).eq('id', editing.row.id).select('id')
                    : supabase
                        .from('field_definition')
                        .insert({ ...v, key: v.key ?? '', type: v.type ?? 'text', tenant_id: tenantId, entity: 'asset', category_id: current.id, sort_order: own.length })
                        .select('id'),
                  t.categories.errors.duplicateKey,
                )
              }
            />
          )}
          {current && (
            <div className="card">
              <div className="page-head">
                <h2>{t.categories.fieldsOf.replace('{name}', current.name)}</h2>
                <div className="spacer" />
                {canManage && (
                  <>
                    <button className="btn" type="button" onClick={() => setEditing({ kind: 'category', row: current })}>
                      {t.categories.editCategory}
                    </button>
                    <button className="btn" type="button" onClick={() => setEditing({ kind: 'field' })}>
                      {t.categories.addField}
                    </button>
                  </>
                )}
              </div>
              <div className="table-wrap">
                <table>
                  <thead>
                    <tr>
                      <th>{t.categories.col.field}</th>
                      <th>{t.categories.col.type}</th>
                      <th>{t.categories.col.required}</th>
                      <th>{t.categories.col.domain}</th>
                      {canManage && <th aria-label={t.categories.col.actions} />}
                    </tr>
                  </thead>
                  <tbody>
                    {inherited.map((f) => (
                      <tr key={f.id} className="muted">
                        <td>
                          {f.label}
                          <span className="tag">{t.categories.inheritedFrom.replace('{name}', nameOf(f.category_id) ?? '')}</span>
                          {!f.is_active && <span className="tag">{t.categories.inactive}</span>}
                        </td>
                        <td>{typeLabel(f)}</td>
                        <td>
                          <Switch on={f.is_required} />
                        </td>
                        <td>{domainLabel(f.security_domain_id)}</td>
                        {canManage && <td />}
                      </tr>
                    ))}
                    {own.map((f, i) => (
                      <tr key={f.id}>
                        <td>
                          {f.label} <code className="muted">{f.key}</code>
                          {!f.is_active && <span className="tag">{t.categories.inactive}</span>}
                        </td>
                        <td>{typeLabel(f)}</td>
                        <td>
                          <Switch on={f.is_required} />
                        </td>
                        <td>{domainLabel(f.security_domain_id)}</td>
                        {canManage && (
                          <td className="actions">
                            <button className="btn" type="button" disabled={i === 0} onClick={() => void move(i, -1)} aria-label={t.categories.moveUp}>
                              ↑
                            </button>
                            <button className="btn" type="button" disabled={i === own.length - 1} onClick={() => void move(i, 1)} aria-label={t.categories.moveDown}>
                              ↓
                            </button>
                            <button className="btn" type="button" onClick={() => setEditing({ kind: 'field', row: f })}>
                              {t.categories.edit}
                            </button>
                          </td>
                        )}
                      </tr>
                    ))}
                    {inherited.length + own.length === 0 && (
                      <tr>
                        <td colSpan={5} className="muted">
                          {t.categories.noFields}
                        </td>
                      </tr>
                    )}
                  </tbody>
                </table>
              </div>
            </div>
          )}
        </div>
      </div>
      <StatusesCard statuses={statuses} canManage={canManage} tenantId={tenantId} run={run} onError={setError} />
    </>
  )
}

function typeLabel(f: Field) {
  const label = t.categories.types[f.type as FieldType] ?? f.type
  return f.unit ? `${label} · ${f.unit}` : label
}

function Switch({ on }: { on: boolean }) {
  return <span className={`sw${on ? '' : ' off'}`} role="img" aria-label={on ? t.categories.yes : t.categories.no} />
}

function CategoryForm({
  row,
  categories,
  statuses,
  vendors,
  onSave,
  onCancel,
  onError,
}: {
  row?: Category
  categories: Category[]
  statuses: Status[]
  vendors: Vendor[]
  onSave: (v: { name: string; parent_id: string | null; code: string | null; is_active: boolean; status_ids: string[] | null; oem_vendor_ids?: string[]; om_vendor_ids?: string[] }) => Promise<boolean>
  onCancel: () => void
  onError: (message: string) => void
}) {
  // A category cannot sit under itself or its own children. The database also refuses a cycle.
  const blocked = new Set(row ? categories.filter((c) => lineage(categories, c.id).includes(row.id)).map((c) => c.id) : [])
  const [parentId, setParentId] = useState(row?.parent_id ?? '')
  const [code, setCode] = useState(row?.code ?? '')
  const [statusIds, setStatusIds] = useState(row?.status_ids ?? null)
  const [tags, setTags] = useState<Record<VendorRole, string[]>>({ oem: row?.oem_vendor_ids ?? [], om: row?.om_vendor_ids ?? [] })
  const inherited = inheritedCode(categories, parentId)

  function submit(e: FormEvent<HTMLFormElement>) {
    e.preventDefault()
    const form = new FormData(e.currentTarget)
    const value = code.trim()
    if (value && !codePattern.test(value)) return onError(t.categories.errors.code)
    const badSet = statusIds && validateSet(statusIds, statuses)
    if (badSet) return onError(badSet)
    void onSave({
      name: String(form.get('name')).trim(),
      parent_id: parentId || null,
      code: value || null,
      is_active: form.get('active') === 'on',
      status_ids: statusIds,
      // Sent only when changed: tags are checked on change, and most saves do not touch them.
      ...vendorRoles.reduce((o, role) => {
        const before = (role === 'oem' ? row?.oem_vendor_ids : row?.om_vendor_ids) ?? []
        return JSON.stringify(tags[role]) === JSON.stringify(before) ? o : { ...o, [`${role}_vendor_ids`]: tags[role] }
      }, {}),
    })
  }

  return (
    <form className="card" onSubmit={submit}>
      <h2>{row ? t.categories.editCategory : t.categories.addCategory}</h2>
      <label className="field">
        {t.categories.name}
        <input name="name" defaultValue={row?.name} required maxLength={200} />
      </label>
      <label className="field">
        {t.categories.parent}
        <select name="parent" value={parentId} onChange={(e) => setParentId(e.target.value)}>
          <option value="">{t.categories.noParent}</option>
          {buildTree(categories)
            .filter(({ row: c }) => !blocked.has(c.id))
            .map(({ row: c, depth }) => (
              <option key={c.id} value={c.id}>
                {`${'— '.repeat(depth)}${c.name}`}
              </option>
            ))}
        </select>
      </label>
      <label className="field">
        {t.categories.code}
        <input name="code" value={code} onChange={(e) => setCode(e.target.value)} maxLength={20} spellCheck={false} aria-describedby="code-hint" />
        <span id="code-hint" className="muted hint">
          {t.categories.codeHint}
          {!code.trim() && inherited && ` ${t.categories.codeInherited.replace('{code}', inherited.code ?? '').replace('{name}', inherited.name)}`}
        </span>
      </label>
      <label className="check">
        <input name="active" type="checkbox" defaultChecked={row?.is_active ?? true} />
        {t.categories.active}
      </label>
      <StatusSetPicker categories={categories} statuses={statuses} parentId={parentId} value={statusIds} onChange={setStatusIds} />
      <VendorTags categories={categories} vendors={vendors} parentId={parentId} value={tags} onChange={setTags} />
      <FormButtons onCancel={onCancel} />
    </form>
  )
}

// Story 4.1b (B1, B2): vendors tagged per role. Tags of the parent and above also apply (union, as
// private.allowed_vendor_ids); they show read-only with their source.
function VendorTags({
  categories,
  vendors,
  parentId,
  value,
  onChange,
}: {
  categories: Category[]
  vendors: Vendor[]
  parentId: string
  value: Record<VendorRole, string[]>
  onChange: (v: Record<VendorRole, string[]>) => void
}) {
  const s = t.categories.vendorTags
  const [pick, setPick] = useState<Record<VendorRole, string>>({ oem: '', om: '' })
  const nameOf = (id: string) => vendors.find((x) => x.id === id)?.name ?? '—'
  const tagsOf = (c: Category, role: VendorRole) => (role === 'oem' ? c.oem_vendor_ids : c.om_vendor_ids) ?? []
  const ancestors = parentId ? lineage(categories, parentId).map((id) => categories.find((c) => c.id === id)) : []
  return (
    <fieldset className="field set">
      <legend>{s.title}</legend>
      <span className="muted hint">{s.hint}</span>
      {vendorRoles.map((role) => {
        const label = role === 'oem' ? s.oem : s.om
        const ids = value[role]
        // Active vendors with the role; an id already tagged stays even when it no longer qualifies (B4).
        const addable = vendors.filter((x) => x.is_active && x.roles.includes(role) && !ids.includes(x.id))
        return (
          <div key={role}>
            <b>{label}</b>
            {ancestors.map(
              (c) =>
                c &&
                tagsOf(c, role).length > 0 && (
                  <p key={c.id} className="muted hint">
                    {s.inherited.replace('{name}', c.name).replace('{vendors}', tagsOf(c, role).map(nameOf).join(', '))}
                  </p>
                ),
            )}
            {ids.length === 0 ? (
              <p className="muted hint">{s.none}</p>
            ) : (
              <ul className="set-list">
                {ids.map((id) => (
                  <li key={id}>
                    {nameOf(id)}
                    {vendors.find((x) => x.id === id)?.is_active === false && <span className="tag">{t.categories.inactive}</span>}
                    <span className="actions">
                      <button className="btn" type="button" onClick={() => onChange({ ...value, [role]: ids.filter((x) => x !== id) })} aria-label={`${s.remove} ${nameOf(id)}`}>
                        {s.remove}
                      </button>
                    </span>
                  </li>
                ))}
              </ul>
            )}
            <div className="page-head">
              <select aria-label={s.addLabel.replace('{role}', label)} value={pick[role]} onChange={(e) => setPick({ ...pick, [role]: e.target.value })}>
                <option value="">{s.choose}</option>
                {addable.map((x) => (
                  <option key={x.id} value={x.id}>
                    {x.name}
                  </option>
                ))}
              </select>
              <button
                className="btn"
                type="button"
                disabled={!pick[role]}
                onClick={() => {
                  onChange({ ...value, [role]: [...ids, pick[role]] })
                  setPick({ ...pick, [role]: '' })
                }}
              >
                {s.add}
              </button>
            </div>
          </div>
        )
      })}
    </fieldset>
  )
}

// What {CAT} uses for a category with no code: the nearest ancestor's code (as private.asset_tag_prefix does).
export function inheritedCode(categories: Category[], parentId: string) {
  if (!parentId) return undefined
  return lineage(categories, parentId)
    .map((id) => categories.find((c) => c.id === id))
    .find((c) => c?.code)
}

type FieldValues = Partial<Pick<Field, 'key' | 'type'>> &
  Pick<Field, 'label' | 'options' | 'unit' | 'pattern' | 'is_required' | 'security_domain_id' | 'is_active'>

// Also the Vendors page's field form (4.1): same table, entity vendor.
export function FieldForm({
  row,
  domains,
  onSave,
  onCancel,
  onError,
}: {
  row?: Field
  domains: Domain[]
  onSave: (v: FieldValues) => Promise<boolean>
  onCancel: () => void
  onError: (message: string) => void
}) {
  const [type, setType] = useState(row?.type ?? 'text')
  const existing = asOptions(row?.options ?? [])

  function submit(e: FormEvent<HTMLFormElement>) {
    e.preventDefault()
    const form = new FormData(e.currentTarget)
    const options = type === 'list' ? parseOptions(String(form.get('options')), existing) : []
    const input = {
      key: row?.key ?? String(form.get('key')).trim(),
      label: String(form.get('label')).trim(),
      type,
      options,
      domainId: String(form.get('domain') ?? ''),
    }
    const invalid = validateField(input)
    if (invalid) return onError(invalid)
    const pattern = type === 'text' ? String(form.get('pattern')).trim() || null : null
    if (pattern && !validPattern(pattern)) return onError(t.categories.errors.pattern)
    const values: FieldValues = {
      label: input.label,
      options,
      unit: type === 'number' ? String(form.get('unit')).trim() || null : null,
      pattern,
      is_required: form.get('required') === 'on',
      security_domain_id: input.domainId,
      is_active: form.get('active') === 'on',
    }
    // key and type cannot change after insert (2.1 column grants), so only a new field sends them.
    void onSave(row ? values : { ...values, key: input.key, type })
  }

  return (
    <form className="card" onSubmit={submit} noValidate>
      <h2>{row ? t.categories.editField : t.categories.addField}</h2>
      <label className="field">
        {t.categories.key}
        <input name="key" defaultValue={row?.key} disabled={!!row} maxLength={63} aria-describedby="key-hint" />
        <span id="key-hint" className="muted hint">
          {row ? t.categories.keyLocked : t.categories.keyHint}
        </span>
      </label>
      <label className="field">
        {t.categories.label}
        <input name="label" defaultValue={row?.label} />
      </label>
      <label className="field">
        {t.categories.type}
        <select name="type" value={type} disabled={!!row} onChange={(e) => setType(e.target.value)}>
          {fieldTypes.map((ft) => (
            <option key={ft} value={ft}>
              {t.categories.types[ft]}
            </option>
          ))}
        </select>
      </label>
      {type === 'number' && (
        <label className="field">
          {t.categories.unit}
          <input name="unit" defaultValue={row?.unit ?? ''} />
        </label>
      )}
      {type === 'text' && (
        <label className="field">
          {t.categories.pattern}
          <input name="pattern" defaultValue={row?.pattern ?? ''} maxLength={200} spellCheck={false} />
          <span className="muted hint">{t.categories.patternHint}</span>
        </label>
      )}
      {type === 'list' && (
        <label className="field">
          {t.categories.options}
          <textarea
            name="options"
            rows={4}
            defaultValue={existing
              .filter((o) => o.is_active)
              .map((o) => `${o.code} = ${o.label}`)
              .join('\n')}
          />
          <span className="muted hint">{t.categories.optionsHint}</span>
        </label>
      )}
      <label className="field">
        {t.categories.domain}
        <select name="domain" defaultValue={row?.security_domain_id ?? domains[0]?.id}>
          {domains.map((d) => (
            <option key={d.id} value={d.id}>
              {(t.categories.domains as Record<string, string>)[d.code] ?? d.code}
            </option>
          ))}
        </select>
      </label>
      <label className="check">
        <input name="required" type="checkbox" defaultChecked={row?.is_required} />
        {t.categories.required}
      </label>
      <label className="check">
        <input name="active" type="checkbox" defaultChecked={row?.is_active ?? true} />
        {t.categories.active}
      </label>
      <FormButtons onCancel={onCancel} />
    </form>
  )
}

function FormButtons({ onCancel }: { onCancel: () => void }) {
  return (
    <div className="page-head">
      <div className="spacer" />
      <button className="btn" type="button" onClick={onCancel}>
        {t.categories.cancel}
      </button>
      <button className="btn btn-main" type="submit">
        {t.categories.save}
      </button>
    </div>
  )
}
