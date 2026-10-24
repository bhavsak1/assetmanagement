import { useEffect, useState, type FormEvent } from 'react'
import { CustomInput, customPayload } from './AssetForm'
import { errorMessage, FieldForm } from './Categories'
import { t } from './i18n'
import { supabase } from './supabase'
import type { Json, Tables } from './types/database'

type Vendor = Tables<'vendor_view'>
type Contact = Tables<'vendor_contact'>
type Field = Tables<'field_definition'>
type Domain = { id: string; code: string }
type Can = (domain: string, operation: string) => boolean
type DbError = { code?: string; message?: string }
export type Filters = { q: string; role: string; state: '' | 'active' | 'inactive' }

const v = t.vendors
const PAGE = 50
export const roles = ['oem', 'om', 'supplier'] as const
// Same as the vendor.code check (migration 4_1_vendor), before the trigger upper-cases it.
const codePattern = /^[A-Za-z0-9._-]{1,20}$/
const obj = (j: Json | undefined) => (j && typeof j === 'object' && !Array.isArray(j) ? j : {})

// The search box as a PostgREST or() filter on name and code (V5: plain ilike). Characters that are
// syntax in or() or wildcards in ilike are dropped, so the text is always matched as typed words.
export function searchFilter(q: string): string | undefined {
  const s = q.replace(/[,()*%_\\:."]/g, ' ').trim()
  return s ? `name.ilike.*${s}*,code.ilike.*${s}*` : undefined
}

// The list's tax column (§3): the first vendor field in vendor_tax_ids by sort order, if any.
export function taxField(fields: Field[], domains: Domain[]): Field | undefined {
  const tax = domains.find((d) => d.code === 'vendor_tax_ids')?.id
  return fields.filter((f) => f.security_domain_id === tax && f.is_active).sort((a, b) => a.sort_order - b.sort_order)[0]
}

// A database error to one message. Custom field messages name the key; show its label.
export function vendorError(error: DbError, fields: Field[]): string {
  const m = error.message ?? ''
  const label = (key: string) => fields.find((f) => f.key === key)?.label ?? key
  const custom = /custom field (\w+)/.exec(m)?.[1]
  if (error.code === '23502' && m.startsWith('missing mandatory fields: '))
    return v.errors.required.replace('{names}', m.slice('missing mandatory fields: '.length).split(', ').map(label).join(', '))
  if (custom) {
    if (error.code === '42501') return v.errors.fieldPermission.replace('{name}', label(custom))
    return (m.includes('format') ? v.errors.format : v.errors.field).replace('{name}', label(custom))
  }
  if (error.code === '23505') return m.includes('vendor_code_uq') ? v.errors.duplicateCode : v.errors.duplicateName
  if (error.code === '42501') return v.errors.noPermission
  if (m.includes('code')) return v.errors.code
  if (m.includes('email')) return v.errors.email
  return v.errors.generic
}

export function VendorsPage({ tenantId, can }: { tenantId: string; can: Can }) {
  const [typed, setTyped] = useState('')
  const [filters, setFilters] = useState<Filters>({ q: '', role: '', state: '' })
  const [limit, setLimit] = useState(PAGE)
  const [rows, setRows] = useState<Vendor[]>()
  const [primary, setPrimary] = useState<Record<string, Contact>>({})
  const [fields, setFields] = useState<Field[]>([])
  const [domains, setDomains] = useState<Domain[]>([])
  const [open, setOpen] = useState<{ row?: Vendor }>()
  const [error, setError] = useState<string>()
  const [reload, setReload] = useState(0)

  // Search as you type, after a short pause.
  useEffect(() => {
    const id = setTimeout(() => setFilters((f) => (f.q === typed ? f : { ...f, q: typed })), 300)
    return () => clearTimeout(id)
  }, [typed])

  useEffect(() => {
    let live = true
    void Promise.all([
      supabase.from('field_definition').select('*').eq('entity', 'vendor').is('deleted_at', null).order('sort_order'),
      supabase.rpc('field_domains', { p_entity: 'vendor' }),
    ]).then(([f, d]) => {
      if (!live) return
      setFields(f.data ?? [])
      setDomains(d.data ?? [])
    })
    return () => {
      live = false
    }
  }, [reload])

  useEffect(() => {
    let live = true
    let q = supabase.from('vendor_view').select('*')
    const s = searchFilter(filters.q)
    if (s) q = q.or(s)
    if (filters.role) q = q.contains('roles', [filters.role])
    if (filters.state) q = q.eq('is_active', filters.state === 'active')
    // One extra row tells whether there is more. shortcut: grows the page, fine at SME vendor counts (V5).
    void q
      .order('name')
      .order('id')
      .limit(limit + 1)
      .then(async ({ data, error }) => {
        const ids = (data ?? []).map((r) => r.id ?? '')
        const c = ids.length
          ? await supabase.from('vendor_contact').select('*').eq('is_primary', true).is('deleted_at', null).in('vendor_id', ids)
          : { data: [] as Contact[] }
        if (!live) return
        setRows(data ?? [])
        setPrimary(Object.fromEntries((c.data ?? []).map((p) => [p.vendor_id, p])))
        setError(error ? v.errors.load : undefined)
      })
    return () => {
      live = false
    }
  }, [filters, limit, reload])

  const tax = taxField(fields, domains)
  const shown = (rows ?? []).slice(0, limit)
  const filtered = filters.q || filters.role || filters.state
  const pick = (k: keyof Filters, value: string) => {
    setLimit(PAGE)
    setFilters((f) => ({ ...f, [k]: value }))
  }

  return (
    <>
      <title>{`${t.pages.vendors} · ${t.app.name}`}</title>
      <div className="page-head">
        <div>
          <h1>{t.pages.vendors}</h1>
          <span className="muted">{v.subtitle}</span>
        </div>
        <div className="spacer" />
        {can('vendor_core', 'create') && (
          <button className="btn btn-main" type="button" onClick={() => setOpen({})}>
            {v.add}
          </button>
        )}
      </div>
      <div className="page-head filters">
        <input className="search" type="search" placeholder={v.filter} aria-label={v.filter} value={typed} onChange={(e) => setTyped(e.target.value)} />
        <select className="filter" aria-label={v.col.roles} value={filters.role} onChange={(e) => pick('role', e.target.value)}>
          <option value="">{v.allRoles}</option>
          {roles.map((r) => (
            <option key={r} value={r}>
              {v.roles[r]}
            </option>
          ))}
        </select>
        <select className="filter" aria-label={v.active} value={filters.state} onChange={(e) => pick('state', e.target.value)}>
          <option value="">{v.allStates}</option>
          <option value="active">{v.activeOnly}</option>
          <option value="inactive">{v.inactiveOnly}</option>
        </select>
      </div>
      {error && (
        <p className="login-error" role="alert">
          {error}
        </p>
      )}
      {open && (
        <VendorPanel
          key={open.row?.id ?? 'new'}
          row={open.row}
          tenantId={tenantId}
          fields={fields}
          domains={domains}
          can={can}
          onSaved={(row) => {
            setOpen({ row })
            setReload((n) => n + 1)
          }}
          onContacts={() => setReload((n) => n + 1)}
          onClose={() => setOpen(undefined)}
        />
      )}
      <div className="card table-wrap list">
        {rows === undefined ? (
          <p className="muted" role="status">
            {v.loading}
          </p>
        ) : shown.length === 0 ? (
          <p className="muted">{filtered ? v.noMatch : v.none}</p>
        ) : (
          <table>
            <thead>
              <tr>
                <th>{v.col.vendor}</th>
                <th>{v.col.roles}</th>
                <th>{v.col.contact}</th>
                {tax && <th>{tax.label}</th>}
              </tr>
            </thead>
            <tbody>
              {shown.map((r) => {
                const p = primary[r.id ?? '']
                return (
                  <tr key={r.id}>
                    <td>
                      <button className="row-link" type="button" onClick={() => setOpen({ row: r })}>
                        {r.name}
                      </button>
                      {r.code && <span className="muted"> {r.code}</span>}
                      {!r.is_active && <span className="tag">{v.inactive}</span>}
                    </td>
                    <td>
                      {(r.roles ?? []).map((role) => (
                        <span key={role} className="tag status">
                          {(v.roles as Record<string, string>)[role] ?? role}
                        </span>
                      ))}
                    </td>
                    <td>{p ? [p.name, p.phone ?? p.email].filter(Boolean).join(' · ') : '—'}</td>
                    {tax && (
                      <td>
                        {can('vendor_tax_ids', 'view') ? asText(obj(r.custom_values)[tax.key]) || '—' : <span className="muted">{v.hidden}</span>}
                      </td>
                    )}
                  </tr>
                )
              })}
            </tbody>
          </table>
        )}
      </div>
      {(rows?.length ?? 0) > limit && (
        <div className="page-head">
          <div className="spacer" />
          <button className="btn" type="button" onClick={() => setLimit((n) => n + PAGE)}>
            {v.more}
          </button>
        </div>
      )}
      {can('category_config', 'manage') && (
        <VendorFieldsCard tenantId={tenantId} fields={fields} domains={domains} onSaved={() => setReload((n) => n + 1)} />
      )}
    </>
  )
}

const asText = (j: Json | undefined) => (j === undefined || j === null ? '' : String(j))

function VendorPanel({
  row,
  tenantId,
  fields,
  domains,
  can,
  onSaved,
  onContacts,
  onClose,
}: {
  row?: Vendor
  tenantId: string
  fields: Field[]
  domains: Domain[]
  can: Can
  onSaved: (row: Vendor) => void
  onContacts: () => void
  onClose: () => void
}) {
  const editable = row ? can('vendor_core', 'update') : can('vendor_core', 'create')
  const stored = obj(row?.custom_values) as Record<string, Json | undefined>
  const domainCode = (f: Field) => domains.find((d) => d.id === f.security_domain_id)?.code ?? ''
  const canWrite = (f: Field) => editable && can(domainCode(f), 'update')
  // Active fields, plus inactive ones that still hold a value on this vendor (shown read-only).
  const line = fields.filter((f) => f.is_active || stored[f.key] !== undefined)
  const [values, setValues] = useState<Record<string, string>>(() =>
    Object.fromEntries(line.map((f) => [`custom.${f.key}`, asText(stored[f.key])])),
  )
  const [picked, setPicked] = useState<string[]>(row?.roles ?? [])
  const [error, setError] = useState<string>()
  const [busy, setBusy] = useState(false)

  async function submit(e: FormEvent<HTMLFormElement>) {
    e.preventDefault()
    const form = new FormData(e.currentTarget)
    const text = (k: string) => String(form.get(k) ?? '').trim() || null
    const name = text('name')
    const code = text('code')
    if (!name) return setError(v.errors.name)
    if (code && !codePattern.test(code)) return setError(v.errors.code)
    const payload = {
      name,
      code,
      roles: picked,
      phone: text('phone'),
      email: text('email'),
      website: text('website'),
      address: text('address'),
      notes: text('notes'),
      is_active: row ? form.get('active') === 'on' : true,
      custom_values: customPayload(stored, values, line, canWrite),
    }
    setBusy(true)
    setError(undefined)
    // Base table writes; the masked row is read back from vendor_view (custom_values is not readable on the table).
    const write = row?.id
      ? await supabase.from('vendor').update(payload).eq('id', row.id).select('id')
      : await supabase.from('vendor').insert({ ...payload, tenant_id: tenantId }).select('id')
    const id = write.data?.[0]?.id
    const back = id ? await supabase.from('vendor_view').select('*').eq('id', id) : undefined
    setBusy(false)
    const saved = back?.data?.[0]
    if (write.error || !saved) return setError(vendorError(write.error ?? { code: '42501' }, fields))
    onSaved(saved)
  }

  return (
    <div className="card">
      <form onSubmit={(e) => void submit(e)} noValidate>
        <div className="page-head">
          <h2>{row ? (editable ? v.edit : v.view) : v.add}</h2>
          <div className="spacer" />
          <button className="btn" type="button" onClick={onClose}>
            {v.close}
          </button>
        </div>
        {error && (
          <p className="login-error" role="alert">
            {error}
          </p>
        )}
        <fieldset disabled={!editable} className="form-grid plain">
          <label className="field">
            {v.name}
            <input name="name" defaultValue={row?.name ?? ''} required maxLength={200} />
          </label>
          <label className="field">
            {v.code}
            <input name="code" defaultValue={row?.code ?? ''} maxLength={20} spellCheck={false} aria-describedby="vendor-code-hint" />
            <span id="vendor-code-hint" className="muted hint">
              {v.codeHint}
            </span>
          </label>
          <label className="field">
            {v.phone}
            <input name="phone" type="tel" defaultValue={row?.phone ?? ''} maxLength={50} />
          </label>
          <label className="field">
            {v.email}
            <input name="email" type="email" defaultValue={row?.email ?? ''} maxLength={254} />
          </label>
          <label className="field">
            {v.website}
            <input name="website" defaultValue={row?.website ?? ''} maxLength={200} />
          </label>
          <fieldset className="plain">
            <legend>{v.rolesLabel}</legend>
            {roles.map((r) => (
              <label key={r} className="check">
                <input
                  type="checkbox"
                  checked={picked.includes(r)}
                  onChange={(e) => setPicked((p) => (e.target.checked ? [...p, r] : p.filter((x) => x !== r)))}
                />
                {v.roles[r]}
              </label>
            ))}
          </fieldset>
          {line.map((f) => (
            <CustomInput
              key={f.id}
              field={f}
              name={`custom.${f.key}`}
              text={f.label}
              value={values[`custom.${f.key}`] ?? ''}
              disabled={!canWrite(f) || !f.is_active}
              error={undefined}
              onChange={(n, s) => setValues((old) => ({ ...old, [n]: s }))}
            />
          ))}
          <label className="field">
            {v.address}
            <textarea name="address" rows={3} defaultValue={row?.address ?? ''} maxLength={1000} />
          </label>
          <label className="field">
            {v.notes}
            <textarea name="notes" rows={3} defaultValue={row?.notes ?? ''} maxLength={2000} />
          </label>
          {row && (
            <label className="check">
              <input name="active" type="checkbox" defaultChecked={row.is_active ?? true} aria-describedby="vendor-active-hint" />
              {v.active}
              <span id="vendor-active-hint" className="muted hint">
                {v.activeHint}
              </span>
            </label>
          )}
        </fieldset>
        {editable && (
          <div className="page-head">
            <div className="spacer" />
            <button className="btn" type="button" onClick={onClose}>
              {v.cancel}
            </button>
            <button className="btn btn-main" type="submit" disabled={busy}>
              {v.save}
            </button>
          </div>
        )}
      </form>
      {row?.id && <Contacts tenantId={tenantId} vendorId={row.id} canEdit={can('vendor_core', 'update')} onChange={onContacts} />}
    </div>
  )
}

type ContactValues = Pick<Contact, 'name' | 'title' | 'phone' | 'email' | 'is_primary'>

function Contacts({ tenantId, vendorId, canEdit, onChange }: { tenantId: string; vendorId: string; canEdit: boolean; onChange: () => void }) {
  const c = v.contacts
  const [rows, setRows] = useState<Contact[]>([])
  const [editing, setEditing] = useState<{ row?: Contact }>()
  const [error, setError] = useState<string>()
  const [reload, setReload] = useState(0)

  useEffect(() => {
    let live = true
    void supabase
      .from('vendor_contact')
      .select('*')
      .eq('vendor_id', vendorId)
      .is('deleted_at', null)
      .order('is_primary', { ascending: false })
      .order('name')
      .then(({ data }) => live && setRows(data ?? []))
    return () => {
      live = false
    }
  }, [vendorId, reload])

  async function run(write: PromiseLike<{ data: unknown[] | null; error: DbError | null }>) {
    setError(undefined)
    const { data, error } = await write
    if (error || !data?.length) return setError(vendorError(error ?? { code: '42501' }, []))
    setEditing(undefined)
    setReload((n) => n + 1)
    onChange()
  }

  function submit(e: FormEvent<HTMLFormElement>) {
    e.preventDefault()
    const form = new FormData(e.currentTarget)
    const text = (k: string) => String(form.get(k) ?? '').trim() || null
    const values: ContactValues = { name: text('name') ?? '', title: text('title'), phone: text('phone'), email: text('email'), is_primary: form.get('primary') === 'on' }
    if (!values.name) return setError(v.errors.name)
    void run(
      editing?.row
        ? supabase.from('vendor_contact').update(values).eq('id', editing.row.id).select('id')
        : supabase.from('vendor_contact').insert({ ...values, tenant_id: tenantId, vendor_id: vendorId }).select('id'),
    )
  }

  return (
    <section aria-label={c.title}>
      <div className="page-head">
        <h2>{c.title}</h2>
        <div className="spacer" />
        {canEdit && !editing && (
          <button className="btn" type="button" onClick={() => setEditing({})}>
            {c.add}
          </button>
        )}
      </div>
      {error && (
        <p className="login-error" role="alert">
          {error}
        </p>
      )}
      {editing && (
        <form className="form-grid" onSubmit={submit} noValidate key={editing.row?.id ?? 'new'}>
          <label className="field">
            {c.name}
            <input name="name" defaultValue={editing.row?.name ?? ''} required maxLength={200} />
          </label>
          <label className="field">
            {c.role}
            <input name="title" defaultValue={editing.row?.title ?? ''} maxLength={200} />
          </label>
          <label className="field">
            {c.phone}
            <input name="phone" type="tel" defaultValue={editing.row?.phone ?? ''} maxLength={50} />
          </label>
          <label className="field">
            {c.email}
            <input name="email" type="email" defaultValue={editing.row?.email ?? ''} maxLength={254} />
          </label>
          <label className="check">
            <input name="primary" type="checkbox" defaultChecked={editing.row?.is_primary ?? rows.length === 0} />
            {c.primary}
          </label>
          <div className="page-head">
            <div className="spacer" />
            <button className="btn" type="button" onClick={() => setEditing(undefined)}>
              {v.cancel}
            </button>
            <button className="btn btn-main" type="submit">
              {v.save}
            </button>
          </div>
        </form>
      )}
      <div className="table-wrap">
        <table>
          <tbody>
            {rows.length === 0 && (
              <tr>
                <td className="muted">{c.none}</td>
              </tr>
            )}
            {rows.map((r) => (
              <tr key={r.id}>
                <td>
                  {r.name}
                  {r.is_primary && <span className="tag">{c.primary}</span>}
                  {r.title && <div className="muted">{r.title}</div>}
                </td>
                <td>{r.phone ? <a href={`tel:${r.phone}`}>{r.phone}</a> : '—'}</td>
                <td>{r.email ? <a href={`mailto:${r.email}`}>{r.email}</a> : '—'}</td>
                {canEdit && (
                  <td className="actions">
                    {!r.is_primary && (
                      <button className="btn" type="button" onClick={() => void run(supabase.from('vendor_contact').update({ is_primary: true }).eq('id', r.id).select('id'))}>
                        {c.makePrimary}
                      </button>
                    )}
                    <button className="btn" type="button" onClick={() => setEditing({ row: r })}>
                      {c.edit}
                    </button>
                    <button
                      className="btn"
                      type="button"
                      onClick={() => void run(supabase.from('vendor_contact').update({ deleted_at: new Date().toISOString() }).eq('id', r.id).select('id'))}
                    >
                      {c.remove}
                    </button>
                  </td>
                )}
              </tr>
            ))}
          </tbody>
        </table>
      </div>
    </section>
  )
}

function VendorFieldsCard({ tenantId, fields, domains, onSaved }: { tenantId: string; fields: Field[]; domains: Domain[]; onSaved: () => void }) {
  const f = v.fields
  const [editing, setEditing] = useState<{ row?: Field }>()
  const [error, setError] = useState<string>()
  const domainLabel = (id: string) => {
    const code = domains.find((d) => d.id === id)?.code ?? ''
    return (t.categories.domains as Record<string, string>)[code] ?? code
  }

  async function save(write: PromiseLike<{ data: unknown[] | null; error: DbError | null }>) {
    setError(undefined)
    const { data, error } = await write
    if (error || !data?.length) {
      setError(errorMessage(error ?? { code: '42501' }, t.categories.errors.duplicateKey))
      return false
    }
    setEditing(undefined)
    onSaved()
    return true
  }

  return (
    <div className="card list">
      <div className="page-head">
        <div>
          <h2>{f.title}</h2>
          <span className="muted">{f.intro}</span>
        </div>
        <div className="spacer" />
        {!editing && (
          <button className="btn" type="button" onClick={() => setEditing({})}>
            {f.add}
          </button>
        )}
      </div>
      {error && (
        <p className="login-error" role="alert">
          {error}
        </p>
      )}
      {editing && (
        <FieldForm
          row={editing.row}
          domains={domains}
          onCancel={() => setEditing(undefined)}
          onError={setError}
          onSave={(values) =>
            save(
              editing.row
                ? supabase.from('field_definition').update(values).eq('id', editing.row.id).select('id')
                : supabase
                    .from('field_definition')
                    .insert({ ...values, key: values.key ?? '', type: values.type ?? 'text', tenant_id: tenantId, entity: 'vendor', category_id: null, sort_order: fields.length })
                    .select('id'),
            )
          }
        />
      )}
      <div className="table-wrap">
        <table>
          <thead>
            <tr>
              <th>{t.categories.col.field}</th>
              <th>{t.categories.col.type}</th>
              <th>{t.categories.col.domain}</th>
              <th aria-label={t.categories.col.actions} />
            </tr>
          </thead>
          <tbody>
            {fields.length === 0 && (
              <tr>
                <td colSpan={4} className="muted">
                  {f.none}
                </td>
              </tr>
            )}
            {fields.map((row) => (
              <tr key={row.id}>
                <td>
                  {row.label} <code className="muted">{row.key}</code>
                  {row.is_required && <span className="tag">{t.categories.required}</span>}
                  {!row.is_active && <span className="tag">{t.categories.inactive}</span>}
                </td>
                <td>{(t.categories.types as Record<string, string>)[row.type] ?? row.type}</td>
                <td>{domainLabel(row.security_domain_id)}</td>
                <td className="actions">
                  <button className="btn" type="button" onClick={() => setEditing({ row })}>
                    {f.edit}
                  </button>
                </td>
              </tr>
            ))}
          </tbody>
        </table>
      </div>
    </div>
  )
}
