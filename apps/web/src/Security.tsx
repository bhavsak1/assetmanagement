import { useEffect, useState, type FormEvent } from 'react'
import { TreeSelect } from './Assets'
import { t } from './i18n'
import { supabase } from './supabase'
import type { Database, Tables } from './types/database'

type Group = Pick<Tables<'security_group'>, 'id' | 'code' | 'name' | 'group_type'>
type Domain = Pick<Tables<'security_domain'>, 'id' | 'code' | 'description'> & { domain_operation: Pick<Tables<'domain_operation'>, 'id' | 'code' | 'sort_order'>[] }
type Assignment = Pick<Tables<'user_group_assignment'>, 'id' | 'user_id' | 'security_group_id' | 'scope_profile_id' | 'effective_from' | 'effective_to'>
type Member = { user_id: string; display_name: string; email: string; status: string }
type Profile = Pick<Tables<'scope_profile'>, 'id' | 'name'>
type Rule = Pick<Tables<'scope_profile_rule'>, 'id' | 'scope_profile_id' | 'dimension' | 'location_id' | 'category_id'>
type Node = { id: string; parent_id: string | null; name: string }
type ChangeSet = Pick<Tables<'policy_change_set'>, 'id' | 'status' | 'created_by' | 'activated_by' | 'activated_at' | 'created_at'>
type Item = Pick<Tables<'policy_change_set_item'>, 'policy_change_set_id' | 'security_group_id' | 'operation_ids'>
type Diff = Database['public']['Functions']['change_set_diff']['Returns'][number]
type DbError = { code?: string; message?: string }
type Write = PromiseLike<{ data?: unknown; error: DbError | null }>

const s = t.security
const tabs = ['groups', 'assignments', 'profiles', 'changes'] as const
type Tab = (typeof tabs)[number]
const label = (map: Record<string, string>, code: string, fallback?: string) => map[code] ?? fallback ?? code
// Domains in the order of the label file (the starter grid's order); a domain added later goes last.
const domainOrder = Object.keys(s.domains)
const rank = (code: string) => (domainOrder.includes(code) ? domainOrder.indexOf(code) : domainOrder.length)
const now = () => new Date().toISOString()
// shortcut: UTC calendar date, not the tenant's format and zone; switch to Settings.formatDate when the shell holds the tenant.
const day = (iso: string | null) => (iso ? iso.slice(0, 10) : s.assignments.open)

// Same as the security_group.code check (migration 1_2), unique among the live groups.
export function groupCode(name: string, taken: string[]): string {
  const base = `g_${name.toLowerCase().replace(/[^a-z0-9]+/g, '_').replace(/^_+|_+$/g, '')}`.replace(/_$/, '').slice(0, 40)
  let code = base
  for (let n = 2; taken.includes(code); n++) code = `${base}_${n}`
  return code
}

export function securityError(error: DbError | null): string {
  const e = s.errors
  const m = error?.message ?? ''
  if (m.includes('last security admin')) return e.lastAdmin
  if (m.includes('not an open draft')) return e.notDraft
  if (error?.code === '42501') return e.noPermission
  if (m.includes('security group is assigned')) return e.groupAssigned
  if (m.includes('scope profile is assigned')) return e.profileAssigned
  if (error?.code === '23505') return e.duplicate
  return e.generic
}

