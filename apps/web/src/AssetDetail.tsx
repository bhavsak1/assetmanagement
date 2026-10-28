import { useEffect, useState, type FormEvent, type ReactNode } from 'react'
import { Link, useParams } from 'react-router'
import { AttachmentsTab } from './Attachments'
import { CoverageCard, CoverageTab } from './Coverage'
import { lineFields } from './AssetForm'
import { ObligationsCard, ObligationsTab } from './Obligations'
import { ServiceHistoryTab } from './Service'
import { loadStatuses, statusName, StatusTag, type Status } from './Assets'
import { t } from './i18n'
import { supabase } from './supabase'
import { buildTree, lineage } from './tree'
import type { Database, Json, Tables } from './types/database'

type Asset = Tables<'asset_view'>
type Field = Tables<'field_definition'>
type Node = { id: string; parent_id: string | null; name: string }
type Category = Node & { is_active: boolean }
type Place = Node & { active: boolean }
export type History = Database['public']['Functions']['asset_history']['Returns'][number]
export type Change = { field: string; from?: string; to?: string; hidden?: boolean }
type Can = (domain: string, operation: string) => boolean

const PAGE = 50
const d = t.assetDetail
const h = d.history
// Shown in the Audit tab under these labels; custom keys use their field's label.
const labels: Record<string, string> = {
  name: t.assetForm.name,
  tag: t.assetForm.tag,
  category_id: t.assetForm.category,
  location_id: t.assetForm.location,
  status: t.assetForm.status,
  status_id: t.assetForm.status,
  status_reason: d.statusReason,
  location_reason: d.transferReason,
  quantity: t.assetForm.quantity,
  parent_asset_id: t.assetForm.parent,
  criticality: t.assetForm.criticality,
  purchase_currency: t.assetForm.currency,
  oem_vendor_id: t.assetForm.oemVendor,
  om_vendor_id: t.assetForm.omVendor,
  ...t.settings.assetFields,
}
// Bookkeeping columns, not shown as changes.
const skip = new Set(['id', 'tenant_id', 'created_at', 'updated_at', 'created_by', 'updated_by', 'status_changed_at', 'location_changed_at', 'deleted_at', 'custom_values'])
const obj = (j: Json | undefined) => (j && typeof j === 'object' && !Array.isArray(j) ? j : {})
const same = (a: Json | undefined, b: Json | undefined) => JSON.stringify(a ?? null) === JSON.stringify(b ?? null)

// One history row to readable lines: each changed field old → new, then the ones masked for this user.
export function changes(row: History, label: (key: string) => string, show: (key: string, v: Json | undefined) => string): Change[] {
  const o = obj(row.old_data)
  const n = obj(row.new_data)
  const oc = obj(o.custom_values)
  const nc = obj(n.custom_values)
  const out: Change[] = []
  // The tenant status (3.7) says it better than the system status in the same row.
  const hide = (k: string) => skip.has(k) || (k === 'status' && 'status_id' in n)
  for (const k of new Set([...Object.keys(o), ...Object.keys(n)]))
    if (!hide(k) && !same(o[k], n[k])) out.push({ field: label(k), from: show(k, o[k]), to: show(k, n[k]) })
  for (const k of new Set([...Object.keys(oc), ...Object.keys(nc)]))
    if (!same(oc[k], nc[k])) out.push({ field: label(`custom.${k}`), from: show(`custom.${k}`, oc[k]), to: show(`custom.${k}`, nc[k]) })
  for (const k of row.hidden_fields) out.push({ field: label(k), hidden: true })
  return out
}

export function historyTitle(row: History): string {
  if (row.action === 'insert') return h.created
  if (row.action === 'soft_delete') return h.deleted
  const n = obj(row.new_data)
  if ('status_changed_at' in n) return h.statusChanged
  return 'location_reason' in n ? h.transferred : h.updated
}

