import { useEffect, useState, type FormEvent, type ReactNode } from 'react'
import { useNavigate, useParams } from 'react-router'
import { t } from './i18n'
import { loadStatuses, statusName, type Status } from './Assets'
import { supabase } from './supabase'
import { buildTree, lineage } from './tree'
import type { Json, Tables, TablesInsert } from './types/database'

type Asset = Tables<'asset_view'>
type Field = Tables<'field_definition'>
type Category = Pick<Tables<'asset_category'>, 'id' | 'parent_id' | 'name' | 'is_active'>
type Place = { id: string; parent_id: string | null; name: string; active: boolean }
type Option = { code: string; label: string; is_active: boolean }
type Can = (domain: string, operation: string) => boolean
export type Errors = Record<string, string>

// System text fields; each is also a 2.5 rule name. Custom fields are keyed `custom.<key>`.
const textFields = ['serial_number', 'manufacturer', 'model'] as const
const systemRuleNames = [...textFields, 'location', 'purchase_date', 'purchase_value', 'in_service_date']
const e = t.assetForm.errors

// Fields that apply to the category (G3): every-asset fields, then furthest ancestor first, each by sort_order.
// Inactive fields are hidden on forms; their values stay on the record.
export function lineFields(fields: Field[], categories: Category[], categoryId: string): Field[] {
  const line = categoryId ? lineage(categories, categoryId) : []
  const rank = (f: Field) => (f.category_id === null ? line.length : line.indexOf(f.category_id))
  return fields
    .filter((f) => f.is_active && !f.deleted_at && (f.category_id === null || line.includes(f.category_id)))
    .sort((a, b) => rank(b) - rank(a) || a.sort_order - b.sort_order)
}

// Same rule as the check_asset_values trigger (data-model-goal3 §4.1.6), so the marker and the
// database agree: M2 skips what the user cannot write; location changes only by transfer (3.5).
export function requiredNames(opts: { line: Field[]; tenantRequired: string[]; editing: boolean; canWrite: (f: Field) => boolean; canMoney: boolean }): Set<string> {
  const out = new Set(['name', 'category_id'])
  for (const r of opts.tenantRequired) {
    if (r === 'location' && opts.editing) continue
    if (r === 'purchase_value' && !opts.canMoney) continue
    out.add(r === 'location' ? 'location_id' : r)
  }
  for (const f of opts.line) if (f.is_required && opts.canWrite(f)) out.add(`custom.${f.key}`)
  return out
}

// Form text back to a JSON value of the field's type; undefined when the text is not one.
function customValue(f: Field, s: string): Json | undefined {
  if (f.type === 'number') return s.trim() === '' || !Number.isFinite(Number(s)) ? undefined : Number(s)
  if (f.type === 'boolean') return s === 'true' ? true : s === 'false' ? false : undefined
  if (f.type === 'date') return /^\d{4}-\d{2}-\d{2}$/.test(s) ? s : undefined
  return s
}

const asText = (v: Json | undefined) => (v === undefined || v === null ? '' : String(v))

// Fast feedback only. The database checks the same and is the truth.
export function validate(values: Record<string, string>, required: Set<string>, line: Field[]): Errors {
  const out: Errors = {}
  for (const name of required) if (!values[name]?.trim()) out[name] = e.required
  const qty = values.quantity ?? ''
  if (!/^\d+$/.test(qty) || Number(qty) < 1) out.quantity = e.quantity
  if (values.purchase_value && !(Number(values.purchase_value) >= 0)) out.purchase_value = e.money
  for (const f of line) {
    const s = values[`custom.${f.key}`] ?? ''
    if (s.trim() && customValue(f, s) === undefined) out[`custom.${f.key}`] = f.type === 'number' ? e.number : e.invalid
  }
  return out
}

// custom_values to send: the stored visible values (asset_view already removed hidden keys) with the
// user's edits to fields they can write. Untouched keys keep their stored JSON, so read-only fields
// and fields of a former category go back as they were, and hidden keys are never sent.
export function customPayload(stored: Record<string, Json | undefined>, values: Record<string, string>, line: Field[], canWrite: (f: Field) => boolean) {
  const out = { ...stored }
  for (const f of line) {
    const s = values[`custom.${f.key}`] ?? ''
    if (!canWrite(f) || s === asText(stored[f.key])) continue
    const v = s.trim() === '' ? undefined : customValue(f, s)
    if (v === undefined) delete out[f.key]
    else out[f.key] = v
  }
  return out as { [key: string]: Json }
}