export function SecurityPage({ tenantId, canView, canManage }: { tenantId: string; canView: boolean; canManage: boolean }) {
  const [tab, setTab] = useState<Tab>('groups')
  const [groups, setGroups] = useState<Group[]>([])
  const [domains, setDomains] = useState<Domain[]>([])
  const [assignments, setAssignments] = useState<Assignment[]>([])
  const [members, setMembers] = useState<Member[]>([])
  const [profiles, setProfiles] = useState<Profile[]>([])
  const [rules, setRules] = useState<Rule[]>([])
  const [locations, setLocations] = useState<Node[]>([])
  const [categories, setCategories] = useState<Node[]>([])
  const [sets, setSets] = useState<ChangeSet[]>([])
  const [items, setItems] = useState<Item[]>([])
  const [diff, setDiff] = useState<Diff[]>([])
  const [error, setError] = useState<string>()
  const [reload, setReload] = useState(0)
  const draft = sets.find((x) => x.status === 'draft')

  useEffect(() => {
    if (!canView) return
    let live = true
    void Promise.all([
      supabase.from('security_group').select('id, code, name, group_type').is('deleted_at', null).order('name'),
      supabase.from('security_domain').select('id, code, description, domain_operation (id, code, sort_order)'),
      supabase.from('user_group_assignment').select('id, user_id, security_group_id, scope_profile_id, effective_from, effective_to').is('deleted_at', null).order('effective_from'),
      supabase.rpc('security_members'),
      supabase.from('scope_profile').select('id, name').is('deleted_at', null).order('name'),
      supabase.from('scope_profile_rule').select('id, scope_profile_id, dimension, location_id, category_id').is('deleted_at', null),
      supabase.from('location').select('id, parent_id, name').is('deleted_at', null),
      supabase.from('asset_category').select('id, parent_id, name').is('deleted_at', null),
      supabase.from('policy_change_set').select('id, status, created_by, activated_by, activated_at, created_at').order('created_at', { ascending: false }),
      supabase.from('policy_change_set_item').select('policy_change_set_id, security_group_id, operation_ids').is('deleted_at', null),
    ]).then(async ([g, d, a, m, p, r, l, c, cs, ci]) => {
      const open = (cs.data ?? []).find((x) => x.status === 'draft')
      const diffRows = open ? (await supabase.rpc('change_set_diff', { p_change_set_id: open.id })).data : []
      if (!live) return
      setGroups(g.data ?? [])
      // rls_sample is the 1.4 test template, not business data (1.6 leaves it out of every group too).
      setDomains((d.data ?? []).filter((x) => x.code !== 'rls_sample').sort((x, y) => rank(x.code) - rank(y.code) || x.code.localeCompare(y.code)))
      setAssignments(a.data ?? [])
      setMembers(m.data ?? [])
      setProfiles(p.data ?? [])
      setRules(r.data ?? [])
      setLocations(l.data ?? [])
      setCategories(c.data ?? [])
      setSets(cs.data ?? [])
      setItems(open ? (ci.data ?? []).filter((x) => x.policy_change_set_id === open.id) : [])
      setDiff(diffRows ?? [])
    })
    return () => {
      live = false
    }
  }, [canView, reload])

  // Every write: show the database's reason, or reload on success. An RLS no-op returns no row.
  async function run(write: Write, needRow = true): Promise<boolean> {
    setError(undefined)
    const { data, error } = await write
    if (error || (needRow && !(Array.isArray(data) && data.length))) {
      setError(securityError(error ?? { code: '42501' }))
      // A draft closed elsewhere: show the current state.
      if (error?.message?.includes('not an open draft')) setReload((n) => n + 1)
      return false
    }
    setReload((n) => n + 1)
    return true
  }

  if (!canView)
    return (
      <>
        <title>{`${t.pages.security} · ${t.app.name}`}</title>
        <h1>{t.pages.security}</h1>
        <p className="muted">{s.noAccess}</p>
      </>
    )

  return (
    <>
      <title>{`${t.pages.security} · ${t.app.name}`}</title>
      <div className="page-head">
        <div>
          <h1>{t.pages.security}</h1>
          <span className="muted">{s.subtitle}</span>
        </div>
        <div className="spacer" />
        {canManage && diff.length > 0 && (
          <button className="btn btn-main" type="button" onClick={() => setTab('changes')}>
            {s.changes.review}
          </button>
        )}
      </div>
      {diff.length > 0 && (
        <p className="banner" role="status">
          {s.changes.pending.replace('{n}', String(diff.length))}
        </p>
      )}
      {error && (
        <p className="login-error" role="alert">
          {error}
        </p>
      )}
      <div className="tabs" role="tablist">
        {tabs.map((k) => (
          <button key={k} type="button" role="tab" aria-selected={tab === k} className={tab === k ? 'on' : ''} onClick={() => setTab(k)}>
            {s.tabs[k]}
          </button>
        ))}
      </div>
      {tab === 'groups' && <Groups tenantId={tenantId} groups={groups} domains={domains} items={items} canManage={canManage} run={run} reload={reload} />}
      {tab === 'assignments' && (
        <Assignments tenantId={tenantId} rows={assignments} members={members} groups={groups} profiles={profiles} canManage={canManage} run={run} />
      )}
      {tab === 'profiles' && (
        <Profiles tenantId={tenantId} profiles={profiles} rules={rules} assignments={assignments} locations={locations} categories={categories} canManage={canManage} run={run} />
      )}
      {tab === 'changes' && <ChangeSets draft={draft} sets={sets} diff={diff} members={members} canManage={canManage} run={run} />}
    </>
  )
}

