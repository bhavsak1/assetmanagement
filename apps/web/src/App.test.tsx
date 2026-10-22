// @vitest-environment jsdom
import { act } from 'react'
import { createRoot, type Root } from 'react-dom/client'
import { MemoryRouter } from 'react-router'
import { afterEach, beforeEach, expect, test, vi } from 'vitest'
import { App, safeNext } from './App'
import { t } from './i18n'

type AuthCallback = (event: string, session: unknown) => void

const auth = vi.hoisted(() => ({
  listener: undefined as AuthCallback | undefined,
  signInWithPassword: vi.fn(),
  signOut: vi.fn(),
  refreshSession: vi.fn(),
  rpc: vi.fn(),
  memberships: [] as { tenant_id: string; tenant: { name: string; status: string; deleted_at: null } }[],
  entitlements: [] as { id: string }[],
  // What RLS lets the user see in asset_view: an unknown id and another tenant's id both give no rows.
  assets: [] as { id: string; name: string }[],
}))

vi.mock('./supabase', () => ({
  supabase: {
    auth: {
      onAuthStateChange: (cb: AuthCallback) => {
        auth.listener = cb
        return { data: { subscription: { unsubscribe: () => {} } } }
      },
      signInWithPassword: auth.signInWithPassword,
      signOut: auth.signOut,
      refreshSession: auth.refreshSession,
    },
    rpc: auth.rpc,
    // Any query chain; awaiting it gives the mocked memberships or entitlements, else no rows
    // (my_permission: no grants).
    from: (table: string) => {
      const q: Record<string, unknown> = {}
      for (const m of ['select', 'eq', 'is', 'lte', 'or', 'order', 'limit']) q[m] = () => q
      const data = table === 'tenant_membership' ? auth.memberships : table === 'tenant_entitlement' ? auth.entitlements : table === 'asset_view' ? auth.assets : []
      q.then = (resolve: (v: unknown) => void) => resolve({ data, error: null })
      return q
    },
  },
}))

Object.assign(globalThis, { IS_REACT_ACT_ENVIRONMENT: true })

let root: Root
let container: HTMLDivElement

beforeEach(() => {
  container = document.createElement('div')
  document.body.append(container)
  root = createRoot(container)
})

afterEach(() => {
  act(() => root.unmount())
  container.remove()
})

const membership = (tenant_id: string, name: string) => ({ tenant_id, tenant: { name, status: 'active', deleted_at: null } })
// A session whose access token carries the given claims (unsigned; the app only decodes it).
const session = (claims: object = {}) => ({
  user: { id: 'u1' },
  access_token: `h.${btoa(JSON.stringify(claims)).replace(/=+$/, '')}.s`,
})

beforeEach(() => {
  auth.memberships = []
  auth.entitlements = []
  auth.assets = []
  auth.rpc.mockResolvedValue({ error: null })
  auth.refreshSession.mockResolvedValue({ error: null })
})

async function render(path: string, session: unknown) {
  act(() =>
    root.render(
      <MemoryRouter initialEntries={[path]}>
        <App />
      </MemoryRouter>,
    ),
  )
  // async act lets the membership query settle.
  await act(async () => auth.listener?.('INITIAL_SESSION', session))
}

const heading = () => container.querySelector('h1')?.textContent

test('signed out: a protected route shows the login screen', async () => {
  await render('/assets', null)
  expect(heading()).toBe(t.pages.login)
  expect(container.textContent).not.toMatch(/SSO|forgot/i)
})

test('signed in with a tenant: protected route renders, and sign out returns to login', async () => {
  auth.memberships = [membership('ta', 'Tenant A')]
  await render('/assets', session({ tenant_id: 'ta' }))
  expect(heading()).toBe(t.pages.assets)
  expect(container.textContent).toContain('Tenant A')
  act(() => auth.listener?.('SIGNED_OUT', null))
  expect(heading()).toBe(t.pages.login)
})

test('Ask Assetly and Intelligence show only with the AI add-on', async () => {
  auth.memberships = [membership('ta', 'Tenant A')]
  await render('/dashboard', session({ tenant_id: 'ta' }))
  expect(container.textContent).not.toContain(t.topbar.askAssetly)
  expect(container.textContent).not.toContain(t.nav.groups.intelligence)
  act(() => root.unmount())
  root = createRoot(container)
  auth.entitlements = [{ id: 'e1' }]
  await render('/dashboard', session({ tenant_id: 'ta' }))
  expect(container.textContent).toContain(t.topbar.askAssetly)
  expect(container.textContent).toContain(t.nav.groups.intelligence)
})

