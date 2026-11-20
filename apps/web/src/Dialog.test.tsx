// @vitest-environment jsdom
import { act } from 'react'
import { createRoot, type Root } from 'react-dom/client'
import { afterEach, beforeEach, expect, test } from 'vitest'
import { useDialog } from './Dialog'
import { t } from './i18n'

Object.assign(globalThis, { IS_REACT_ACT_ENVIRONMENT: true })

let container: HTMLDivElement
let root: Root
let result: unknown

beforeEach(() => {
  result = 'pending'
  container = document.createElement('div')
  document.body.append(container)
  root = createRoot(container)
})

afterEach(() => {
  act(() => root.unmount())
  container.remove()
})

function Harness({ text, danger }: { text?: boolean; danger?: boolean }) {
  const { dialog, confirm, ask } = useDialog()
  const open = () => void (text ? ask({ title: 'Name it', label: 'Name', ok: 'Save' }) : confirm({ title: 'Delete it?', ok: 'Delete', danger })).then((v) => (result = v))
  return (
    <>
      <button id="opener" type="button" onClick={open}>
        open
      </button>
      {dialog}
    </>
  )
}

const btn = (text: string) => [...container.querySelectorAll<HTMLButtonElement>('[role="dialog"] button')].find((b) => b.textContent === text)!
async function show(props: { text?: boolean; danger?: boolean }) {
  await act(async () => root.render(<Harness {...props} />))
  const opener = container.querySelector<HTMLButtonElement>('#opener')!
  opener.focus()
  await act(async () => opener.click())
  return opener
}
const key = (k: string, shiftKey = false) => act(async () => document.activeElement!.dispatchEvent(new KeyboardEvent('keydown', { key: k, shiftKey, bubbles: true })))

test('confirm: a modal dialog; OK resolves true and focus goes back to the opener', async () => {
  const opener = await show({})
  const d = container.querySelector('[role="dialog"]')!
  expect(d.getAttribute('aria-modal')).toBe('true')
  expect(document.getElementById(d.getAttribute('aria-labelledby')!)?.textContent).toBe('Delete it?')
  expect(document.activeElement).toBe(btn('Delete'))
  await act(async () => btn('Delete').click())
  expect(result).toBe(true)
  expect(container.querySelector('[role="dialog"]')).toBeNull()
  expect(document.activeElement).toBe(opener)
})

test('danger confirm: red OK, focus starts on Cancel; Esc resolves false', async () => {
  const opener = await show({ danger: true })
  expect(btn('Delete').className).toContain('btn-danger')
  expect(document.activeElement).toBe(btn(t.dialog.cancel))
  await key('Escape')
  expect(result).toBe(false)
  expect(document.activeElement).toBe(opener)
})

test('focus trap: Tab from the last control goes to the first, Shift+Tab from the first to the last', async () => {
  await show({})
  await key('Tab')
  expect(document.activeElement).toBe(btn(t.dialog.cancel))
  await key('Tab', true)
  expect(document.activeElement).toBe(btn('Delete'))
})

test('text: OK stays off until something is typed; resolves the trimmed text, Cancel resolves undefined', async () => {
  await show({ text: true })
  const input = container.querySelector<HTMLInputElement>('[role="dialog"] input')!
  expect(document.activeElement).toBe(input)
  expect(btn('Save').disabled).toBe(true)
  await act(async () => {
    Object.getOwnPropertyDescriptor(HTMLInputElement.prototype, 'value')!.set!.call(input, '  Pumps  ')
    input.dispatchEvent(new Event('input', { bubbles: true }))
  })
  await act(async () => btn('Save').click())
  expect(result).toBe('Pumps')
  await act(async () => container.querySelector<HTMLButtonElement>('#opener')!.click())
  await act(async () => btn(t.dialog.cancel).click())
  expect(result).toBeUndefined()
})