type Run = (write: Write, needRow?: boolean) => Promise<boolean>

function Groups({ tenantId, groups, domains, items, canManage, run, reload }: { tenantId: string; groups: Group[]; domains: Domain[]; items: Item[]; canManage: boolean; run: Run; reload: number }) {
  const g = s.groups
  const [selected, setSelected] = useState<string>()
  const [creating, setCreating] = useState(false)
  const [renaming, setRenaming] = useState(false)
  const [live, setLive] = useState<string[]>([])
  const [checked, setChecked] = useState<Set<string>>(new Set())
  const current = groups.find((x) => x.id === selected) ?? groups[0]
  const editable = canManage && current?.group_type !== 'system'
  // The grid shows the group's draft when it has one (6.4 C7), else its live grants.
  const drafted = items.find((x) => x.security_group_id === current?.id)?.operation_ids
  const saved = drafted ?? live
  const savedKey = [...saved].sort().join()
  const dirty = saved.length !== checked.size || saved.some((id) => !checked.has(id))

  const currentId = current?.id
  useEffect(() => {
    if (!currentId) return
    let live = true
    void supabase
      .from('group_domain_policy')
      .select('domain_operation_id')
      .eq('security_group_id', currentId)
      .is('deleted_at', null)
      .then(({ data }) => {
        if (!live) return
        setLive((data ?? []).map((r) => r.domain_operation_id))
      })
    return () => {
      live = false
    }
  }, [currentId, reload])

  // Reset the boxes when the group or its saved set changes (adjusting state during render).
  const baseKey = `${currentId}:${savedKey}`
  const [base, setBase] = useState(baseKey)
  if (base !== baseKey) {
    setBase(baseKey)
    setChecked(new Set(saved))
  }

  function toggle(id: string) {
    const next = new Set(checked)
    if (next.has(id)) next.delete(id)
    else next.add(id)
    setChecked(next)
  }

  async function create(e: FormEvent<HTMLFormElement>) {
    e.preventDefault()
    const form = new FormData(e.currentTarget)
    const name = String(form.get('name') ?? '').trim()
    const from = String(form.get('from') ?? '')
    if (!name) return
    const { data, error } = await supabase
      .from('security_group')
      .insert({ tenant_id: tenantId, name, code: groupCode(name, groups.map((x) => x.code)) })
      .select('id')
      .single()
    if (!(await run(Promise.resolve({ data: data ? [data] : [], error })))) return
    if (from && data) {
      const { data: ops } = await supabase.from('group_domain_policy').select('domain_operation_id').eq('security_group_id', from).is('deleted_at', null)
      await run(supabase.rpc('set_group_policies', { p_group_id: data.id, p_operation_ids: (ops ?? []).map((r) => r.domain_operation_id) }), false)
    }
    setCreating(false)
    if (data) setSelected(data.id)
  }

  async function rename(e: FormEvent<HTMLFormElement>) {
    e.preventDefault()
    const name = String(new FormData(e.currentTarget).get('name') ?? '').trim()
    if (current && name && (await run(supabase.from('security_group').update({ name }).eq('id', current.id).select('id')))) setRenaming(false)
  }

  return (
    <div className="split">
      <div className="card tree" role="list" aria-label={g.title}>
        {groups.map((row) => (
          <button
            key={row.id}
            type="button"
            role="listitem"
            className={`li${row.id === current?.id ? ' on' : ''}`}
            aria-current={row.id === current?.id}
            onClick={() => {
              setSelected(row.id)
              setRenaming(false)
            }}
          >
            {row.name}
            {row.group_type === 'system' && <span className="tag">{g.system}</span>}
          </button>
        ))}
        {canManage && !creating && (
          <button className="btn block" type="button" onClick={() => setCreating(true)}>
            {g.add}
          </button>
        )}
      </div>
      <div className="stack">
        {creating && (
          <form className="card form-grid" onSubmit={(e) => void create(e)} noValidate>
            <h2>{g.add}</h2>
            <label className="field">
              {g.name}
              <input name="name" required maxLength={80} />
            </label>
            <label className="field">
              {g.copyFrom}
              <select name="from" defaultValue="">
                <option value="">{g.blank}</option>
                {groups.map((row) => (
                  <option key={row.id} value={row.id}>
                    {row.name}
                  </option>
                ))}
              </select>
            </label>
            <div className="page-head">
              <div className="spacer" />
              <button className="btn" type="button" onClick={() => setCreating(false)}>
                {s.cancel}
              </button>
              <button className="btn btn-main" type="submit">
                {s.save}
              </button>
            </div>
          </form>
        )}
        {current && (
          <div className="card">
            <div className="page-head">
              {renaming ? (
                <form className="page-head" onSubmit={(e) => void rename(e)}>
                  <label className="field">
                    {g.name}
                    <input name="name" defaultValue={current.name} required maxLength={80} />
                  </label>
                  <button className="btn" type="button" onClick={() => setRenaming(false)}>
                    {s.cancel}
                  </button>
                  <button className="btn btn-main" type="submit">
                    {s.save}
                  </button>
                </form>
              ) : (
                <h2>
                  {g.policies.replace('{group}', current.name)}
                  {drafted && <span className="tag warn">{g.draft}</span>}
                </h2>
              )}
              <div className="spacer" />
              {editable && !renaming && (
                <>
                  <button className="btn" type="button" onClick={() => setRenaming(true)}>
                    {g.rename}
                  </button>
                  <button
                    className="btn"
                    type="button"
                    onClick={() => {
                      if (window.confirm(g.confirmDelete.replace('{group}', current.name)))
                        void run(supabase.from('security_group').update({ deleted_at: now() }).eq('id', current.id).select('id')).then((ok) => ok && setSelected(undefined))
                    }}
                  >
                    {g.delete}
                  </button>
                </>
              )}
            </div>
            {!editable && <p className="muted">{canManage ? g.systemHint : g.readOnly}</p>}
            <div className="table-wrap">
              <table className="grid">
                <thead>
                  <tr>
                    <th>{g.domain}</th>
                    <th>{g.operations}</th>
                  </tr>
                </thead>
                <tbody>
                  {domains.map((d) => (
                    <tr key={d.id}>
                      <th scope="row">{label(s.domains, d.code, d.description)}</th>
                      <td>
                        {[...d.domain_operation]
                          .sort((a, b) => a.sort_order - b.sort_order)
                          .map((o) => (
                            <label key={o.id} className="op">
                              <input type="checkbox" checked={checked.has(o.id)} disabled={!editable} onChange={() => toggle(o.id)} />
                              {label(s.ops, o.code)}
                            </label>
                          ))}
                      </td>
                    </tr>
                  ))}
                </tbody>
              </table>
            </div>
            {editable && (
              <div className="page-head">
                <span className="muted">{dirty ? g.unsaved : g.draftHint}</span>
                <div className="spacer" />
                {drafted && (
                  <button className="btn" type="button" onClick={() => void run(supabase.rpc('set_group_policies', { p_group_id: current.id, p_operation_ids: live }), false)}>
                    {g.revert}
                  </button>
                )}
                <button className="btn" type="button" disabled={!dirty} onClick={() => setChecked(new Set(saved))}>
                  {g.reset}
                </button>
                <button
                  className="btn btn-main"
                  type="button"
                  disabled={!dirty}
                  onClick={() => void run(supabase.rpc('set_group_policies', { p_group_id: current.id, p_operation_ids: [...checked] }), false)}
                >
                  {s.save}
                </button>
              </div>
            )}
          </div>
        )}
      </div>
    </div>
  )
}