test('failed sign in shows one generic message', async () => {
  auth.signInWithPassword.mockResolvedValue({ error: { message: 'Invalid login credentials' } })
  await render('/login', null)
  container.querySelector<HTMLInputElement>('[name="email"]')!.value = 'someone@example.com'
  container.querySelector<HTMLInputElement>('[name="password"]')!.value = 'wrong'
  await act(async () => container.querySelector('form')!.requestSubmit())
  expect(container.querySelector('[role="alert"]')?.textContent).toBe(t.login.error)
})

test('no active membership: no access page, no tenant picked', async () => {
  await render('/dashboard', session())
  expect(heading()).toBe(t.company.noAccessTitle)
  expect(auth.rpc).not.toHaveBeenCalled()
})

test('one membership: picks it without asking, then refreshes the token', async () => {
  auth.memberships = [membership('ta', 'Tenant A')]
  await render('/dashboard', session())
  expect(auth.rpc).toHaveBeenCalledWith('select_tenant', { p_tenant_id: 'ta' })
  expect(auth.refreshSession).toHaveBeenCalled()
  await act(async () => auth.listener?.('TOKEN_REFRESHED', session({ tenant_id: 'ta' })))
  expect(heading()).toBe(t.pages.dashboard)
})

test('several memberships: Choose company, then the header switcher', async () => {
  auth.memberships = [membership('tb', 'Tenant B'), membership('ta', 'Tenant A')]
  await render('/dashboard', session())
  expect(heading()).toBe(t.company.chooseTitle)
  expect(auth.rpc).not.toHaveBeenCalled()
  const buttons = [...container.querySelectorAll('.company-list button')]
  expect(buttons.map((b) => b.textContent)).toEqual(['Tenant A', 'Tenant B'])
  await act(async () => (buttons[1] as HTMLButtonElement).click())
  expect(auth.rpc).toHaveBeenCalledWith('select_tenant', { p_tenant_id: 'tb' })

  await act(async () => auth.listener?.('TOKEN_REFRESHED', session({ tenant_id: 'tb' })))
  const select = container.querySelector<HTMLSelectElement>('select.company-switch')!
  expect(select.value).toBe('tb')
  select.value = 'ta'
  await act(async () => select.dispatchEvent(new Event('change', { bubbles: true })))
  expect(auth.rpc).toHaveBeenLastCalledWith('select_tenant', { p_tenant_id: 'ta' })
})

test('select_tenant refused: Choose company shows an error', async () => {
  auth.memberships = [membership('ta', 'Tenant A')]
  auth.rpc.mockResolvedValue({ error: { message: 'no access to tenant' } })
  await render('/dashboard', session())
  expect(container.querySelector('[role="alert"]')?.textContent).toBe(t.company.error)
  expect(auth.refreshSession).not.toHaveBeenCalled()
})

test('safeNext: same-app paths only', () => {
  expect(safeNext('/q/6f1c2d3e-0000-4000-8000-000000000001')).toBe('/q/6f1c2d3e-0000-4000-8000-000000000001')
  expect(safeNext('/assets?status=active')).toBe('/assets?status=active')
  for (const bad of [null, '', '//evil.com', 'https://evil.com', '/\\evil.com', '/\t/evil.com', 'evil.com', 'javascript:alert(1)', '/a\\b'])
    expect(safeNext(bad)).toBeUndefined()
})

test('scan signed out: login keeps the target, sign in lands on the asset', async () => {
  auth.memberships = [membership('ta', 'Tenant A')]
  auth.assets = [{ id: 'a1', name: 'Pump 1' }]
  await render('/q/a1', null)
  expect(heading()).toBe(t.pages.login)
  await act(async () => auth.listener?.('SIGNED_IN', session({ tenant_id: 'ta' })))
  expect(heading()).toBe('Pump 1')
})

test('scan with several companies: the pick comes first, then the asset', async () => {
  auth.memberships = [membership('tb', 'Tenant B'), membership('ta', 'Tenant A')]
  auth.assets = [{ id: 'a1', name: 'Pump 1' }]
  await render('/q/a1', session())
  expect(heading()).toBe(t.company.chooseTitle)
  await act(async () => auth.listener?.('TOKEN_REFRESHED', session({ tenant_id: 'ta' })))
  expect(heading()).toBe('Pump 1')
})

// RLS gives no rows for both (asset_view is covered by the 3.1 pgTAP cross-tenant tests), so the page
// must not tell them apart: no query other than asset_view decides what shows.
test('scan of an unknown or other-tenant id: the same not found', async () => {
  auth.memberships = [membership('ta', 'Tenant A')]
  await render('/q/00000000-0000-4000-8000-000000000000', session({ tenant_id: 'ta' }))
  const unknown = container.querySelector('main')?.innerHTML
  expect(container.textContent).toContain(t.assetDetail.notFound)
  act(() => root.unmount())
  root = createRoot(container)
  await render('/q/not-a-uuid', session({ tenant_id: 'ta' }))
  expect(container.querySelector('main')?.innerHTML).toBe(unknown)
})