// A database error to a message on the field it is about (or on the form, key '').
export function fieldErrors(error: { code?: string; message?: string }): Errors {
  const m = error.message ?? ''
  const custom = /custom field (\w+)/.exec(m)?.[1]
  if (error.code === '23502' && m.startsWith('missing mandatory fields: ')) {
    // shortcut: a custom key equal to a 2.5 rule name maps to the system field; fine while keys stay distinct.
    const names = m.slice('missing mandatory fields: '.length).split(', ')
    return Object.fromEntries(
      names.map((n) => [systemRuleNames.includes(n) ? (n === 'location' ? 'location_id' : n) : `custom.${n}`, e.required]),
    )
  }
  if (custom) {
    if (error.code === '42501') return { [`custom.${custom}`]: e.noPermissionField }
    if (m.includes('does not apply')) return { [`custom.${custom}`]: e.notInCategory }
    if (m.includes('inactive')) return { [`custom.${custom}`]: e.fieldInactive }
    return { [`custom.${custom}`]: e.invalid }
  }
  if (m.includes('purchase value') || m.includes('purchase_value')) return { purchase_value: error.code === '42501' ? e.noPermissionField : e.money }
  if (m.includes('asset tag') || m.includes('tag_check')) return { tag: error.code === '42501' ? e.noPermissionField : e.tagInvalid }
  if (m.includes('tag pattern needs')) return { tag: e.tagNeedsCode }
  if (error.code === '23505') return { tag: e.tagDuplicate }
  if (m.includes('inside itself')) return { parent: e.parentCycle }
  if (m.includes('5 levels')) return { parent: e.parentDepth }
  if (m.includes('quantity')) return { quantity: e.quantity }
  if (m.includes('status set')) return { status_id: e.statusNotInSet }
  if (m.includes('category')) return { category_id: e.categoryInactive }
  if (m.includes('location')) return { location_id: e.locationInactive }
  if (m.includes('parent_asset_id')) return { parent: e.parentNotFound }
  if (error.code === '42501') return { '': e.noPermission }
  return { '': e.generic }
}

