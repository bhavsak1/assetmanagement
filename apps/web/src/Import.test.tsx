import { describe, expect, it, vi } from 'vitest'
import { actError, aiError, applyTemplate, mergeAi, codeName, columnLetter, commitWill, errorRows, messageText, normalise, saveError, templateOf, uploadError, type Target } from './Import'
import { t } from './i18n'
import { crc32, sheetXlsx } from './xlsx'

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

  it('10.3: AI targets fill only rule-unmapped columns with a free field; refusals without a fix stay silent', () => {
    const cur = [{ target: 'name', source: 'rules' }, { target: 'ignore', source: 'rules' }, { target: 'ignore', source: 'user' },
      { target: 'ignore', source: 'rules' }, { target: 'ignore', source: 'rules' }] as const
    const ai = [{ target: 'name', source: 'rules' }, { target: 'category', source: 'ai', confidence: 0.9 },
      { target: 'location', source: 'ai', confidence: 0.8 }, { target: 'name', source: 'ai', confidence: 0.7 },
      { target: 'ignore', source: 'rules' }] as const
    expect(mergeAi([...cur], [...ai]).map((e) => `${e.target}/${e.source}`))
      .toEqual(['name/rules', 'category/ai', 'ignore/user', 'ignore/rules', 'ignore/rules'])
    expect(aiError('ai_cap_reached')).toBe(t.import.mapping.aiErrors.ai_cap_reached)
    expect([aiError('ai_not_licensed'), aiError('ai_off'), aiError('ai_no_right'), aiError()]).toEqual([undefined, undefined, undefined, undefined])
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

  it('says what commit would do with each row (8.5)', () => {
    expect(commitWill(null)).toBe(t.import.review.skip)
    expect(commitWill({ asset: { name: 'Pump' } })).toBe(t.import.review.create)
    expect(commitWill({ asset: { name: 'Pump' }, coverage: { vendor_id: 'v' } })).toBe(t.import.review.createWithWarranty)
    expect(codeName('required')).toBe('… is required.')
  })

  it('builds the errors file from the rows as they were, plus a Problems column (8.5 R2)', () => {
    const catalog = [{ target: 'category', label: 'Category' } as Target]
    const rows = errorRows(['Name', 'Cat', 'Cost'], [
      { cells: ['=HYPERLINK("x")', 'Pumpz', 1200], messages: [{ col: 1, code: 'not_found' }, { code: 'required', params: { field: 'category' } }] },
      { cells: ['Fan', null], messages: [] },
    ], catalog)
    expect(rows).toEqual([
      ['Name', 'Cat', 'Cost', t.import.review.problems],
      ['=HYPERLINK("x")', 'Pumpz', 1200, `B · Cat: ${t.import.check.codes.not_found}
Category is required.`],
      ['Fan', null, null, ''],
    ])
  })

  it('maps commit and undo errors to messages (8.6)', () => {
    const e = t.import.commit.errors
    expect(actError(413, 'too_many_rows')).toBe(e.too_many_rows)
    expect(actError(409, 'changed')).toBe(e.changed)
    expect(actError(401)).toBe(e.forbidden)
    expect(actError(0)).toBe(e.generic)
  })

  it('writes a stored zip with the right CRC and formula-safe text cells', () => {
    expect(crc32(new TextEncoder().encode('123456789'))).toBe(0xcbf43926)
    const file = sheetXlsx('Assets', [['Name', 'Qty'], ['=1+1', 2], [true, null]])
    expect([...file.slice(0, 4)]).toEqual([0x50, 0x4b, 0x03, 0x04])
    const text = new TextDecoder().decode(file)
    expect(text).toContain('<c r="A2" t="inlineStr" s="1"><is><t xml:space="preserve">=1+1</t></is></c><c r="B2"><v>2</v></c>')
    expect(text).toContain('<c r="A3" t="b"><v>1</v></c></row>')
    expect(text).toContain('quotePrefix="1"')
  })
})
