// Story 3.7b: tenant statuses card and the status set picker of the category form.
// Design: data-model-goal3.md §18 (asset_status 18.1, sets 18.2, permission 18.7).
import { useState, type FormEvent } from 'react'
import { statuses as systemStatuses, statusTone, StatusTag, type Status } from './Assets'
import { t } from './i18n'
import { supabase } from './supabase'
import { lineage } from './tree'

type Category = { id: string; parent_id: string | null; name: string; status_ids: string[] | null }
type Write = PromiseLike<{ data: unknown[] | null; error: { code?: string; message?: string } | null }>
export const tones = ['ok', 'warn', 'error', 'neutral'] as const
// Same as the asset_status.code check (migration 3_7_asset_status).
const codePattern = /^[a-z][a-z0-9_]{0,39}$/

const systemRank = (s: Status) => systemStatuses.indexOf(s.system_status as (typeof systemStatuses)[number])
const isDefault = (s: Status) => s.code === s.system_status
const live = (rows: Status[]) => rows.filter((s) => !s.deleted_at)

// Card order: system status, then its default row, then label.
export function groupStatuses(rows: Status[]) {
  return systemStatuses.map((system) => ({
    system,
    rows: live(rows)
      .filter((s) => s.system_status === system)
      .sort((a, b) => Number(isDefault(b)) - Number(isDefault(a)) || a.label.localeCompare(b.label)),
  }))
}

// A label to a code: lowercase, _ between words, starts with a letter.
export function codeFrom(label: string) {
  const code = label.toLowerCase().replace(/[^a-z0-9]+/g, '_').replace(/^_+|_+$/g, '')
  return (/^[a-z]/.test(code) ? code : `s_${code}`).slice(0, 40).replace(/_+$/, '')
}

// What a category with no set of its own uses (as private.effective_status_ids): the nearest
// ancestor's set, else every active status in system order then label (R2).
export function inheritedSet(categories: Category[], statuses: Status[], parentId: string) {
  const from = parentId
    ? lineage(categories, parentId)
        .map((id) => categories.find((c) => c.id === id))
        .find((c) => c?.status_ids)
    : undefined
  if (from?.status_ids) return { ids: from.status_ids, from }
  const ids = live(statuses)
    .filter((s) => s.is_active)
    .sort((a, b) => systemRank(a) - systemRank(b) || a.label.toLowerCase().localeCompare(b.label.toLowerCase()))
    .map((s) => s.id)
  return { ids, from: undefined }
}

// Checks before the write; the set trigger still runs.
export function validateSet(ids: string[], statuses: Status[]) {
  const e = t.categories.errors
  if (ids.length === 0) return e.setEmpty
  if (!ids.some((id) => ['in_stock', 'active'].includes(statuses.find((s) => s.id === id)?.system_status ?? ''))) return e.setStart
  return undefined
}

