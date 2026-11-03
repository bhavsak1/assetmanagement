import { describe, expect, it, vi } from 'vitest'
import { applyTemplate, columnLetter, messageText, normalise, saveError, templateOf, uploadError, type Target } from './Import'
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

  it('saves a template by normalised header and applies it to moved columns', () => {
    const tpl = templateOf(['Asset Name', 'Grp', 'Column C', 'Notes'], [
      { target: 'name', source: 'rules' }, { target: 'category', source: 'user' },
      { target: 'ignore', source: 'rules' }, { target: 'ignore', source: 'rules' }])
    expect(tpl).toEqual({ headers: ['assetname', 'grp', 'notes'], targets: { assetname: 'name', grp: 'category' } })
    const catalog = ['name', 'category'].map((target) => ({ target }) as Target)
    expect(applyTemplate(['GRP', 'asset-name', 'Cost'], { ...tpl.targets, cost: 'purchase_value' }, catalog).map((e) => e.target))
      .toEqual(['category', 'name', 'ignore'])
    expect(normalise('O&M Vendor')).toBe('oandmvendor')
  })

  it('maps save errors to messages', () => {
    expect(saveError('mapping: name and category are required')).toBe(t.import.mapping.errors.required)
    expect(saveError('mapping: a target is used twice')).toBe(t.import.mapping.errors.twice)
    expect(saveError('mapping: unknown or not allowed target')).toBe(t.import.mapping.errors.stale)
  })

  it('words check messages from their code and params', () => {
    const catalog = [{ target: 'location', label: 'Location' } as Target]
    expect(messageText({ code: 'required', params: { field: 'location' } }, catalog)).toBe('Location is required.')
    expect(messageText({ col: 3, code: 'date_format', params: { format: 'dd-MM-yyyy' } }, catalog))
      .toBe('Not a date. Use an Excel date, YYYY-MM-DD or dd-MM-yyyy.')
    expect(messageText({ code: 'some_new_code' }, catalog)).toBe('some_new_code')
    // Every code import_validate can write has words.
    expect(Object.keys(t.import.check.codes)).toHaveLength(25)
  })
})