// Keyset cursor for Load more: the last row shown, when the page came back full.
export function moreCursor(rows: History[]): { p_before: string; p_before_id: string } | undefined {
  const last = rows[PAGE - 1]
  return rows.length > PAGE && last ? { p_before: last.occurred_at, p_before_id: last.id } : undefined
}

const statusLabel = (s: string) => (t.assets.statuses as Record<string, string>)[s] ?? s
const a = d.actions

// A transfer or status action error to a message (codes from transfer_asset and change_asset_status).
export function actionError(e: { code?: string; message?: string }): string {
  if (e.code === '42501') return a.errors.noPermission
  if (e.code === 'P0002') return a.errors.notFound
  if (e.code === '23514') return a.errors.locationInactive
  if (e.code === '23502') return a.errors.reasonRequired
  if (e.code === '22023') return e.message?.includes('already at') ? a.errors.sameLocation : e.message?.includes('cannot be transferred') ? a.errors.disposed : a.errors.statusNotAllowed
  return a.errors.failed
}

export function AssetDetailPage({ can }: { can: Can }) {
  const { assetId = '' } = useParams()
  const [asset, setAsset] = useState<Asset | null>()
  const [tags, setTags] = useState<Record<string, string>>({})
  const [children, setChildren] = useState<Pick<Asset, 'id' | 'tag' | 'name'>[]>([])
  const [categories, setCategories] = useState<Category[]>([])
  const [places, setPlaces] = useState<Place[]>([])
  const [fields, setFields] = useState<Field[]>([])
  const [domains, setDomains] = useState<Record<string, string>>({})
  const [timeZone, setTimeZone] = useState<string>()
  const [statuses, setStatuses] = useState<Status[]>([])
  const [vendors, setVendors] = useState<{ id: string; name: string; is_active: boolean }[]>([])
  // Change status offers what the database allows now (allowed_asset_statuses, 3.7).
  const [targets, setTargets] = useState<string[]>([])
  const [tab, setTab] = useState<'overview' | 'coverage' | 'obligations' | 'service' | 'attachments' | 'audit'>('overview')
  const [dialog, setDialog] = useState<'transfer' | 'retire' | 'status'>()
  // Bumped after an action: reloads the asset and the Audit tab.
  const [version, setVersion] = useState(0)

  useEffect(() => {
    let live = true
    void Promise.all([
      supabase.from('asset_view').select('*').eq('id', assetId),
      supabase.from('asset_view').select('id, tag, name').eq('parent_asset_id', assetId).order('tag'),
      supabase.from('asset_category').select('id, parent_id, name, is_active').is('deleted_at', null),
      supabase.from('location').select('id, parent_id, name, active').is('deleted_at', null),
      supabase.from('field_definition').select('*').eq('entity', 'asset').is('deleted_at', null),
      supabase.rpc('field_domains', { p_entity: 'asset' }),
      supabase.from('tenant').select('time_zone'),
      loadStatuses(),
      supabase.rpc('allowed_asset_statuses', { p_asset_id: assetId }),
      supabase.from('vendor_view').select('id, name, is_active'),
    ]).then(async ([a, ch, c, l, f, dm, tn, st, al, vn]) => {
      const row = a.data?.[0] ?? null
      const parent = row?.parent_asset_id ? (await supabase.from('asset_view').select('id, tag').eq('id', row.parent_asset_id)).data?.[0] : undefined
      if (!live) return
      setAsset(row)
      setChildren(ch.data ?? [])
      setCategories(c.data ?? [])
      setPlaces(l.data ?? [])
      setFields(f.data ?? [])
      setDomains(Object.fromEntries((dm.data ?? []).map((x) => [x.id, x.code])))
      setTimeZone(tn.data?.[0]?.time_zone)
      setStatuses(st.data ?? [])
      setTargets(al.data ?? [])
      setVendors((vn.data ?? []).map((x) => ({ id: x.id ?? '', name: x.name ?? '', is_active: x.is_active ?? false })))
      if (parent?.id && parent.tag) setTags((m) => ({ ...m, [parent.id as string]: parent.tag as string }))
    })
    return () => {
      live = false
    }
  }, [assetId, version])

  if (asset === undefined) return <p className="muted" role="status">{d.loading}</p>
  if (asset === null) return <p className="muted">{d.notFound}</p>

  const seeMoney = can('asset_financials', 'view')
  const canSee = (f: Field) => can(domains[f.security_domain_id] ?? '', 'view')
  const path = (rows: Node[], id: string | null) =>
    id
      ? lineage(rows, id)
          .reverse()
          .map((x) => rows.find((r) => r.id === x)?.name)
          .join(' › ') || '—'
      : '—'
  const line = lineFields(fields, categories, asset.category_id ?? '')
  const custom = obj(asset.custom_values)
  const fieldOf = (key: string) => fields.find((f) => f.key === key)
  // A value as text: ids to names and tags, statuses and list codes to labels.
  const show = (key: string, v: Json | undefined): string => {
    if (v === undefined || v === null || v === '') return '—'
    const s = String(v)
    if (key === 'category_id') return path(categories, s)
    if (key === 'location_id') return path(places, s)
    if (key === 'parent_asset_id') return tags[s] ?? '—'
    if (key === 'status') return statusLabel(s)
    if (key === 'status_id') return statusName(statuses, s)
    // A merged (soft-deleted) vendor is not in vendor_view.
    if (key === 'oem_vendor_id' || key === 'om_vendor_id') return vendors.find((x) => x.id === s)?.name ?? (can('vendor_core', 'view') ? d.formerVendor : d.hidden)
    if (typeof v === 'boolean') return v ? t.categories.yes : t.categories.no
    const f = key.startsWith('custom.') ? fieldOf(key.slice(7)) : undefined
    const option = f?.type === 'list' && Array.isArray(f.options) ? (f.options as { code: string; label: string }[]).find((o) => o.code === s) : undefined
    return option?.label ?? s
  }
  const label = (key: string) => (key.startsWith('custom.') ? (fieldOf(key.slice(7))?.label ?? key.slice(7)) : (labels[key] ?? key))
  const money = !seeMoney ? <Hidden /> : asset.purchase_value == null ? '—' : `${Number(asset.purchase_value).toLocaleString()} ${asset.purchase_currency ?? ''}`
  const parentTag = asset.parent_asset_id ? tags[asset.parent_asset_id] : undefined
  const tabs = ['overview', 'coverage', 'obligations', 'service', 'bom', 'attachments', 'audit'] as const
  const live = asset.status !== 'disposed'
  const tag = asset.tag ?? ''
  const id = asset.id ?? assetId
  const close = () => setDialog(undefined)
  const done = () => {
    close()
    setVersion((v) => v + 1)
  }

  return (
    <>
      <title>{`${asset.name ?? t.pages.assetDetail} · ${t.app.name}`}</title>
      <div className="page-head">
        <div>
          <span className="muted">
            <Link className="row-link" to="/assets">
              {t.pages.assets}
            </Link>
            {` / ${categories.find((c) => c.id === asset.category_id)?.name ?? ''}`}
          </span>
          <h1>
            {asset.name}
            <StatusTag statuses={statuses} id={asset.status_id} system={asset.status} />
          </h1>
        </div>
        <div className="spacer" />
        {can('asset_core', 'view') && (
          <Link className="btn" to={`/assets/${asset.id}/label`}>
            {d.label.button}
          </Link>
        )}
        {live && can('asset_lifecycle', 'execute') && (
          <>
            <button className="btn" type="button" onClick={() => setDialog('transfer')}>
              {a.transfer}
            </button>
            <button className="btn" type="button" onClick={() => setDialog('retire')}>
              {a.retire}
            </button>
          </>
        )}
        {targets.length > 0 && (
          <button className="btn" type="button" onClick={() => setDialog('status')}>
            {a.changeStatus}
          </button>
        )}
        {can('asset_core', 'update') && (
          <Link className="btn btn-main" to={`/assets/${asset.id}/edit`}>
            {d.edit}
          </Link>
        )}
      </div>
      <div className="tabs" role="tablist">
        {tabs.map((k) =>
          k === 'overview' || k === 'audit' || (k === 'coverage' && can('coverage_contract', 'view')) || (k === 'obligations' && can('obligation', 'view')) || (k === 'service' && can('service_record', 'view')) || (k === 'attachments' && can('asset_attachment', 'view')) ? (
            <button key={k} type="button" role="tab" aria-selected={tab === k} className={tab === k ? 'on' : ''} onClick={() => setTab(k)}>
              {d.tabs[k]}
            </button>
          ) : (
            <button key={k} type="button" role="tab" disabled title={d.laterHint}>
              {d.tabs[k]}
            </button>
          ),
        )}
      </div>
      {tab === 'overview' ? (
        <div className="stack detail">
          <section className="card">
            <h2>{t.assetForm.details}</h2>
            <dl className="kv">
              <Row k={t.assetForm.tag}>
                <b>{asset.tag}</b>
              </Row>
              <Row k={t.assetForm.category}>{path(categories, asset.category_id)}</Row>
              <Row k={t.assetForm.location}>{path(places, asset.location_id)}</Row>
              <Row k={d.makeModel}>{[asset.manufacturer, asset.model].filter(Boolean).join(' ') || '—'}</Row>
              <Row k={t.settings.assetFields.serial_number}>{asset.serial_number ?? '—'}</Row>
              <Row k={d.purchase}>
                {asset.purchase_date ?? '—'} · {money}
              </Row>
              <Row k={t.settings.assetFields.in_service_date}>{asset.in_service_date ?? '—'}</Row>
              <Row k={t.assetForm.criticality}>{asset.criticality ?? '—'}</Row>
              <Row k={t.assetForm.quantity}>{asset.quantity}</Row>
              {asset.status_reason && <Row k={d.statusReason}>{asset.status_reason}</Row>}
              {asset.location_reason && <Row k={d.transferReason}>{asset.location_reason}</Row>}
              <Row k={t.assetForm.parent}>{parentTag ? <Link className="row-link" to={`/assets/${asset.parent_asset_id}`}>{parentTag}</Link> : '—'}</Row>
              <Row k={d.children}>
                {children.length
                  ? children.map((c, i) => (
                      <span key={c.id}>
                        {i > 0 && ', '}
                        <Link className="row-link" to={`/assets/${c.id}`}>
                          {c.tag}
                        </Link>{' '}
                        {c.name}
                      </span>
                    ))
                  : '—'}
              </Row>
              {([
                [t.assetForm.oemVendor, asset.oem_vendor_id],
                [t.assetForm.omVendor, asset.om_vendor_id],
              ] as const).map(([k, vid]) => {
                const x = vendors.find((y) => y.id === vid)
                return (
                  <Row key={k} k={k}>
                    {!vid ? (
                      '—'
                    ) : !can('vendor_core', 'view') ? (
                      <Hidden />
                    ) : (
                      <>
                        <Link className="row-link" to={`/vendors?id=${vid}`}>
                          {x?.name ?? d.formerVendor}
                        </Link>
                        {x && !x.is_active && <span className="tag">{t.vendors.inactive}</span>}
                      </>
                    )}
                  </Row>
                )
              })}
            </dl>
          </section>
          {can('coverage_contract', 'view') && <CoverageCard assetId={id} can={can} />}
          {can('obligation', 'view') && <ObligationsCard assetId={id} onRecord={can('obligation', 'complete') ? () => setTab('obligations') : undefined} />}
          {line.length > 0 && (
            <section className="card">
              <h2>{t.assetForm.fields}</h2>
              <dl className="kv">
                {line.map((f) => (
                  <Row key={f.id} k={f.unit ? `${f.label} (${f.unit})` : f.label}>
                    {canSee(f) ? show(`custom.${f.key}`, custom[f.key]) : <Hidden />}
                  </Row>
                ))}
              </dl>
            </section>
          )}
        </div>
      ) : tab === 'coverage' ? (
        <CoverageTab assetId={id} can={can} />
      ) : tab === 'obligations' ? (
        <ObligationsTab tenantId={asset.tenant_id ?? ''} assetId={id} asset={asset} can={can} />
      ) : tab === 'service' ? (
        <ServiceHistoryTab assetId={id} can={can} />
      ) : tab === 'attachments' ? (
        <AttachmentsTab tenantId={asset.tenant_id ?? ''} assetId={id} can={can} timeZone={timeZone} />
      ) : (
        <AuditTab key={`${asset.id}-${version}`} assetId={asset.id ?? assetId} timeZone={timeZone} label={label} show={show} onTags={(m) => setTags((x) => ({ ...x, ...m }))} known={tags} />
      )}
      {dialog === 'transfer' && (
        <ActionDialog
          title={a.transferTitle.replace('{tag}', tag)}
          hint={a.transferHint}
          submit={a.transfer}
          // Active places only; the current one cannot be picked. Inactive ones keep the tree shape.
          choices={{ label: a.to, placeholder: a.choose, options: buildTree(places).map(({ row, depth }) => ({ value: row.id, text: `${'— '.repeat(depth)}${row.name}`, off: !row.active || row.id === asset.location_id })) }}
          run={(to, reason) => supabase.rpc('transfer_asset', { p_asset_id: id, p_to_location_id: to, p_reason: reason })}
          onClose={close}
          onDone={done}
        />
      )}
      {dialog === 'retire' && (
        <ActionDialog
          title={a.retireTitle.replace('{tag}', tag)}
          hint={a.retireHint}
          submit={a.retire}
          run={(_, reason) => supabase.rpc('change_asset_status', { p_asset_id: id, p_status: 'disposed', p_reason: reason })}
          onClose={close}
          onDone={done}
        />
      )}
      {dialog === 'status' && (
        <ActionDialog
          title={a.statusTitle.replace('{tag}', tag)}
          submit={a.changeStatus}
          choices={{ label: a.newStatus, placeholder: a.chooseStatus, options: targets.map((s) => ({ value: s, text: statusName(statuses, s) })) }}
          run={(status, reason) => supabase.rpc('change_asset_status', { p_asset_id: id, p_status_id: status, p_reason: reason })}
          onClose={close}
          onDone={done}
        />
      )}
    </>
  )
}