function Assignments({ tenantId, rows, members, groups, profiles, canManage, run }: { tenantId: string; rows: Assignment[]; members: Member[]; groups: Group[]; profiles: Profile[]; canManage: boolean; run: Run }) {
  const a = s.assignments
  const [adding, setAdding] = useState(false)
  const name = <T extends { id: string; name: string }>(list: T[], id: string | null) => list.find((x) => x.id === id)?.name ?? '—'
  const member = (id: string) => members.find((m) => m.user_id === id)
  const ended = (r: Assignment) => !!r.effective_to && r.effective_to <= now()

  async function add(e: FormEvent<HTMLFormElement>) {
    e.preventDefault()
    const form = new FormData(e.currentTarget)
    const text = (k: string) => String(form.get(k) ?? '') || null
    const from = text('from')
    const to = text('to')
    const ok = await run(
      supabase
        .from('user_group_assignment')
        .insert({
          tenant_id: tenantId,
          user_id: text('user') ?? '',
          security_group_id: text('group') ?? '',
          scope_profile_id: text('scope'),
          ...(from ? { effective_from: new Date(from).toISOString() } : {}),
          effective_to: to ? new Date(to).toISOString() : null,
        })
        .select('id'),
    )
    if (ok) setAdding(false)
  }

  return (
    <div className="card list detail">
      <div className="page-head">
        <span className="muted">{a.intro}</span>
        <div className="spacer" />
        {canManage && !adding && (
          <button className="btn" type="button" onClick={() => setAdding(true)}>
            {a.add}
          </button>
        )}
      </div>
      {adding && (
        <form className="form-grid" onSubmit={(e) => void add(e)}>
          <label className="field">
            {a.member}
            <select name="user" required defaultValue="">
              <option value="" disabled>
                {a.pick}
              </option>
              {members.map((m) => (
                <option key={m.user_id} value={m.user_id}>
                  {`${m.display_name} (${m.email})`}
                </option>
              ))}
            </select>
          </label>
          <label className="field">
            {a.group}
            <select name="group" required defaultValue="">
              <option value="" disabled>
                {a.pick}
              </option>
              {groups.map((g) => (
                <option key={g.id} value={g.id}>
                  {g.name}
                </option>
              ))}
            </select>
          </label>
          <label className="field">
            {a.scope}
            <select name="scope" defaultValue="">
              <option value="">{a.tenantWide}</option>
              {profiles.map((p) => (
                <option key={p.id} value={p.id}>
                  {p.name}
                </option>
              ))}
            </select>
          </label>
          <label className="field">
            {a.from}
            <input name="from" type="date" />
          </label>
          <label className="field">
            {a.to}
            <input name="to" type="date" />
          </label>
          <div className="page-head">
            <div className="spacer" />
            <button className="btn" type="button" onClick={() => setAdding(false)}>
              {s.cancel}
            </button>
            <button className="btn btn-main" type="submit">
              {s.save}
            </button>
          </div>
        </form>
      )}
      <div className="table-wrap">
        <table>
          <thead>
            <tr>
              <th>{a.member}</th>
              <th>{a.group}</th>
              <th>{a.scope}</th>
              <th>{a.from}</th>
              <th>{a.to}</th>
              {canManage && <th aria-label={a.actions} />}
            </tr>
          </thead>
          <tbody>
            {rows.length === 0 && (
              <tr>
                <td colSpan={6} className="muted">
                  {a.none}
                </td>
              </tr>
            )}
            {rows.map((r) => (
              <tr key={r.id}>
                <td>
                  {member(r.user_id)?.display_name ?? '—'}
                  {member(r.user_id)?.status === 'disabled' && <span className="tag">{a.disabled}</span>}
                  <div className="muted">{member(r.user_id)?.email}</div>
                </td>
                <td>{name(groups, r.security_group_id)}</td>
                <td>
                  {canManage ? (
                    <select
                      className="filter"
                      aria-label={a.scope}
                      value={r.scope_profile_id ?? ''}
                      onChange={(e) => void run(supabase.from('user_group_assignment').update({ scope_profile_id: e.target.value || null }).eq('id', r.id).select('id'))}
                    >
                      <option value="">{a.tenantWide}</option>
                      {profiles.map((p) => (
                        <option key={p.id} value={p.id}>
                          {p.name}
                        </option>
                      ))}
                    </select>
                  ) : r.scope_profile_id ? (
                    name(profiles, r.scope_profile_id)
                  ) : (
                    a.tenantWide
                  )}
                </td>
                <td>{day(r.effective_from)}</td>
                <td>
                  {day(r.effective_to)}
                  {ended(r) && <span className="tag">{a.ended}</span>}
                </td>
                {canManage && (
                  <td className="actions">
                    {!ended(r) && r.effective_from < now() && (
                      <button className="btn" type="button" onClick={() => void run(supabase.from('user_group_assignment').update({ effective_to: now() }).eq('id', r.id).select('id'))}>
                        {a.end}
                      </button>
                    )}
                    <button className="btn" type="button" onClick={() => void run(supabase.from('user_group_assignment').update({ deleted_at: now() }).eq('id', r.id).select('id'))}>
                      {a.remove}
                    </button>
                  </td>
                )}
              </tr>
            ))}
          </tbody>
        </table>
      </div>
    </div>
  )
}

