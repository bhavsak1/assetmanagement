import { createContext, useContext } from 'react'

// Story 11.1 (d): the one place that turns dates, times, money and counts into text, from the tenant's settings.
// Without the tenant (still loading) dates show as stored and numbers in the browser's locale.
export type Fmt = { locale: string; date_format: string; time_zone: string }

// A date in one of the tenant date formats. Month names follow the tenant locale.
export function formatDate(date: Date, format: string, locale: string): string {
  const pad = (n: number) => String(n).padStart(2, '0')
  return format
    .replace('yyyy', String(date.getFullYear()))
    .replace('MMM', new Intl.DateTimeFormat(locale, { month: 'short' }).format(date))
    .replace('MM', pad(date.getMonth() + 1))
    .replace('dd', pad(date.getDate()))
}

// Plain dates as YYYY-MM-DD. "Today" is the tenant's (C7), so the day counts match the status the view computed.
export const tenantToday = (timeZone: string, now = new Date()) =>
  new Intl.DateTimeFormat('en-CA', { timeZone, year: 'numeric', month: '2-digit', day: '2-digit' }).format(now)

// A calendar date (YYYY-MM-DD, or the date part of a timestamp) in the tenant format. No time zone shift.
export const showDate = (d: string | null | undefined, tn?: Pick<Fmt, 'locale' | 'date_format'>) =>
  !d ? '—' : tn?.date_format ? formatDate(new Date(Number(d.slice(0, 4)), Number(d.slice(5, 7)) - 1, Number(d.slice(8, 10))), tn.date_format, tn.locale) : d

// A moment (timestamptz) as the tenant's calendar date and short clock time in the tenant's zone.
export function showDateTime(iso: string, tn?: Fmt): string {
  const at = new Date(iso)
  if (!tn?.date_format) return at.toLocaleString(undefined, { dateStyle: 'medium', timeStyle: 'short' })
  const time = new Intl.DateTimeFormat(tn.locale, { timeZone: tn.time_zone, timeStyle: 'short' }).format(at)
  return `${showDate(tenantToday(tn.time_zone, at), tn)} ${time}`
}

// A timestamp's calendar day in the tenant zone and format.
export const showDay = (iso: string | null | undefined, tn?: Fmt) => (!iso ? '—' : tn?.date_format ? showDate(tenantToday(tn.time_zone, new Date(iso)), tn) : iso.slice(0, 10))

export const showNumber = (n: number, tn?: Pick<Fmt, 'locale'>) => n.toLocaleString(tn?.locale)

// Amount with its own currency (no conversion, CLAUDE.md §8), grouped by the tenant locale: en-IN INR 350000 → ₹3,50,000.
// Whole amounts drop the decimals.
export function showMoney(v: number | string | null | undefined, currency: string | null | undefined, tn?: Pick<Fmt, 'locale'>): string {
  if (v == null || v === '') return '—'
  const n = Number(v)
  if (!currency) return n.toLocaleString(tn?.locale)
  const whole = Number.isInteger(n) ? { minimumFractionDigits: 0, maximumFractionDigits: 0 } : {}
  try {
    return new Intl.NumberFormat(tn?.locale, { style: 'currency', currency, ...whole }).format(n)
  } catch {
    // A code Intl does not know still shows, with the code after the amount.
    return `${n.toLocaleString(tn?.locale)} ${currency}`
  }
}

// The shell's tenant settings, for parts of a page that have no tenant of their own (Security, Import, Insights, Locations).
export const TenantFmt = createContext<Fmt | undefined>(undefined)
export const useFmt = () => useContext(TenantFmt)
