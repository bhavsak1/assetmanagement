// @vitest-environment jsdom
import { act } from 'react'
import { createRoot, type Root } from 'react-dom/client'
import { MemoryRouter } from 'react-router'
import { AuthApiError, AuthRetryableFetchError } from '@supabase/supabase-js'
import { afterEach, beforeEach, expect, test, vi } from 'vitest'
import { App, safeNext } from './App'
import { t } from './i18n'

type AuthCallback = (event: string, session: unknown) => void

const auth = vi.hoisted(() => ({
  listener: undefined as AuthCallback | undefined,
  signInWithPassword: vi.fn(),
  signOut: vi.fn(),
  refreshSession: vi.fn(),
  resetPasswordForEmail: vi.fn(),
  verifyOtp: vi.fn(),
  updateUser: vi.fn(),
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
      resetPasswordForEmail: auth.resetPasswordForEmail,
      verifyOtp: auth.verifyOtp,
      updateUser: auth.updateUser,
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
  expect(container.textContent).not.toMatch(/SSO/i)
  expect(container.querySelector('a[href="/forgot-password"]')?.textContent).toBe(t.login.forgot)
})

async function submitEmail(email: string) {
  container.querySelector<HTMLInputElement>('[name="email"]')!.value = email
  await act(async () => container.querySelector('form')!.requestSubmit())
}

test('forgot password: the same message whether or not the email exists, even on a 429 [9.1b F6]', async () => {
  for (const error of [null, new AuthApiError('For security purposes, you can only request this after 60 seconds.', 429, 'over_email_send_rate_limit')]) {
    auth.resetPasswordForEmail.mockResolvedValue({ data: {}, error })
    await render('/forgot-password', null)
    await submitEmail('someone@example.com')
    expect(auth.resetPasswordForEmail).toHaveBeenLastCalledWith('someone@example.com')
    expect(container.querySelector('[role="status"]')?.textContent).toBe(t.reset.sent)
    act(() => root.unmount())
    root = createRoot(container)
  }
})

test('forgot password: a network failure asks to try again', async () => {
  auth.resetPasswordForEmail.mockResolvedValue({ data: null, error: new AuthRetryableFetchError('Failed to fetch', 0) })
  await render('/forgot-password', null)
  await submitEmail('someone@example.com')
  expect(container.querySelector('[role="alert"]')?.textContent).toBe(t.reset.sendError)
})

test('reset password: a missing or used link shows one message and a way to ask again', async () => {
  await render('/reset-password', null)
  expect(container.querySelector('[role="alert"]')?.textContent).toBe(t.reset.badLink)
  expect(auth.verifyOtp).not.toHaveBeenCalled()
  act(() => root.unmount())
  root = createRoot(container)
  auth.verifyOtp.mockResolvedValue({ data: {}, error: new AuthApiError('Token has expired or is invalid', 403, 'otp_expired') })
  await render('/reset-password?token_hash=h1&type=recovery', null)
  expect(container.querySelector('[role="alert"]')?.textContent).toBe(t.reset.badLink)
  expect(container.querySelector('a[href="/forgot-password"]')).not.toBeNull()
})

test('reset password: verify once, check the match, set it, sign out everywhere [9.1b F9]', async () => {
  auth.verifyOtp.mockResolvedValue({ data: {}, error: null })
  auth.updateUser.mockResolvedValueOnce({ data: {}, error: new AuthApiError('Password should be at least 6 characters.', 422, 'weak_password') })
  auth.updateUser.mockResolvedValueOnce({ data: {}, error: null })
  auth.signOut.mockResolvedValue({ error: null })
  await render('/reset-password?token_hash=h1&type=recovery', null)
  expect(auth.verifyOtp).toHaveBeenCalledTimes(1)
  expect(auth.verifyOtp).toHaveBeenCalledWith({ token_hash: 'h1', type: 'recovery' })
  expect(heading()).toBe(t.reset.resetTitle)
  const fill = async (a: string, b: string) => {
    container.querySelector<HTMLInputElement>('[name="password"]')!.value = a
    container.querySelector<HTMLInputElement>('[name="confirm"]')!.value = b
    await act(async () => container.querySelector('form')!.requestSubmit())
  }
  await fill('new-pass-1', 'new-pass-2')
  expect(container.querySelector('[role="alert"]')?.textContent).toBe(t.reset.mismatch)
  expect(auth.updateUser).not.toHaveBeenCalled()
  await fill('short', 'short')
  expect(container.querySelector('[role="alert"]')?.textContent).toBe(t.reset.weak)
  await fill('new-pass-1', 'new-pass-1')
  expect(auth.updateUser).toHaveBeenLastCalledWith({ password: 'new-pass-1' })
  expect(auth.signOut).toHaveBeenCalledWith({ scope: 'global' })
  expect(heading()).toBe(t.pages.login)
  expect(container.textContent).toContain(t.reset.done)
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