function Profiles({ tenantId, profiles, rules, assignments, locations, categories, canManage, run }: { tenantId: string; profiles: Profile[]; rules: Rule[]; assignments: Assignment[]; locations: Node[]; categories: Node[]; canManage: boolean; run: Run }) {
  const p = s.profiles
  const [selected, setSelected] = useState<string>()
  const [editing, setEditing] = useState<{ row?: Profile }>()
  const current = profiles.find((x) => x.id === selected) ?? profiles[0]
  const mine = rules.filter((r) => r.scope_profile_id === current?.id)
  const users = new Set(assignments.filter((a) => a.scope_profile_id === current?.id).map((a) => a.user_id)).size

  async function save(e: FormEvent<HTMLFormElement>) {
    e.preventDefault()
    const name = String(new FormData(e.currentTarget).get('name') ?? '').trim()
    if (!name) return
    const ok = await run(
      editing?.row
        ? supabase.from('scope_profile').update({ name }).eq('id', editing.row.id).select('id')
        : supabase.from('scope_profile').insert({ tenant_id: tenantId, name }).select('id'),
    )
    if (ok) setEditing(undefined)
  }

  function addRule(dimension: 'location' | 'category', id: string) {
    if (!current || !id) return
    void run(
      supabase
        .from('scope_profile_rule')
        .insert({ tenant_id: tenantId, scope_profile_id: current.id, dimension, location_id: dimension === 'location' ? id : null, category_id: dimension === 'category' ? id : null })
        .select('id'),
    )
  }

  function dimension(kind: 'location' | 'category', title: string, nodes: Node[], suffix: string) {
    const list = mine.filter((r) => r.dimension === kind)
    const taken = new Set(list.map((r) => r.location_id ?? r.category_id))
    return (
      <>
        <dt>{title}</dt>
        <dd>
          {list.length === 0 && p.all}
          <div className="chips">
            {list.map((r) => (
              <span key={r.id} className="chip">
                {`${nodes.find((n) => n.id === (r.location_id ?? r.category_id))?.name ?? '—'} ${suffix}`}
                {canManage && (
                  <button type="button" aria-label={p.removeRule} onClick={() => void run(supabase.from('scope_profile_rule').update({ deleted_at: now() }).eq('id', r.id).select('id'))}>
                    ×
                  </button>
                )}
              </span>
            ))}
          </div>
          {canManage && <TreeSelect label={p.addRule.replace('{dimension}', title)} all={p.addRule.replace('{dimension}', title)} rows={nodes.filter((n) => !taken.has(n.id))} value="" onChange={(id) => addRule(kind, id)} />}
        </dd>
      </>
    )
  }

  return (
    <div className="split">
      <div className="card tree" role="list" aria-label={p.title}>
        {profiles.length === 0 && <p className="muted">{p.none}</p>}
        {profiles.map((row) => (
          <button
            key={row.id}
            type="button"
            role="listitem"
            className={`li${row.id === current?.id ? ' on' : ''}`}
            aria-current={row.id === current?.id}
            onClick={() => {
              setSelected(row.id)
              setEditing(undefined)
            }}
          >
            {row.name}
          </button>
        ))}
        {canManage && !editing && (
          <button className="btn block" type="button" onClick={() => setEditing({})}>
            {p.add}
          </button>
        )}
      </div>
      <div className="stack">
        {editing && (
          <form className="card form-grid" onSubmit={(e) => void save(e)} key={editing.row?.id ?? 'new'}>
            <label className="field">
              {p.name}
              <input name="name" defaultValue={editing.row?.name ?? ''} required maxLength={80} />
            </label>
            <div className="page-head">
              <div className="spacer" />
              <button className="btn" type="button" onClick={() => setEditing(undefined)}>
                {s.cancel}
              </button>
              <button className="btn btn-main" type="submit">
                {s.save}
              </button>
            </div>
          </form>
        )}
        {current && (
          <div className="card">
            <div className="page-head">
              <h2>{current.name}</h2>
              <div className="spacer" />
              {canManage && (
                <>
                  <button className="btn" type="button" onClick={() => setEditing({ row: current })}>
                    {p.rename}
                  </button>
                  <button
                    className="btn"
                    type="button"
                    onClick={() => {
                      if (window.confirm(p.confirmDelete.replace('{profile}', current.name)))
                        void run(supabase.from('scope_profile').update({ deleted_at: now() }).eq('id', current.id).select('id')).then((ok) => ok && setSelected(undefined))
                    }}
                  >
                    {p.delete}
                  </button>
                </>
              )}
            </div>
            {mine.length === 0 && <p className="muted">{p.empty}</p>}
            <dl className="kv">
              {dimension('location', p.locations, locations, p.andBelow)}
              {dimension('category', p.categories, categories, p.andChildren)}
              <dt>{p.assigned}</dt>
              <dd>{p.users.replace('{n}', String(users))}</dd>
            </dl>
          </div>
        )}
      </div>
    </div>
  )
}

