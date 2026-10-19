import { useEffect, useState, type FormEvent } from 'react'
import { NavLink, Navigate, Outlet, Route, Routes } from 'react-router'
import type { Session } from '@supabase/supabase-js'
import { t } from './i18n'
import { supabase } from './supabase'

type PageKey = keyof typeof t.pages

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

function Shell() {
  return (
    <div className="app">
      <nav className="sidebar" aria-label={t.nav.label}>
        <div className="logo">
          <i aria-hidden="true" />
          {t.app.name}
        </div>
        {navGroups.map(({ group, items }) => (
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
          <button className="btn" type="button">{t.topbar.askAssetly}</button>
          <div className="spacer" />
          {/* Tenant name goes here once tenants exist. */}
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
    <div className="login">
      <title>{`${t.pages.login} · ${t.app.name}`}</title>
      <div className="login-brand">
        <div className="login-logo">{t.app.name}</div>
        <div>
          <div className="login-headline">{t.login.headline}</div>
          <p>{t.login.tagline}</p>
        </div>
        <div className="login-footer">{t.login.footer}</div>
      </div>
      <div className="login-panel">
        <form className="login-form" onSubmit={(e) => void signIn(e)}>
          <h1>{t.pages.login}</h1>
          <p className="muted">{t.login.welcome}</p>
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
      </div>
    </div>
  )
}

export function App() {
  // undefined until Supabase reports the stored session; it fires INITIAL_SESSION on subscribe.
  const [session, setSession] = useState<Session | null>()

  useEffect(() => {
    const { data } = supabase.auth.onAuthStateChange((_event, s) => setSession(s))
    return () => data.subscription.unsubscribe()
  }, [])

  if (session === undefined) return null

  return (
    <Routes>
      <Route path="/login" element={session ? <Navigate to="/dashboard" replace /> : <LoginPage />} />
      <Route element={session ? <Shell /> : <Navigate to="/login" replace />}>
        {navGroups.flatMap(({ items }) =>
          items.map((key) => <Route key={key} path={`/${key}`} element={<EmptyPage page={key} />} />),
        )}
        <Route path="/assets/:assetId" element={<EmptyPage page="assetDetail" />} />
      </Route>
      <Route path="*" element={<Navigate to="/dashboard" replace />} />
    </Routes>
  )
}
