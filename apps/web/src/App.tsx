import { useEffect, useRef, useState, type FormEvent, type ReactNode } from 'react'
import { Link, NavLink, Navigate, Outlet, Route, Routes, useLocation, useNavigate, useSearchParams } from 'react-router'
import { isAuthRetryableFetchError, type Session } from '@supabase/supabase-js'
import { AssetDetailPage } from './AssetDetail'
import { AssetFormPage } from './AssetForm'
import { AssetLabelPage, ScanPage } from './AssetLabel'
import { AssetsPage } from './Assets'
import { CategoriesPage } from './Categories'
import { CoveragePage } from './Coverage'
import { DashboardPage } from './Dashboard'
import { ImportPage } from './Import'
import { InsightsPage } from './Insights'
import { LocationsPage } from './Locations'
import { MaintenancePage } from './Maintenance'
import { NotificationBell, NotificationsPage } from './Notifications'
import { SettingsPage } from './Settings'
import { SecurityPage } from './Security'
import { VendorsPage } from './Vendors'
import { t } from './i18n'
import { supabase } from './supabase'

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

function Shell({ companies, tenantId, canImport, canAsk }: { companies: Company[]; tenantId: string; canImport: boolean; canAsk: boolean }) {
  const navigate = useNavigate()
  // Ask Assetly and the Intelligence group show only with the AI add-on (CLAUDE.md §11) and, from 10.7, insights_query.ask.
  const [ai, setAi] = useState<{ tenantId: string; on: boolean }>()
  useEffect(() => {
    let live = true
    void hasAiAddon().then((on) => live && setAi({ tenantId, on }))
    return () => {
      live = false
    }
  }, [tenantId])
  const aiOn = ai?.tenantId === tenantId && ai.on && canAsk

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
            {items.filter((key) => canImport || key !== 'import').map((key) => (
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
          {aiOn && <button className="btn" type="button" onClick={() => void navigate('/insights')}>{t.topbar.askAssetly}</button>}
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
          <NotificationBell tenantId={tenantId} />
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
  const [params] = useSearchParams()
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
      {params.get('reset') === 'done' && <p className="save-ok login-note">{t.reset.done}</p>}
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
      <Link className="login-link" to="/forgot-password">
        {t.login.forgot}
      </Link>
    </LoginFrame>
  )
}

// Story 9.1b. Supabase Auth sends the mail; the template links to /reset-password (docs/data-model-goal9.md §16).
export function ForgotPasswordPage() {
  const [state, setState] = useState<'idle' | 'busy' | 'sent' | 'failed'>('idle')

  async function send(e: FormEvent<HTMLFormElement>) {
    e.preventDefault()
    const email = String(new FormData(e.currentTarget).get('email'))
    setState('busy')
    const { error } = await supabase.auth.resetPasswordForEmail(email)
    // Same answer for success, unknown email and 429 (a 429 means the account exists) [F6]. Only a network failure differs.
    setState(error && isAuthRetryableFetchError(error) ? 'failed' : 'sent')
  }

  return (
    <LoginFrame title={t.reset.forgotTitle}>
      <p className="muted">{t.reset.forgotIntro}</p>
      {state === 'sent' ? (
        <p className="save-ok login-note" role="status">
          {t.reset.sent}
        </p>
      ) : (
        <form onSubmit={(e) => void send(e)}>
          <label className="field">
            {t.login.email}
            <input name="email" type="email" autoComplete="username" placeholder={t.login.emailPlaceholder} required />
          </label>
          {state === 'failed' && (
            <p className="login-error" role="alert">
              {t.reset.sendError}
            </p>
          )}
          <button className="btn btn-primary" type="submit" disabled={state === 'busy'}>
            {t.reset.send}
          </button>
        </form>
      )}
      <Link className="login-link" to="/login">
        {t.reset.backToLogin}
      </Link>
    </LoginFrame>
  )
}

export function ResetPasswordPage() {
  const [params] = useSearchParams()
  const navigate = useNavigate()
  const token_hash = params.get('type') === 'recovery' ? params.get('token_hash') : null
  const [state, setState] = useState<'checking' | 'ready' | 'bad' | 'busy'>(token_hash ? 'checking' : 'bad')
  const [error, setError] = useState<'mismatch' | 'weak'>()
  const verified = useRef(false)

  useEffect(() => {
    // The token is single use: React's dev double effect must not spend it twice.
    if (!token_hash || verified.current) return
    verified.current = true
    void supabase.auth.verifyOtp({ token_hash, type: 'recovery' }).then(({ error }) => setState(error ? 'bad' : 'ready'))
  }, [token_hash])

  async function save(e: FormEvent<HTMLFormElement>) {
    e.preventDefault()
    const form = new FormData(e.currentTarget)
    const password = String(form.get('password'))
    if (password !== String(form.get('confirm'))) return setError('mismatch')
    setError(undefined)
    setState('busy')
    const { error } = await supabase.auth.updateUser({ password })
    if (error) {
      setError('weak')
      setState('ready')
      return
    }
    // Sign out on every device, then sign in with the new password [F9].
    await supabase.auth.signOut({ scope: 'global' })
    void navigate('/login?reset=done', { replace: true })
  }

  if (state === 'checking') return null
  return (
    <LoginFrame title={t.reset.resetTitle}>
      {state === 'bad' ? (
        <>
          <p className="login-error" role="alert">
            {t.reset.badLink}
          </p>
          <Link className="login-link" to="/forgot-password">
            {t.reset.askAgain}
          </Link>
        </>
      ) : (
        <form onSubmit={(e) => void save(e)}>
          <label className="field">
            {t.reset.newPassword}
            <input name="password" type="password" autoComplete="new-password" required />
          </label>
          <label className="field">
            {t.reset.confirmPassword}
            <input name="confirm" type="password" autoComplete="new-password" required />
          </label>
          {error && (
            <p className="login-error" role="alert">
              {error === 'mismatch' ? t.reset.mismatch : t.reset.weak}
            </p>
          )}
          <button className="btn btn-primary" type="submit" disabled={state === 'busy'}>
            {t.reset.save}
          </button>
        </form>
      )}
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
    if (tenantId) signedIn = <Shell companies={companies} tenantId={tenantId} canImport={can('excel_import', 'run') || can('excel_import', 'review')} canAsk={can('insights_query', 'ask')} />
    else if (companies.length === 0) signedIn = <NoAccess />
    else signedIn = <ChooseCompany companies={companies} failed={pickFailed} onPick={pick} />
  }

  return (
    <Routes>
      <Route path="/login" element={session ? <Navigate to={safeNext(params.get('next')) ?? '/dashboard'} replace /> : <LoginPage />} />
      {/* Outside the sign-in guard: the recovery link signs the user in on this page [9.1b]. */}
      <Route path="/forgot-password" element={<ForgotPasswordPage />} />
      <Route path="/reset-password" element={<ResetPasswordPage />} />
      {/* The target page survives sign-in, and the company pick too (it renders in place) [3.6b]. */}
      <Route element={session ? signedIn : <Navigate to={`/login?next=${encodeURIComponent(location.pathname + location.search)}`} replace />}>
        <Route path="/insights" element={<InsightsPage />} />
        <Route path="/dashboard" element={<DashboardPage tenantId={tenantId ?? ''} can={can} />} />
        <Route
          path="/assets"
          element={
            <AssetsPage
              tenantId={tenantId ?? ''}
              canSaveViews={can('asset_core', 'view') && writable}
              canCreate={can('asset_core', 'create')}
              canCoverage={can('coverage_contract', 'view')}
            />
          }
        />
        <Route path="/assets/new" element={<AssetFormPage tenantId={tenantId ?? ''} can={can} />} />
        <Route path="/assets/:assetId/edit" element={<AssetFormPage tenantId={tenantId ?? ''} can={can} />} />
        <Route path="/maintenance" element={<MaintenancePage tenantId={tenantId ?? ''} can={can} />} />
        <Route path="/categories" element={<CategoriesPage tenantId={tenantId ?? ''} canManage={can('category_config', 'manage')} />} />
        <Route path="/vendors" element={<VendorsPage tenantId={tenantId ?? ''} can={can} />} />
        <Route path="/import" element={<ImportPage tenantId={tenantId ?? ''} canRun={can('excel_import', 'run')} canCommit={can('excel_import', 'commit')} canUndo={can('import_undo', 'undo')} canReview={can('excel_import', 'review')} />} />
        <Route path="/coverage" element={<CoveragePage tenantId={tenantId ?? ''} can={can} />} />
        <Route path="/locations" element={<LocationsPage tenantId={tenantId ?? ''} canManage={can('location_hierarchy', 'manage')} can={can} />} />
        <Route
          path="/settings"
          element={<SettingsPage tenantId={tenantId ?? ''} canView={can('tenant_settings', 'view')} canManage={can('tenant_settings', 'manage')} canViewAi={can('ai_usage', 'view')} />}
        />
        <Route path="/notifications" element={<NotificationsPage tenantId={tenantId ?? ''} userId={userId ?? ''} />} />
        <Route path="/security" element={<SecurityPage tenantId={tenantId ?? ''} canView={can('users_security', 'view')} canManage={can('users_security', 'manage')} canViewKeys={can('api_keys', 'view')} canManageKeys={can('api_keys', 'manage')} />} />
        <Route path="/assets/:assetId" element={<AssetDetailPage can={can} />} />
        <Route path="/assets/:assetId/label" element={<AssetLabelPage />} />
        <Route path="/q/:assetId" element={<ScanPage />} />
      </Route>
      <Route path="*" element={<Navigate to="/dashboard" replace />} />
    </Routes>
  )
}