export function StatusesCard({
  statuses,
  canManage,
  tenantId,
  run,
  onError,
}: {
  statuses: Status[]
  canManage: boolean
  tenantId: string
  run: (write: Write, duplicate: string) => Promise<boolean>
  onError: (message: string) => void
}) {
  const [editing, setEditing] = useState<{ row?: Status }>()
  const s = t.categories.statuses

  return (
    <section className="card statuses" aria-labelledby="statuses-title">
      <div className="page-head">
        <div>
          <h2 id="statuses-title">{s.title}</h2>
          <span className="muted">{s.subtitle}</span>
        </div>
        <div className="spacer" />
        {canManage && !editing && (
          <button className="btn" type="button" onClick={() => setEditing({})}>
            {s.add}
          </button>
        )}
      </div>
      {editing && (
        <StatusForm
          key={editing.row?.id ?? 'new'}
          row={editing.row}
          onCancel={() => setEditing(undefined)}
          onError={onError}
          onSave={async (v) => {
            const write = editing.row
              ? supabase.from('asset_status').update(v).eq('id', editing.row.id).select('id')
              : supabase.from('asset_status').insert({ ...v, code: v.code ?? '', system_status: v.system_status ?? '', tenant_id: tenantId }).select('id')
            if (await run(write, t.categories.errors.duplicateStatusCode)) setEditing(undefined)
          }}
        />
      )}
      <div className="table-wrap">
        <table>
          <thead>
            <tr>
              <th>{s.col.status}</th>
              <th>{s.col.code}</th>
              {canManage && <th aria-label={t.categories.col.actions} />}
            </tr>
          </thead>
          {groupStatuses(statuses).map((g) => (
            <tbody key={g.system}>
              <tr>
                <th colSpan={canManage ? 3 : 2} scope="rowgroup" className="muted">
                  {(t.assets.statuses as Record<string, string>)[g.system]}
                </th>
              </tr>
              {g.rows.map((row) => (
                <tr key={row.id} className={row.is_active ? undefined : 'muted'}>
                  <td>
                    <StatusTag statuses={statuses} id={row.id} system={row.system_status} />
                    {isDefault(row) && <span className="tag">{s.default}</span>}
                    {!row.is_active && <span className="tag">{t.categories.inactive}</span>}
                  </td>
                  <td>
                    <code className="muted">{row.code}</code>
                  </td>
                  {canManage && (
                    <td className="actions">
                      <button className="btn" type="button" onClick={() => setEditing({ row })} aria-label={`${t.categories.edit} ${row.label}`}>
                        {t.categories.edit}
                      </button>
                    </td>
                  )}
                </tr>
              ))}
            </tbody>
          ))}
        </table>
      </div>
    </section>
  )
}

type StatusValues = { label: string; tone: string; is_active: boolean; code?: string; system_status?: string }

function StatusForm({
  row,
  onSave,
  onCancel,
  onError,
}: {
  row?: Status
  onSave: (v: StatusValues) => Promise<void>
  onCancel: () => void
  onError: (message: string) => void
}) {
  const s = t.categories.statuses
  const [label, setLabel] = useState(row?.label ?? '')
  const [code, setCode] = useState('')
  const [system, setSystem] = useState(row?.system_status ?? 'active')
  const [tone, setTone] = useState(row?.tone ?? statusTone.active ?? 'ok')
  const locked = !!row && isDefault(row)

  function submit(e: FormEvent<HTMLFormElement>) {
    e.preventDefault()
    const form = new FormData(e.currentTarget)
    const value = { label: label.trim(), tone, is_active: locked || form.get('active') === 'on' }
    if (!value.label || value.label.length > 60) return onError(t.categories.errors.statusLabel)
    const newCode = code.trim() || codeFrom(value.label)
    if (!row && !codePattern.test(newCode)) return onError(t.categories.errors.statusCode)
    // code and system_status cannot change after insert (3.7 column grants), so only a new status sends them.
    void onSave(row ? value : { ...value, code: newCode, system_status: system })
  }

  return (
    <form onSubmit={submit} noValidate aria-label={row ? s.edit : s.add}>
      <label className="field">
        {t.categories.label}
        <input name="label" value={label} onChange={(e) => setLabel(e.target.value)} maxLength={60} />
      </label>
      <label className="field">
        {t.categories.code}
        <input
          name="code"
          value={row ? row.code : code}
          placeholder={row || !label.trim() ? undefined : codeFrom(label)}
          onChange={(e) => setCode(e.target.value)}
          disabled={!!row}
          maxLength={40}
          spellCheck={false}
          aria-describedby="status-code-hint"
        />
        <span id="status-code-hint" className="muted hint">
          {row ? s.codeLocked : s.codeHint}
        </span>
      </label>
      <label className="field">
        {s.system}
        <select
          name="system"
          value={system}
          disabled={!!row}
          onChange={(e) => {
            setSystem(e.target.value)
            setTone(statusTone[e.target.value] ?? 'neutral')
          }}
        >
          {systemStatuses.map((x) => (
            <option key={x} value={x}>
              {(t.assets.statuses as Record<string, string>)[x]}
            </option>
          ))}
        </select>
        <span className="muted hint">{s.systemHint}</span>
      </label>
      <label className="field">
        {s.tone}
        <select name="tone" value={tone} onChange={(e) => setTone(e.target.value)}>
          {tones.map((x) => (
            <option key={x} value={x}>
              {s.tones[x]}
            </option>
          ))}
        </select>
      </label>
      <label className="check">
        <input name="active" type="checkbox" defaultChecked={row?.is_active ?? true} disabled={locked} aria-describedby={locked ? 'status-active-hint' : undefined} />
        {t.categories.active}
      </label>
      {locked && (
        <p id="status-active-hint" className="muted hint">
          {s.defaultLocked}
        </p>
      )}
      <div className="page-head">
        <div className="spacer" />
        <button className="btn" type="button" onClick={onCancel}>
          {t.categories.cancel}
        </button>
        <button className="btn btn-main" type="submit">
          {t.categories.save}
        </button>
      </div>
    </form>
  )
}