// One modal for transfer, retire and change status: an optional choice, a reason, the action.
function ActionDialog(props: {
  title: string
  hint?: string
  submit: string
  choices?: { label: string; placeholder: string; options: { value: string; text: string; off?: boolean }[] }
  run: (choice: string, reason: string) => PromiseLike<{ error: { code?: string; message?: string } | null }>
  onClose: () => void
  onDone: () => void
}) {
  const { choices } = props
  const [choice, setChoice] = useState('')
  const [reason, setReason] = useState('')
  const [error, setError] = useState<string>()
  const [busy, setBusy] = useState(false)

  async function send(ev: FormEvent) {
    ev.preventDefault()
    setBusy(true)
    const { error } = await props.run(choice, reason)
    setBusy(false)
    if (error) setError(actionError(error))
    else props.onDone()
  }

  return (
    <div className="overlay" onKeyDown={(ev) => ev.key === 'Escape' && props.onClose()}>
      <form className="card dialog" role="dialog" aria-modal="true" aria-labelledby="action-title" onSubmit={(ev) => void send(ev)} noValidate>
        <h2 id="action-title">{props.title}</h2>
        {props.hint && <p className="muted">{props.hint}</p>}
        {error && (
          <p className="login-error" role="alert">
            {error}
          </p>
        )}
        {choices && (
          <label className="field">
            {choices.label}
            <select name="choice" value={choice} autoFocus onChange={(ev) => setChoice(ev.target.value)}>
              <option value="">{choices.placeholder}</option>
              {choices.options.map((o) => (
                <option key={o.value} value={o.value} disabled={o.off}>
                  {o.text}
                </option>
              ))}
            </select>
          </label>
        )}
        <label className="field">
          {a.reason}
          <textarea name="reason" rows={3} value={reason} autoFocus={!choices} onChange={(ev) => setReason(ev.target.value)} />
        </label>
        <div className="page-head">
          <div className="spacer" />
          <button className="btn" type="button" onClick={props.onClose}>
            {a.cancel}
          </button>
          <button className="btn btn-main" type="submit" disabled={busy || (!!choices && !choice)}>
            {props.submit}
          </button>
        </div>
      </form>
    </div>
  )
}

