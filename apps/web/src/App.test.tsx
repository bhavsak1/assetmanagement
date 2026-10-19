// @vitest-environment jsdom
import { act } from 'react'
import { createRoot, type Root } from 'react-dom/client'
import { MemoryRouter } from 'react-router'
import { afterEach, beforeEach, expect, test, vi } from 'vitest'
import { App } from './App'
import { t } from './i18n'

type AuthCallback = (event: string, session: unknown) => void

const auth = vi.hoisted(() => ({
  listener: undefined as AuthCallback | undefined,
  signInWithPassword: vi.fn(),
  signOut: vi.fn(),
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

function render(path: string, session: unknown) {
  act(() =>
    root.render(
      <MemoryRouter initialEntries={[path]}>
        <App />
      </MemoryRouter>,
    ),
  )
  act(() => auth.listener?.('INITIAL_SESSION', session))
}

const heading = () => container.querySelector('h1')?.textContent

test('signed out: a protected route shows the login screen', () => {
  render('/assets', null)
  expect(heading()).toBe(t.pages.login)
  expect(container.textContent).not.toMatch(/SSO|forgot/i)
})

test('signed in: protected route renders, and sign out returns to login', () => {
  render('/assets', { user: {} })
  expect(heading()).toBe(t.pages.assets)
  act(() => auth.listener?.('SIGNED_OUT', null))
  expect(heading()).toBe(t.pages.login)
})

test('failed sign in shows one generic message', async () => {
  auth.signInWithPassword.mockResolvedValue({ error: { message: 'Invalid login credentials' } })
  render('/login', null)
  container.querySelector<HTMLInputElement>('[name="email"]')!.value = 'someone@example.com'
  container.querySelector<HTMLInputElement>('[name="password"]')!.value = 'wrong'
  await act(async () => container.querySelector('form')!.requestSubmit())
  expect(container.querySelector('[role="alert"]')?.textContent).toBe(t.login.error)
})
