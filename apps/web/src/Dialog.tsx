import { useEffect, useId, useRef, useState, type KeyboardEvent, type ReactNode } from 'react'
import { t } from './i18n'

const g = t.dialog
const focusable = 'button:not(:disabled), [href], input:not(:disabled), select:not(:disabled), textarea:not(:disabled), [tabindex]:not([tabindex="-1"])'

// 11.3: the backdrop every modal sits in. Esc cancels, Tab stays inside, focus goes back to the opener on close.
export function Overlay({ onCancel, children }: { onCancel: () => void; children: ReactNode }) {
  const box = useRef<HTMLDivElement>(null)
  // Read during render: autoFocus inside has already moved focus by the time effects run.
  const [opener] = useState(() => document.activeElement as HTMLElement | null)
  useEffect(() => {
    if (!box.current?.contains(document.activeElement)) box.current?.querySelector<HTMLElement>(focusable)?.focus()
    return () => opener?.focus()
  }, [opener])

  function key(ev: KeyboardEvent) {
    if (ev.key === 'Escape') {
      ev.stopPropagation()
      return onCancel()
    }
    if (ev.key !== 'Tab' || !box.current) return
    const all = [...box.current.querySelectorAll<HTMLElement>(focusable)]
    const first = all[0]
    const last = all.at(-1)
    if (!first || !last) return
    if (ev.shiftKey ? document.activeElement === first : document.activeElement === last) {
      ev.preventDefault()
      ;(ev.shiftKey ? last : first).focus()
    }
  }

  return (
    <div className="overlay" ref={box} onKeyDown={key}>
      {children}
    </div>
  )
}

type Ask = { title: string; ok: string; body?: string; danger?: boolean; label?: string }
type Open = Ask & { text: boolean; done: (v: string | null) => void }

// The app's own confirm and text prompt (replaces window.confirm and window.prompt). Render `dialog` in the component.
export function useDialog() {
  const [open, setOpen] = useState<Open>()
  const show = (a: Ask, text: boolean) => new Promise<string | null>((done) => setOpen({ ...a, text, done }))
  const confirm = async (a: Ask) => (await show(a, false)) !== null
  const ask = async (a: Ask) => (await show(a, true))?.trim() || undefined
  const close = (v: string | null) => {
    setOpen(undefined)
    open?.done(v)
  }
  const dialog = open ? <AppDialog {...open} onClose={close} /> : null
  return { dialog, confirm, ask }
}

function AppDialog(props: Open & { onClose: (v: string | null) => void }) {
  const [value, setValue] = useState('')
  const id = useId()
  return (
    <Overlay onCancel={() => props.onClose(null)}>
      <form
        className="card dialog"
        role="dialog"
        aria-modal="true"
        aria-labelledby={`${id}-t`}
        onSubmit={(ev) => {
          ev.preventDefault()
          props.onClose(value)
        }}
      >
        <h2 id={`${id}-t`}>{props.title}</h2>
        {props.body && <p className="muted">{props.body}</p>}
        {props.text && (
          <label className="field">
            {props.label}
            <input name="text" value={value} autoFocus onChange={(ev) => setValue(ev.target.value)} />
          </label>
        )}
        <div className="page-head">
          <div className="spacer" />
          {/* A danger confirm starts on Cancel, so Enter does not delete. */}
          <button className="btn" type="button" autoFocus={!props.text && props.danger} onClick={() => props.onClose(null)}>
            {g.cancel}
          </button>
          <button className={props.danger ? 'btn btn-danger' : 'btn btn-main'} type="submit" autoFocus={!props.text && !props.danger} disabled={props.text && !value.trim()}>
            {props.ok}
          </button>
        </div>
      </form>
    </Overlay>
  )
}