export function AssetFormPage({ tenantId, can }: { tenantId: string; can: Can }) {
  const { assetId } = useParams()
  const editing = !!assetId
  const navigate = useNavigate()
  const [asset, setAsset] = useState<Asset>()
  const [parentTag, setParentTag] = useState('')
  const [fields, setFields] = useState<Field[]>([])
  const [domains, setDomains] = useState<Record<string, string>>({})
  const [categories, setCategories] = useState<Category[]>([])
  const [places, setPlaces] = useState<Place[]>([])
  const [tenant, setTenant] = useState<{ currency_code: string; required_asset_fields: string[] }>()
  const [values, setValues] = useState<Record<string, string>>()
  const [errors, setErrors] = useState<Errors>({})
  const [statuses, setStatuses] = useState<Status[]>([])
  // Create only: the statuses a new asset of the chosen category may start in (3.7).
  const [startIds, setStartIds] = useState<string[]>([])
  const [saving, setSaving] = useState(false)

  useEffect(() => {
    let live = true
    void Promise.all([
      supabase.from('tenant').select('currency_code, required_asset_fields').eq('id', tenantId),
      supabase.from('asset_category').select('id, parent_id, name, is_active').is('deleted_at', null),
      supabase.from('location').select('id, parent_id, name, active').is('deleted_at', null),
      supabase.from('field_definition').select('*').eq('entity', 'asset').is('deleted_at', null),
      supabase.rpc('field_domains', { p_entity: 'asset' }),
      assetId ? supabase.from('asset_view').select('*').eq('id', assetId) : Promise.resolve({ data: [], error: null }),
      loadStatuses(),
    ]).then(async ([tn, c, l, f, d, a, st]) => {
      const row = a.data?.[0]
      const parent = row?.parent_asset_id ? (await supabase.from('asset_view').select('tag').eq('id', row.parent_asset_id)).data?.[0]?.tag : undefined
      if (!live) return
      const ten = tn.data?.[0]
      if (tn.error || c.error || l.error || f.error || (assetId && !row) || !ten) setErrors({ '': e.load })
      setTenant(ten)
      setCategories(c.data ?? [])
      setPlaces(l.data ?? [])
      setFields(f.data ?? [])
      setDomains(Object.fromEntries((d.data ?? []).map((x) => [x.id, x.code])))
      setStatuses(st.data ?? [])
      setAsset(row)
      setParentTag(parent ?? '')
      const stored = (row?.custom_values ?? {}) as Record<string, Json>
      setValues({
        name: row?.name ?? '',
        tag: row?.tag ?? '',
        category_id: row?.category_id ?? '',
        location_id: row?.location_id ?? '',
        status_id: row?.status_id ?? '',
        quantity: String(row?.quantity ?? 1),
        parent: parent ?? '',
        criticality: row?.criticality ?? '',
        serial_number: row?.serial_number ?? '',
        manufacturer: row?.manufacturer ?? '',
        model: row?.model ?? '',
        purchase_date: row?.purchase_date ?? '',
        in_service_date: row?.in_service_date ?? '',
        purchase_value: row?.purchase_value == null ? '' : String(row.purchase_value),
        purchase_currency: row?.purchase_currency ?? ten?.currency_code ?? '',
        ...Object.fromEntries(Object.entries(stored).map(([k, v]) => [`custom.${k}`, asText(v)])),
      })
    })
    return () => {
      live = false
    }
  }, [tenantId, assetId])

  // The category's status set (inherited), narrowed to the insert statuses (data-model-goal3 §3, §18.2).
  // The first Active one is preselected; a choice the new category does not offer is replaced.
  const categoryId = values?.category_id
  useEffect(() => {
    if (editing || categoryId === undefined || !statuses.length) return
    let live = true
    void supabase.rpc('category_statuses', categoryId ? { p_category_id: categoryId } : {}).then(({ data }) => {
      if (!live) return
      const start = (data ?? []).filter((id) => ['in_stock', 'active'].includes(statuses.find((s) => s.id === id)?.system_status ?? ''))
      setStartIds(start)
      const first = start.find((id) => statuses.find((s) => s.id === id)?.system_status === 'active') ?? start[0] ?? ''
      setValues((v) => (v && !start.includes(v.status_id ?? '') ? { ...v, status_id: first } : v))
    })
    return () => {
      live = false
    }
  }, [editing, categoryId, statuses])

  const canSave = can('asset_core', editing ? 'update' : 'create')
  const canTag = can('asset_core', 'set_tag')
  const seeMoney = can('asset_financials', 'view')
  const canMoney = seeMoney && can('asset_financials', 'update')
  const canSee = (f: Field) => can(domains[f.security_domain_id] ?? '', 'view')
  const canWrite = (f: Field) => canSave && can(domains[f.security_domain_id] ?? '', 'update')
  const line = values ? lineFields(fields, categories, values.category_id ?? '').filter(canSee) : []
  const required = requiredNames({ line, tenantRequired: tenant?.required_asset_fields ?? [], editing, canWrite, canMoney })
  const title = editing ? t.assetForm.editTitle : t.assetForm.addTitle

  function set(name: string, value: string) {
    setValues((v) => ({ ...v, [name]: value }))
    setErrors((er) => Object.fromEntries(Object.entries(er).filter(([k]) => k !== name)))
  }

  async function submit(ev: FormEvent<HTMLFormElement>) {
    ev.preventDefault()
    if (!values) return
    const found = validate(values, required, line)
    if (Object.keys(found).length) return setErrors(found)
    setSaving(true)
    const tagText = values.parent?.trim().toUpperCase() ?? ''
    let parentId = asset?.parent_asset_id ?? null
    if (tagText !== parentTag) {
      parentId = tagText ? ((await supabase.from('asset_view').select('id').eq('tag', tagText)).data?.[0]?.id ?? '') : null
      if (parentId === '') {
        setSaving(false)
        return setErrors({ parent: e.parentNotFound })
      }
    }
    const text = (name: string) => values[name]?.trim() || null
    // Empty means generated (insert) or unchanged (update), so it is left out.
    const tag = canTag ? text('tag')?.toUpperCase() : undefined
    const row = {
      name: values.name?.trim() ?? '',
      category_id: values.category_id ?? '',
      quantity: Number(values.quantity),
      parent_asset_id: parentId,
      criticality: text('criticality'),
      serial_number: text('serial_number'),
      manufacturer: text('manufacturer'),
      model: text('model'),
      purchase_date: text('purchase_date'),
      in_service_date: text('in_service_date'),
      custom_values: customPayload((asset?.custom_values ?? {}) as Record<string, Json>, values, line, canWrite),
      // Left out when not editable: an update writes only the columns it names, so hidden money stays.
      ...(canMoney && { purchase_value: text('purchase_value') === null ? null : Number(values.purchase_value), purchase_currency: values.purchase_value?.trim() ? text('purchase_currency') : null }),
      ...(tag && { tag }),
    }
    const { error } = assetId
      ? await supabase.from('asset').update(row).eq('id', assetId)
      : await supabase.from('asset').insert({
          ...row,
          id: crypto.randomUUID(),
          tenant_id: tenantId,
          location_id: text('location_id'),
          status_id: values.status_id ?? '',
          // tag may be left out: the assign_asset_tag trigger fills it (A1).
        } as TablesInsert<'asset'>)
    setSaving(false)
    if (error) return setErrors(fieldErrors(error))
    void navigate('/assets')
  }

  const label = (name: string, text: string) => (required.has(name) ? `${text} *` : text)
  const err = (name: string) =>
    errors[name] && (
      <span id={`${name}-error`} className="field-error" role="alert">
        {errors[name]}
      </span>
    )
  const input = (name: string, text: string, props: { type?: string; disabled?: boolean; hint?: string } = {}) => (
    <Labeled key={name} name={name} text={label(name, text)} hint={props.hint} error={err(name)}>
      <input
        name={name}
        type={props.type ?? 'text'}
        value={values?.[name] ?? ''}
        disabled={props.disabled}
        aria-invalid={!!errors[name]}
        onChange={(ev) => set(name, ev.target.value)}
      />
    </Labeled>
  )
  const treeSelect = (name: string, text: string, rows: { id: string; parent_id: string | null; name: string; on: boolean }[], disabled: boolean, hint?: string) => (
    <Labeled name={name} text={label(name, text)} hint={hint} error={err(name)}>
      <select name={name} value={values?.[name] ?? ''} disabled={disabled} aria-invalid={!!errors[name]} onChange={(ev) => set(name, ev.target.value)}>
        <option value="">{t.assetForm.none}</option>
        {buildTree(rows).map(({ row, depth }) => (
          // Inactive ones keep the tree shape and the current value, but cannot be picked (the trigger refuses them).
          <option key={row.id} value={row.id} disabled={!row.on && row.id !== values?.[name]}>
            {`${'— '.repeat(depth)}${row.name}`}
          </option>
        ))}
      </select>
    </Labeled>
  )

  return (
    <>
      <title>{`${title} · ${t.app.name}`}</title>
      <div className="page-head">
        <div>
          <h1>{title}</h1>
          {asset && <span className="muted">{asset.tag}</span>}
        </div>
      </div>
      {!canSave && <p className="muted">{t.assetForm.noAccess}</p>}
      {errors[''] && (
        <p className="login-error" role="alert">
          {errors['']}
        </p>
      )}
      {values && canSave && (
        <form className="stack" onSubmit={(ev) => void submit(ev)} noValidate>
          <fieldset className="card">
            <h2>{t.assetForm.details}</h2>
            <div className="form-grid">
              {input('name', t.assetForm.name)}
              {input('tag', t.assetForm.tag, { disabled: !canTag, hint: canTag ? t.assetForm.tagHint : editing ? undefined : t.assetForm.tagGenerated })}
              {treeSelect('category_id', t.assetForm.category, categories.map((c) => ({ ...c, on: c.is_active })), false)}
              {treeSelect('location_id', t.assetForm.location, places.map((p) => ({ ...p, on: p.active })), editing, editing ? t.assetForm.locationHint : undefined)}
              <Labeled name="status_id" text={label('status_id', t.assetForm.status)} hint={editing ? t.assetForm.statusHint : undefined} error={err('status_id')}>
                <select name="status_id" value={values.status_id} disabled={editing} aria-invalid={!!errors.status_id} onChange={(ev) => set('status_id', ev.target.value)}>
                  {(editing ? [values.status_id ?? ''] : startIds).map((s) => (
                    <option key={s} value={s}>
                      {statusName(statuses, s, asset?.status)}
                    </option>
                  ))}
                </select>
              </Labeled>
              {input('quantity', t.assetForm.quantity, { type: 'number' })}
              {input('parent', t.assetForm.parent, { hint: t.assetForm.parentHint })}
              <Labeled name="criticality" text={t.assetForm.criticality}>
                <select name="criticality" value={values.criticality} onChange={(ev) => set('criticality', ev.target.value)}>
                  <option value="">{t.assetForm.none}</option>
                  {['A', 'B', 'C'].map((c) => (
                    <option key={c}>{c}</option>
                  ))}
                </select>
              </Labeled>
            </div>
          </fieldset>
          <fieldset className="card">
            <h2>{t.assetForm.makeModel}</h2>
            <div className="form-grid">
              {textFields.map((name) => input(name, t.settings.assetFields[name]))}
              {input('in_service_date', t.settings.assetFields.in_service_date, { type: 'date' })}
            </div>
          </fieldset>
          <fieldset className="card">
            <h2>{t.assetForm.purchase}</h2>
            <div className="form-grid">
              {input('purchase_date', t.settings.assetFields.purchase_date, { type: 'date' })}
              {seeMoney && input('purchase_value', t.settings.assetFields.purchase_value, { type: 'number', disabled: !canMoney })}
              {seeMoney && (
                <Labeled name="purchase_currency" text={t.assetForm.currency}>
                  <select name="purchase_currency" value={values.purchase_currency} disabled={!canMoney} onChange={(ev) => set('purchase_currency', ev.target.value)}>
                    {[...new Set([values.purchase_currency ?? '', ...Intl.supportedValuesOf('currency')])].filter(Boolean).map((c) => (
                      <option key={c}>{c}</option>
                    ))}
                  </select>
                </Labeled>
              )}
              {/* A5: vendors arrive in Goal 4 (4.1 adds the columns). */}
              <Labeled name="oem_vendor" text={t.assetForm.oemVendor} hint={t.assetForm.vendorHint}>
                <input name="oem_vendor" disabled />
              </Labeled>
              <Labeled name="om_vendor" text={t.assetForm.omVendor}>
                <input name="om_vendor" disabled />
              </Labeled>
            </div>
          </fieldset>
          {line.length > 0 && (
            <fieldset className="card">
              <h2>{t.assetForm.fields}</h2>
              <div className="form-grid">
                {line.map((f) => (
                  <CustomInput key={f.id} field={f} name={`custom.${f.key}`} text={label(`custom.${f.key}`, f.unit ? `${f.label} (${f.unit})` : f.label)} value={values[`custom.${f.key}`] ?? ''} disabled={!canWrite(f)} error={err(`custom.${f.key}`)} onChange={set} />
                ))}
              </div>
            </fieldset>
          )}
          <div className="page-head">
            <span className="muted hint">{t.assetForm.requiredHint}</span>
            <div className="spacer" />
            <button className="btn" type="button" onClick={() => void navigate('/assets')}>
              {t.assetForm.cancel}
            </button>
            <button className="btn btn-main" type="submit" disabled={saving}>
              {saving ? t.assetForm.saving : t.assetForm.save}
            </button>
          </div>
        </form>
      )}
    </>
  )
}

