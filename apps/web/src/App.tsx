import { NavLink, Navigate, Outlet, Route, Routes } from 'react-router'
import { t } from './i18n'

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
          <span className="muted">{t.topbar.tenant}</span>
          <div className="avatar" role="img" aria-label={t.topbar.account} />
        </header>
        <main className="content">
          <Outlet />
        </main>
      </div>
    </div>
  )
}

export function App() {
  return (
    <Routes>
      <Route path="/login" element={<EmptyPage page="login" />} />
      <Route element={<Shell />}>
        {navGroups.flatMap(({ items }) =>
          items.map((key) => <Route key={key} path={`/${key}`} element={<EmptyPage page={key} />} />),
        )}
        <Route path="/assets/:assetId" element={<EmptyPage page="assetDetail" />} />
      </Route>
      <Route path="*" element={<Navigate to="/dashboard" replace />} />
    </Routes>
  )
}
