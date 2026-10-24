import { useEffect, useState, type FormEvent, type ReactNode } from 'react'
import { NavLink, Navigate, Outlet, Route, Routes, useLocation, useSearchParams } from 'react-router'
import type { Session } from '@supabase/supabase-js'
import { AssetDetailPage } from './AssetDetail'
import { AssetFormPage } from './AssetForm'
import { AssetLabelPage, ScanPage } from './AssetLabel'
import { AssetsPage } from './Assets'
import { CategoriesPage } from './Categories'
import { LocationsPage } from './Locations'
import { SettingsPage } from './Settings'
import { VendorsPage } from './Vendors'
import { t } from './i18n'
import { supabase } from './supabase'

type PageKey = keyof typeof t.pages
type Company = { id: string; name: string; status: string }

// Where to go after sign-in: only a path in this app. '//host' and '/\host' leave the origin, and browsers drop
// tabs and newlines, so only printable ASCII without a backslash passes (no open redirect).
export const safeNext = (next: string | null) => (next && /^\/(?![/\\])[\x21-\x5b\x5d-\x7e]*$/.test(next) ? next : undefined)

// tenant_id and permission_version are added by the JWT hook once select_tenant() ran for this
// login session [D3]. Read here only to route and to know when to reload grants; RLS checks the signed token itself.
function tokenClaims(session: Session): { tenant_id?: string; permission_version?: number } {
  const payload = (session.access_token.split('.')[1] ?? '').replace(/-/g, '+').replace(/_/g, '/')
  return JSON.parse(atob(payload)) as { tenant_id?: string; permission_version?: number }
}

// The user's own grants in the active tenant, as 'domain.operation'. Only hides or disables actions;
// the database enforces them (CLAUDE.md §7.2).
async function loadPermissions(): Promise<Set<string>> {
  const { data } = await supabase.from('my_permission').select('domain, operation')
  return new Set((data ?? []).map((p) => `${p.domain}.${p.operation}`))
}

// The user's own active memberships in tenants they can open. The user_id filter matters:
// a tenant admin can also read other members' rows (1.3).
async function loadCompanies(userId: string): Promise<Company[]> {
  const { data } = await supabase
    .from('tenant_membership')
    .select('tenant_id, tenant(name, status, deleted_at)')
    .eq('user_id', userId)
    .eq('status', 'active')
    .is('deleted_at', null)
  return (data ?? [])
    .flatMap(({ tenant_id, tenant }) =>
      tenant && tenant.status !== 'suspended' && !tenant.deleted_at
        ? [{ id: tenant_id, name: tenant.name, status: tenant.status }]
        : [],
    )
    .sort((a, b) => a.name.localeCompare(b.name))
}

// select_tenant() records the choice for this session; the refresh makes the hook put it in the token.
async function openCompany(id: string): Promise<boolean> {
  const { error } = await supabase.rpc('select_tenant', { p_tenant_id: id })
  return !error && !(await supabase.auth.refreshSession()).error
}

// The AI add-on is a live tenant_entitlement row (OQ-30). RLS shows only the active tenant's rows.
async function hasAiAddon(): Promise<boolean> {
  const now = new Date().toISOString()
  const { data } = await supabase
    .from('tenant_entitlement')
    .select('id')
    .eq('feature_code', 'ai_addon')
    .is('deleted_at', null)
    .lte('valid_from', now)
    .or(`valid_to.is.null,valid_to.gt.${now}`)
    .limit(1)
  return !!data?.length
}

// Sidebar groups and order follow docs/assetly-screens.html. Each item's route is /<key>.
const navGroups = [
  { group: 'operate', items: ['dashboard', 'assets', 'maintenance', 'locations'] },
  { group: 'manage', items: ['vendors', 'coverage', 'categories', 'import'] },
  { group: 'intelligence', items: ['insights'] },
  { group: 'admin', items: ['security', 'settings'] },
] as const

function EmptyPage({ page }: { page: PageKey }) {
  return (
    <>
      <title>{`${t.pages[page]} · ${t.app.name}`}</title>
      <h1>{t.pages[page]}</h1>
      <p className="muted">{t.pages.empty}</p>
    </>
  )
}

