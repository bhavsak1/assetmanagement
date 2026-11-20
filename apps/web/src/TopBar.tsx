import { useEffect, useId, useRef, useState, type KeyboardEvent } from 'react'
import { useNavigate } from 'react-router'
import { StatusTag } from './Assets'
import { t } from './i18n'
import { supabase } from './supabase'

const b = t.topbar
export const SEARCH_MIN = 2
export const SEARCH_MAX = 100
export const SEARCH_HITS = 6

// Story 11.1 (c). "Krunal Bhavsar" → KB, "Ravi" → RA; no name → the email's local part. Array.from keeps
// letters outside the BMP whole.
export function initials(name: string | null | undefined, email: string | null | undefined): string {
  const words = (name?.trim() || email?.split('@')[0] || '').split(/[\s._-]+/).filter(Boolean)
  const first = Array.from(words[0] ?? '')
  const last = Array.from(words.length > 1 ? (words[words.length - 1] ?? '') : '')
  return (last.length ? `${first[0] ?? ''}${last[0]}` : first.slice(0, 2).join('')).toLocaleUpperCase() || '?'
}

// Collapsed main menu (11.1), per user on this browser. Storage can be blocked: then it is just not remembered.
const collapseKey = (userId: string) => `assetly.nav.collapsed.${userId}`
export function readCollapsed(userId: string): boolean {
  try {
    return localStorage.getItem(collapseKey(userId)) === '1'
  } catch {
    return false
  }
}
export function writeCollapsed(userId: string, on: boolean) {
  try {
    localStorage.setItem(collapseKey(userId), on ? '1' : '0')
  } catch {
    // Not remembered; the toggle still works.
  }
}

type Hit = { id: string | null; tag: string | null; name: string | null; status: string | null; status_id: string | null }

// Story 11.1 (b). Assets by tag, name or serial through list_assets(), so RLS, scope and masking apply as the user;
// the term goes as a bound argument and the database escapes LIKE wildcards (3.2). Enter with no row picked opens the list.
export function TopSearch() {
  const navigate = useNavigate()
  const id = useId()
  const [text, setText] = useState('')
  const [open, setOpen] = useState(false)
  const [active, setActive] = useState(-1)
  const [found, setFound] = useState<{ term: string; rows: Hit[] }>()
  const term = text.trim().slice(0, SEARCH_MAX)
  const ready = term.length >= SEARCH_MIN

  useEffect(() => {
    if (!ready) return
    let live = true
    const timer = setTimeout(() => {
      void supabase.rpc('list_assets', { p_term: term, p_limit: SEARCH_HITS }).then(({ data }) => live && setFound({ term, rows: (data ?? []).slice(0, SEARCH_HITS) }))
    }, 250)
    return () => {
      live = false
      clearTimeout(timer)
    }
  }, [term, ready])

  const rows = ready && found?.term === term ? found.rows : undefined
  // The last option is "all results", so mouse users get what Enter does.
  const count = rows ? rows.length + 1 : 0
  const showList = open && ready

  function go(i: number) {
    const hit = rows?.[i]
    setOpen(false)
    setActive(-1)
    void navigate(hit?.id ? `/assets/${hit.id}` : `/assets?q=${encodeURIComponent(term)}`)
  }

  function onKey(e: KeyboardEvent<HTMLInputElement>) {
    if (e.key === 'ArrowDown' || e.key === 'ArrowUp') {
      e.preventDefault()
      setOpen(true)
      if (count) setActive((a) => (e.key === 'ArrowDown' ? (a + 1) % count : (a - 1 + count) % count))
    } else if (e.key === 'Enter' && ready) {
      e.preventDefault()
      go(active)
    } else if (e.key === 'Escape') {
      setOpen(false)
      setActive(-1)
    }
  }

  const optionId = (i: number) => `${id}-o${i}`
  return (
    <div className="top-search">
      <input
        className="search"
        type="search"
        role="combobox"
        placeholder={b.search}
        aria-label={b.search}
        aria-expanded={showList}
        aria-controls={`${id}-list`}
        aria-autocomplete="list"
        aria-activedescendant={showList && active >= 0 ? optionId(active) : undefined}
        maxLength={SEARCH_MAX}
        value={text}
        onChange={(e) => {
          setText(e.target.value)
          setOpen(true)
          setActive(-1)
        }}
        onFocus={() => setOpen(true)}
        onBlur={() => setOpen(false)}
        onKeyDown={onKey}
      />
      {showList && (
        <ul className="search-list" id={`${id}-list`} role="listbox" aria-label={b.searchResults}>
          {!rows ? (
            <li className="muted" role="presentation">{b.searching}</li>
          ) : (
            <>
              {rows.length === 0 && <li className="muted" role="presentation">{b.searchNone}</li>}
              {rows.map((r, i) => (
                <li key={r.id ?? i} id={optionId(i)} role="option" aria-selected={active === i} onMouseDown={(e) => e.preventDefault()} onClick={() => go(i)}>
                  <b>{r.tag}</b> <span>{r.name}</span> <StatusTag statuses={[]} id={null} system={r.status} />
                </li>
              ))}
              <li id={optionId(rows.length)} role="option" aria-selected={active === rows.length} className="search-all" onMouseDown={(e) => e.preventDefault()} onClick={() => go(rows.length)}>
                {b.searchAll.replace('{q}', term)}
              </li>
            </>
          )}
        </ul>
      )}
    </div>
  )
}

// Story 11.1 (c): a disclosure button, not an ARIA menu, so Tab and Enter work as usual. Esc or a click outside closes it.
export function AccountMenu({ name, email, company }: { name?: string | null; email?: string | null; company?: string }) {
  const [open, setOpen] = useState(false)
  const box = useRef<HTMLDivElement>(null)
  const button = useRef<HTMLButtonElement>(null)
  const id = useId()

  useEffect(() => {
    if (!open) return
    const outside = (e: MouseEvent) => !box.current?.contains(e.target as Node) && setOpen(false)
    const esc = (e: globalThis.KeyboardEvent) => {
      if (e.key !== 'Escape') return
      setOpen(false)
      button.current?.focus()
    }
    document.addEventListener('mousedown', outside)
    document.addEventListener('keydown', esc)
    return () => {
      document.removeEventListener('mousedown', outside)
      document.removeEventListener('keydown', esc)
    }
  }, [open])

  return (
    <div className="account" ref={box}>
      <button ref={button} className="avatar" type="button" aria-label={b.account} aria-expanded={open} aria-controls={id} onClick={() => setOpen(!open)}>
        {initials(name, email)}
      </button>
      {open && (
        <div className="account-menu card" id={id}>
          <strong>{name || email}</strong>
          {name && <span className="muted">{email}</span>}
          {company && <span className="muted">{company}</span>}
          <button className="btn" type="button" onClick={() => void supabase.auth.signOut()}>
            {b.signOut}
          </button>
        </div>
      )}
    </div>
  )
}
