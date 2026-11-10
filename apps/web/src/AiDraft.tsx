// Story 10.9: a chat draft from POST /ai/assist, carried in router state (never the URL) to the user's own form or
// dialog. Prefilled fields show "AI-suggested"; Save first opens a confirm step that lists what will be written,
// and only Confirm runs today's save path (owner, 10 Nov 2026). Forms opened by hand never see any of this.
import { createContext, useContext, useEffect, useState, type RefObject } from 'react'
import { useLocation } from 'react-router'
import { t } from './i18n'
import { supabase } from './supabase'

const c = t.aiDraft

export type Option = { id: string; label: string }
export type Note = { text: string; options?: string[] }
export type Draft = {
  ai_call_id: string
  intent: 'create_asset' | 'update_asset' | 'transfer_asset' | 'change_status'
  values: Record<string, string>
  notes: Record<string, Note>
  asset_text?: string
  asset?: Option
  asset_choices?: Option[]
}

// Where each draft opens: the 3.3 form, or Asset detail with its 3.5 / 3.7 dialog.
export function draftPath(d: Draft, assetId: string): string {
  if (d.intent === 'create_asset') return '/assets/new'
  return d.intent === 'update_asset' ? `/assets/${assetId}/edit` : `/assets/${assetId}`
}

// The draft this page was opened with, if it is for this intent and asset. Read once: a reload or a later visit
// opens the plain form.
export function useDraft(intents: Draft['intent'][], assetId?: string): Draft | undefined {
  const state = useLocation().state as { draft?: Draft } | null
  const [d] = useState(state?.draft)
  return d && intents.includes(d.intent) && (d.intent === 'create_asset' || d.asset?.id === assetId) ? d : undefined
}

// §6.4: the outcome on the user's own ai_call. Best effort: a lost log line must never block the user.
export async function outcome(id: string, value: 'saved' | 'discarded') {
  try {
    const token = (await supabase.auth.getSession()).data.session?.access_token ?? ''
    await fetch(`${import.meta.env.VITE_API_URL}/insights/outcome`, {
      method: 'POST',
      headers: { Authorization: `Bearer ${token}`, 'Content-Type': 'application/json' },
      body: JSON.stringify({ ai_call_id: id, outcome: value }),
    })
  } catch {
    // best effort, as above
  }
}

// 'discarded' when the page closes without a confirmed save.
export function useDiscardOnLeave(draft: Draft | undefined, saved: RefObject<boolean>) {
  useEffect(() => () => {
    if (draft && !saved.current) void outcome(draft.ai_call_id, 'discarded')
  }, [draft, saved])
}

// Which fields still hold the AI's value (a field leaves the set when the user edits it), and the name notes.
export const AiMarks = createContext<{ keys: Set<string>; notes: Record<string, Note> }>({ keys: new Set(), notes: {} })

export const fill = (s: string, vars: Record<string, string>) => s.replace(/\{(\w+)\}/g, (_, k: string) => vars[k] ?? '')

export function noteText(n: Note): string {
  if (!n.options) return fill(c.matched, { text: n.text })
  return n.options.length ? fill(c.several, { text: n.text, options: n.options.join(', ') }) : fill(c.notFound, { text: n.text })
}

// Shown next to a field's label: the tag while the AI value stands, and what a name matched.
export function AiMark({ name }: { name: string }) {
  const { keys, notes } = useContext(AiMarks)
  const note = notes[name]
  return (
    <>
      {keys.has(name) && <span className="tag warn">{c.tag}</span>}
      {note && <span className="muted hint">{noteText(note)}</span>}
    </>
  )
}

export type Line = { label: string; from?: string; to: string }

// The confirm step: the action, then each value to be written (old → new on a change). Confirm runs the save.
export function ConfirmDialog(props: { title: string; lines: Line[]; busy: boolean; error?: string; onConfirm: () => void; onCancel: () => void }) {
  return (
    <div className="overlay" onKeyDown={(ev) => ev.key === 'Escape' && props.onCancel()}>
      <div className="card dialog" role="dialog" aria-modal="true" aria-labelledby="ai-confirm-title">
        <h2 id="ai-confirm-title">{props.title}</h2>
        <p className="muted">{c.check}</p>
        {props.error && (
          <p className="login-error" role="alert">
            {props.error}
          </p>
        )}
        <table>
          <tbody>
            {props.lines.map((l) => (
              <tr key={l.label}>
                <th scope="row">{l.label}</th>
                <td>{l.from === undefined ? l.to : fill(c.change, { from: l.from || c.empty, to: l.to || c.empty })}</td>
              </tr>
            ))}
          </tbody>
        </table>
        <div className="page-head">
          <div className="spacer" />
          <button className="btn" type="button" onClick={props.onCancel}>
            {c.cancel}
          </button>
          <button className="btn btn-main" type="button" autoFocus disabled={props.busy} onClick={props.onConfirm}>
            {c.confirm}
          </button>
        </div>
      </div>
    </div>
  )
}