function AuditTab(props: {
  assetId: string
  timeZone?: string
  label: (key: string) => string
  show: (key: string, v: Json | undefined) => string
  known: Record<string, string>
  onTags: (m: Record<string, string>) => void
}) {
  const { assetId, onTags, known } = props
  const [rows, setRows] = useState<History[]>()
  const [more, setMore] = useState<ReturnType<typeof moreCursor>>()
  const [error, setError] = useState(false)
  const [busy, setBusy] = useState(false)

  const fetchPage = (after?: ReturnType<typeof moreCursor>) => supabase.rpc('asset_history', { p_asset_id: assetId, p_limit: PAGE + 1, ...after })

  async function apply(after: ReturnType<typeof moreCursor>, { data, error }: Awaited<ReturnType<typeof fetchPage>>) {
    setBusy(false)
    setError(!!error)
    const page = data ?? []
    setRows((r) => [...(after ? (r ?? []) : []), ...page.slice(0, PAGE)])
    setMore(moreCursor(page))
    // Parent changes show as tags.
    const ids = [...new Set(page.flatMap((x) => [obj(x.old_data).parent_asset_id, obj(x.new_data).parent_asset_id]))].filter((v): v is string => typeof v === 'string' && !known[v])
    if (ids.length) {
      const { data: found } = await supabase.from('asset_view').select('id, tag').in('id', ids)
      onTags(Object.fromEntries((found ?? []).map((a) => [a.id, a.tag])))
    }
  }

  useEffect(() => {
    let live = true
    void fetchPage().then((res) => (live ? apply(undefined, res) : undefined))
    return () => {
      live = false
    }
    // Once per asset (the tab is keyed by it).
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [assetId])

  if (rows === undefined) return <p className="muted" role="status">{d.loading}</p>
  const when = (iso: string) => new Date(iso).toLocaleString(undefined, { timeZone: props.timeZone, dateStyle: 'medium', timeStyle: 'short' })
  return (
    <div className="stack detail">
      {error && (
        <p className="login-error" role="alert">
          {h.error}
        </p>
      )}
      <section className="card history">
        {rows.length === 0 && <p className="muted">{h.none}</p>}
        <ol>
          {rows.map((r) => (
            <li key={r.id}>
              <div>
                <b>{historyTitle(r)}</b>
                <span className="muted">
                  {' · '}
                  {r.actor_type === 'system' ? h.system : r.actor_name || h.formerMember}
                  {' · '}
                  <time dateTime={r.occurred_at}>{when(r.occurred_at)}</time>
                </span>
              </div>
              <ul>
                {changes(r, props.label, props.show).map((c, i) => (
                  <li key={i}>
                    <span className="muted">{c.field}: </span>
                    {c.hidden ? <Hidden /> : `${c.from} → ${c.to}`}
                  </li>
                ))}
              </ul>
            </li>
          ))}
        </ol>
      </section>
      {more && (
        <div className="page-head">
          <button className="btn" type="button" disabled={busy} onClick={() => {
              setBusy(true)
              void fetchPage(more).then((res) => apply(more, res))
            }}>
            {h.more}
          </button>
        </div>
      )}
    </div>
  )
}

function Row({ k, children }: { k: string; children: ReactNode }) {
  return (
    <>
      <dt>{k}</dt>
      <dd>{children}</dd>
    </>
  )
}

function Hidden() {
  return <span className="tag">{d.hidden}</span>
}