// The status set of the category form (18.2): inherit (null), or an own ordered list.
export function StatusSetPicker({
  categories,
  statuses,
  parentId,
  value,
  onChange,
}: {
  categories: Category[]
  statuses: Status[]
  parentId: string
  value: string[] | null
  onChange: (ids: string[] | null) => void
}) {
  const s = t.categories.statusSet
  const inherited = inheritedSet(categories, statuses, parentId)
  const [pick, setPick] = useState('')
  const byId = (id: string) => statuses.find((x) => x.id === id)
  const addable = live(statuses).filter((x) => x.is_active && !value?.includes(x.id))

  function move(i: number, by: -1 | 1) {
    if (!value) return
    const next = [...value]
    const [id] = next.splice(i, 1)
    next.splice(i + by, 0, id as string)
    onChange(next)
  }

  const list = (ids: string[], own: boolean) => (
    <ol className="set-list">
      {ids.map((id, i) => {
        const row = byId(id)
        return (
          <li key={id}>
            <StatusTag statuses={statuses} id={id} system={row?.system_status} />
            <span className="muted">{(t.assets.statuses as Record<string, string>)[row?.system_status ?? ''] ?? ''}</span>
            {row && !row.is_active && <span className="tag">{t.categories.inactive}</span>}
            {own && (
              <span className="actions">
                <button className="btn" type="button" disabled={i === 0} onClick={() => move(i, -1)} aria-label={`${t.categories.moveUp} ${row?.label ?? ''}`}>
                  ↑
                </button>
                <button className="btn" type="button" disabled={i === ids.length - 1} onClick={() => move(i, 1)} aria-label={`${t.categories.moveDown} ${row?.label ?? ''}`}>
                  ↓
                </button>
                <button className="btn" type="button" onClick={() => onChange(ids.filter((x) => x !== id))} aria-label={`${s.remove} ${row?.label ?? ''}`}>
                  {s.remove}
                </button>
              </span>
            )}
          </li>
        )
      })}
    </ol>
  )

  return (
    <fieldset className="field set">
      <legend>{s.title}</legend>
      <label className="check">
        <input type="radio" name="set-mode" checked={value === null} onChange={() => onChange(null)} />
        {s.inherit}
      </label>
      <label className="check">
        <input
          type="radio"
          name="set-mode"
          checked={value !== null}
          onChange={() => onChange(inherited.ids.filter((id) => byId(id)?.is_active))}
        />
        {s.own}
      </label>
      {value === null ? (
        <>
          <span className="muted hint" id="set-source">
            {inherited.from ? s.inheritedFrom.replace('{name}', inherited.from.name) : s.inheritedAll}
          </span>
          {list(inherited.ids, false)}
        </>
      ) : (
        <>
          {list(value, true)}
          <div className="page-head">
            <select aria-label={s.addLabel} value={pick} onChange={(e) => setPick(e.target.value)}>
              <option value="">{s.choose}</option>
              {addable.map((x) => (
                <option key={x.id} value={x.id}>
                  {x.label}
                </option>
              ))}
            </select>
            <button
              className="btn"
              type="button"
              disabled={!pick}
              onClick={() => {
                onChange([...value, pick])
                setPick('')
              }}
            >
              {s.add}
            </button>
          </div>
        </>
      )}
    </fieldset>
  )
}