function Shell({ companies, tenantId }: { companies: Company[]; tenantId: string }) {
  // Ask Assetly and the Intelligence group show only with the AI add-on (CLAUDE.md §11).
  const [ai, setAi] = useState<{ tenantId: string; on: boolean }>()
  useEffect(() => {
    let live = true
    void hasAiAddon().then((on) => live && setAi({ tenantId, on }))
    return () => {
      live = false
    }
  }, [tenantId])
  const aiOn = ai?.tenantId === tenantId && ai.on

  return (
    <div className="app">
      <nav className="sidebar" aria-label={t.nav.label}>
        <div className="logo">
          <i aria-hidden="true" />
          {t.app.name}
        </div>
        {navGroups.filter(({ group }) => aiOn || group !== 'intelligence').map(({ group, items }) => (
          <div key={group} className="nav-group">
            <div className="nav-heading">{t.nav.groups[group]}</div>
            {items.map((key) => (
              <NavLink key={key} to={`/${key}`}>
                {t.nav[key]}
              </NavLink>
            ))}
          </div>
        ))}
      </nav>
      <div className="main">
        <header className="topbar">
          <input className="search" type="search" placeholder={t.topbar.search} aria-label={t.topbar.search} />
          {aiOn && <button className="btn" type="button">{t.topbar.askAssetly}</button>}
          <div className="spacer" />
          {companies.length > 1 ? (
            <select
              className="company-switch"
              aria-label={t.company.switch}
              value={tenantId}
              onChange={(e) => void openCompany(e.target.value)}
            >
              {companies.map((c) => (
                <option key={c.id} value={c.id}>
                  {c.name}
                </option>
              ))}
            </select>
          ) : (
            <span className="muted">{companies.find((c) => c.id === tenantId)?.name}</span>
          )}
          <div className="avatar" role="img" aria-label={t.topbar.account}>
            {t.topbar.initials}
          </div>
          <button className="btn" type="button" onClick={() => void supabase.auth.signOut()}>
            {t.topbar.signOut}
          </button>
        </header>
        <main className="content">
          <Outlet />
        </main>
      </div>
    </div>
  )
}

// Same frame as the login screen: brand panel left, content right.
function LoginFrame({ title, children }: { title: string; children: ReactNode }) {
  return (
    <div className="login">
      <title>{`${title} · ${t.app.name}`}</title>
      <div className="login-brand">
        <div className="login-logo">{t.app.name}</div>
        <div>
          <div className="login-headline">{t.login.headline}</div>
          <p>{t.login.tagline}</p>
        </div>
        <div className="login-footer">{t.login.footer}</div>
      </div>
      <div className="login-panel">
        <div className="login-form">
          <h1>{title}</h1>
          {children}
        </div>
      </div>
    </div>
  )
}

function ChooseCompany({ companies, failed, onPick }: { companies: Company[]; failed: boolean; onPick: (id: string) => void }) {
  return (
    <LoginFrame title={t.company.chooseTitle}>
      <p className="muted">{t.company.chooseIntro}</p>
      <div className="company-list">
        {companies.map((c) => (
          <button key={c.id} className="btn" type="button" onClick={() => onPick(c.id)}>
            {c.name}
          </button>
        ))}
      </div>
      {failed && (
        <p className="login-error" role="alert">
          {t.company.error}
        </p>
      )}
      <button className="btn" type="button" onClick={() => void supabase.auth.signOut()}>
        {t.topbar.signOut}
      </button>
    </LoginFrame>
  )
}

function NoAccess() {
  return (
    <LoginFrame title={t.company.noAccessTitle}>
      <p className="muted">{t.company.noAccess}</p>
      <button className="btn" type="button" onClick={() => void supabase.auth.signOut()}>
        {t.topbar.signOut}
      </button>
    </LoginFrame>
  )
}

function LoginPage() {
  const [failed, setFailed] = useState(false)
  const [busy, setBusy] = useState(false)

  async function signIn(e: FormEvent<HTMLFormElement>) {
    e.preventDefault()
    const form = new FormData(e.currentTarget)
    setBusy(true)
    const { error } = await supabase.auth.signInWithPassword({
      email: String(form.get('email')),
      password: String(form.get('password')),
    })
    // One message for every failure, so it never reveals whether the email exists (CLAUDE.md §13).
    setFailed(Boolean(error))
    setBusy(false)
  }

  return (
    <LoginFrame title={t.pages.login}>
      <p className="muted">{t.login.welcome}</p>
      <form onSubmit={(e) => void signIn(e)}>
        <label className="field">
          {t.login.email}
          <input name="email" type="email" autoComplete="username" placeholder={t.login.emailPlaceholder} required />
        </label>
        <label className="field">
          {t.login.password}
          <input name="password" type="password" autoComplete="current-password" placeholder="••••••••" required />
        </label>
        {failed && (
          <p className="login-error" role="alert">
            {t.login.error}
          </p>
        )}
        <button className="btn btn-primary" type="submit" disabled={busy}>
          {t.pages.login}
        </button>
      </form>
    </LoginFrame>
  )
}

