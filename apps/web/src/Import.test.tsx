import { describe, expect, it, vi } from 'vitest'
import { columnLetter, uploadError } from './Import'
import { t } from './i18n'

vi.mock('./supabase', () => ({ supabase: {} }))

describe('import page helpers', () => {
  it('names columns like Excel', () => {
    expect([0, 25, 26, 199].map(columnLetter)).toEqual(['A', 'Z', 'AA', 'GR'])
  })

  it('maps service errors to messages', () => {
    expect(uploadError(413, 'too_many_rows')).toBe(t.import.errors.too_many_rows)
    expect(uploadError(403, 'forbidden')).toBe(t.import.errors.forbidden)
    expect(uploadError(401)).toBe(t.import.errors.forbidden)
    expect(uploadError(413)).toBe(t.import.errors.file_limits)
    expect(uploadError(0)).toBe(t.import.errors.generic)
  })
})