function Labeled({ name, text, hint, error, children }: { name: string; text: string; hint?: string; error?: ReactNode; children: ReactNode }) {
  return (
    <label className="field" data-field={name}>
      {text}
      {children}
      {hint && <span className="muted hint">{hint}</span>}
      {error}
    </label>
  )
}

function CustomInput({ field: f, name, text, value, disabled, error, onChange }: { field: Field; name: string; text: string; value: string; disabled: boolean; error: ReactNode; onChange: (name: string, v: string) => void }) {
  const change = (ev: { target: { value: string } }) => onChange(name, ev.target.value)
  if (f.type === 'list' || f.type === 'boolean') {
    const options =
      f.type === 'boolean'
        ? [
            { code: 'true', label: t.categories.yes },
            { code: 'false', label: t.categories.no },
          ]
        : (Array.isArray(f.options) ? (f.options as Option[]) : []).filter((o) => o.is_active || o.code === value)
    return (
      <Labeled name={name} text={text} error={error}>
        <select name={name} value={value} disabled={disabled} onChange={change}>
          <option value="">{t.assetForm.none}</option>
          {options.map((o) => (
            <option key={o.code} value={o.code}>
              {o.label}
            </option>
          ))}
        </select>
      </Labeled>
    )
  }
  return (
    <Labeled name={name} text={text} error={error}>
      <input name={name} type={f.type === 'number' ? 'number' : f.type === 'date' ? 'date' : 'text'} step={f.type === 'number' ? 'any' : undefined} value={value} disabled={disabled} onChange={change} />
    </Labeled>
  )
}