function ChangeSets({ draft, sets, diff, members, canManage, run }: { draft?: ChangeSet; sets: ChangeSet[]; diff: Diff[]; members: Member[]; canManage: boolean; run: Run }) {
  const c = s.changes
  const [open, setOpen] = useState<Record<string, Diff[]>>({})
  const who = (id: string | null) => members.find((m) => m.user_id === id)?.display_name ?? '—'
  const history = sets.filter((x) => x.status !== 'draft')

  async function toggle(id: string) {
    if (open[id])
      return setOpen((o) => {
        const next = { ...o }
        delete next[id]
        return next
      })
    const { data } = await supabase.rpc('change_set_diff', { p_change_set_id: id })
    setOpen((o) => ({ ...o, [id]: data ?? [] }))
  }

  return (
    <div className="stack">
      <div className="card">
        <div className="page-head">
          <h2>{c.draftTitle}</h2>
          <div className="spacer" />
          {draft && <span className="muted">{c.draftedBy.replace('{name}', who(draft.created_by))}</span>}
        </div>
        {diff.length ? <DiffList rows={diff} /> : <p className="muted">{c.none}</p>}
        {canManage && draft && (
          <div className="page-head">
            <div className="spacer" />
            <button className="btn" type="button" onClick={() => window.confirm(c.confirmDiscard) && void run(supabase.rpc('discard_change_set', { p_change_set_id: draft.id }), false)}>
              {c.discard}
            </button>
            <button
              className="btn btn-main"
              type="button"
              disabled={!diff.length}
              onClick={() => window.confirm(c.confirmActivate.replace('{n}', String(diff.length))) && void run(supabase.rpc('activate_change_set', { p_change_set_id: draft.id }), false)}
            >
              {c.activate}
            </button>
          </div>
        )}
      </div>
      <div className="card">
        <h2>{c.history}</h2>
        {history.length ? (
          <div className="table-wrap">
            <table>
              <thead>
                <tr>
                  <th>{c.date}</th>
                  <th>{c.status}</th>
                  <th>{c.drafted}</th>
                  <th>{c.activatedBy}</th>
                  <th>{c.changes}</th>
                </tr>
              </thead>
              <tbody>
                {history.map((x) => {
                  const rows = open[x.id]
                  return (
                    <tr key={x.id}>
                      <td>{day(x.activated_at ?? x.created_at)}</td>
                      <td>
                        <span className={`tag status${x.status === 'activated' ? ' ok' : ''}`}>{label(c.statuses, x.status)}</span>
                      </td>
                      <td>{who(x.created_by)}</td>
                      <td>{x.activated_by ? who(x.activated_by) : '—'}</td>
                      <td>
                        <button className="btn" type="button" aria-expanded={!!rows} onClick={() => void toggle(x.id)}>
                          {rows ? c.hide : c.show}
                        </button>
                        {rows && <DiffList rows={rows} />}
                      </td>
                    </tr>
                  )
                })}
              </tbody>
            </table>
          </div>
        ) : (
          <p className="muted">{c.noHistory}</p>
        )}
      </div>
    </div>
  )
}

// One block per group: each added or removed operation, labelled like the grid.
function DiffList({ rows }: { rows: Diff[] }) {
  const groups = [...new Set(rows.map((r) => r.group_name))]
  return (
    <div className="stack">
      {groups.map((group) => (
        <div key={group}>
          <h3>{group}</h3>
          <ul className="plain-list">
            {rows
              .filter((r) => r.group_name === group)
              .map((r) => (
                <li key={`${r.domain_code}.${r.operation_code}`}>
                  <span className={`tag status ${r.change === 'add' ? 'ok' : 'error'}`}>{r.change === 'add' ? s.changes.add : s.changes.remove}</span>{' '}
                  {label(s.domains, r.domain_code)} · {label(s.ops, r.operation_code)}
                </li>
              ))}
          </ul>
        </div>
      ))}
    </div>
  )
}