export function App() {
  const location = useLocation()
  const [params] = useSearchParams()
  // undefined until Supabase reports the stored session; it fires INITIAL_SESSION on subscribe.
  const [session, setSession] = useState<Session | null>()

  useEffect(() => {
    const { data } = supabase.auth.onAuthStateChange((_event, s) => setSession(s))
    return () => data.subscription.unsubscribe()
  }, [])

  // Keyed by user so a sign-out or another user never sees the previous list.
  const [loaded, setLoaded] = useState<{ userId: string; companies: Company[] }>()
  const [pickFailed, setPickFailed] = useState(false)
  const userId = session?.user.id
  const claims = session ? tokenClaims(session) : {}
  const tenantId = claims.tenant_id
  const companies = userId && loaded?.userId === userId ? loaded.companies : undefined

  // Reloaded on login, company switch, and when the token's permission_version moves [D4].
  const permKey = tenantId ? `${userId}:${tenantId}:${claims.permission_version}` : undefined
  const [perms, setPerms] = useState<{ key: string; set: Set<string> }>()
  useEffect(() => {
    if (!permKey) return
    let live = true
    void loadPermissions().then((set) => live && setPerms({ key: permKey, set }))
    return () => {
      live = false
    }
  }, [permKey])
  const writable = companies?.find((c) => c.id === tenantId)?.status === 'active'
  const can = (domain: string, operation: string) =>
    perms?.key === permKey && !!perms?.set.has(`${domain}.${operation}`) && (operation === 'view' || writable)

  useEffect(() => {
    if (!userId) return
    let live = true
    void loadCompanies(userId).then((c) => live && setLoaded({ userId, companies: c }))
    return () => {
      live = false
    }
  }, [userId])

  function pick(id: string) {
    setPickFailed(false)
    void openCompany(id).then((ok) => setPickFailed(!ok))
  }

  // One company: open it without asking [D3]. Several: the Choose company screen.
  const only = !tenantId && companies?.length === 1 ? companies[0]?.id : undefined
  useEffect(() => {
    if (only) void openCompany(only).then((ok) => setPickFailed(!ok))
  }, [only])

  if (session === undefined) return null

  let signedIn = null
  if (session && companies) {
    if (tenantId) signedIn = <Shell companies={companies} tenantId={tenantId} />
    else if (companies.length === 0) signedIn = <NoAccess />
    else signedIn = <ChooseCompany companies={companies} failed={pickFailed} onPick={pick} />
  }

  return (
    <Routes>
      <Route path="/login" element={session ? <Navigate to={safeNext(params.get('next')) ?? '/dashboard'} replace /> : <LoginPage />} />
      {/* The target page survives sign-in, and the company pick too (it renders in place) [3.6b]. */}
      <Route element={session ? signedIn : <Navigate to={`/login?next=${encodeURIComponent(location.pathname + location.search)}`} replace />}>
        {navGroups.flatMap(({ items }) =>
          items
            .filter((key) => key !== 'assets' && key !== 'categories' && key !== 'locations' && key !== 'settings' && key !== 'vendors')
            .map((key) => <Route key={key} path={`/${key}`} element={<EmptyPage page={key} />} />),
        )}
        <Route
          path="/assets"
          element={
            <AssetsPage
              tenantId={tenantId ?? ''}
              canSaveViews={can('asset_core', 'view') && writable}
              canCreate={can('asset_core', 'create')}
            />
          }
        />
        <Route path="/assets/new" element={<AssetFormPage tenantId={tenantId ?? ''} can={can} />} />
        <Route path="/assets/:assetId/edit" element={<AssetFormPage tenantId={tenantId ?? ''} can={can} />} />
        <Route path="/categories" element={<CategoriesPage tenantId={tenantId ?? ''} canManage={can('category_config', 'manage')} />} />
        <Route path="/vendors" element={<VendorsPage tenantId={tenantId ?? ''} can={can} />} />
        <Route path="/locations" element={<LocationsPage tenantId={tenantId ?? ''} canManage={can('location_hierarchy', 'manage')} />} />
        <Route
          path="/settings"
          element={<SettingsPage tenantId={tenantId ?? ''} canView={can('tenant_settings', 'view')} canManage={can('tenant_settings', 'manage')} />}
        />
        <Route path="/assets/:assetId" element={<AssetDetailPage can={can} />} />
        <Route path="/assets/:assetId/label" element={<AssetLabelPage />} />
        <Route path="/q/:assetId" element={<ScanPage />} />
      </Route>
      <Route path="*" element={<Navigate to="/dashboard" replace />} />
    </Routes>
  )
}
