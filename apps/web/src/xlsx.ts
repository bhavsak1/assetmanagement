// A minimal one-sheet .xlsx writer for the import errors file (data-model-goal8.md §17.2).
// The zip is "stored" (no compression): the web app has no zip library, and CRC-32 is all a stored zip needs.

export type XlsxCell = string | number | boolean | null

const CRC = Array.from({ length: 256 }, (_, n) => {
  let c = n
  for (let k = 0; k < 8; k++) c = c & 1 ? 0xedb88320 ^ (c >>> 1) : c >>> 1
  return c >>> 0
})

export function crc32(b: Uint8Array): number {
  let c = 0xffffffff
  for (const x of b) c = CRC[(c ^ x) & 0xff]! ^ (c >>> 8)
  return (c ^ 0xffffffff) >>> 0
}

export function zipStored(files: Record<string, string>): Uint8Array<ArrayBuffer> {
  const enc = new TextEncoder()
  const local: Uint8Array[] = []
  const central: Uint8Array[] = []
  let offset = 0
  for (const [name, content] of Object.entries(files)) {
    const data = enc.encode(content)
    const fname = enc.encode(name)
    const crc = crc32(data)
    const head = new DataView(new ArrayBuffer(30))
    head.setUint32(0, 0x04034b50, true)
    head.setUint16(4, 20, true)
    head.setUint32(14, crc, true)
    head.setUint32(18, data.length, true)
    head.setUint32(22, data.length, true)
    head.setUint16(26, fname.length, true)
    const dir = new DataView(new ArrayBuffer(46))
    dir.setUint32(0, 0x02014b50, true)
    dir.setUint16(4, 20, true)
    dir.setUint16(6, 20, true)
    dir.setUint32(16, crc, true)
    dir.setUint32(20, data.length, true)
    dir.setUint32(24, data.length, true)
    dir.setUint16(28, fname.length, true)
    dir.setUint32(42, offset, true)
    local.push(new Uint8Array(head.buffer), fname, data)
    central.push(new Uint8Array(dir.buffer), fname)
    offset += 30 + fname.length + data.length
  }
  const dirSize = central.reduce((n, b) => n + b.length, 0)
  const end = new DataView(new ArrayBuffer(22))
  end.setUint32(0, 0x06054b50, true)
  end.setUint16(8, central.length / 2, true)
  end.setUint16(10, central.length / 2, true)
  end.setUint32(12, dirSize, true)
  end.setUint32(16, offset, true)
  const parts = [...local, ...central, new Uint8Array(end.buffer)]
  const out = new Uint8Array(parts.reduce((n, b) => n + b.length, 0))
  parts.reduce((at, b) => (out.set(b, at), at + b.length), 0)
  return out
}

const esc = (s: string) => s.replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;').replace(/"/g, '&quot;')
const colName = (i: number): string => (i >= 26 ? colName(Math.floor(i / 26) - 1) : '') + String.fromCharCode(65 + (i % 26))

// Text cells carry quotePrefix (style 1, bold header style 2): Excel keeps "=HYPERLINK(...)" as text even
// after an edit (§13.3), and the value read back on upload is unchanged.
function cellXml(v: XlsxCell, ref: string, header: boolean): string {
  if (v === null || v === '') return ''
  if (typeof v === 'number') return `<c r="${ref}"><v>${v}</v></c>`
  if (typeof v === 'boolean') return `<c r="${ref}" t="b"><v>${v ? 1 : 0}</v></c>`
  return `<c r="${ref}" t="inlineStr" s="${header ? 2 : 1}"><is><t xml:space="preserve">${esc(v)}</t></is></c>`
}

export function sheetXlsx(sheet: string, rows: XlsxCell[][]): Uint8Array<ArrayBuffer> {
  const main = 'http://schemas.openxmlformats.org/spreadsheetml/2006/main'
  const rel = 'http://schemas.openxmlformats.org/officeDocument/2006/relationships'
  const pkg = 'http://schemas.openxmlformats.org/package/2006/relationships'
  const data = rows
    .map((r, i) => `<row r="${i + 1}">${r.map((v, c) => cellXml(v, `${colName(c)}${i + 1}`, i === 0)).join('')}</row>`)
    .join('')
  return zipStored({
    '[Content_Types].xml': '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>'
      + '<Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">'
      + '<Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/>'
      + '<Default Extension="xml" ContentType="application/xml"/>'
      + '<Override PartName="/xl/workbook.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.sheet.main+xml"/>'
      + '<Override PartName="/xl/worksheets/sheet1.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.worksheet+xml"/>'
      + '<Override PartName="/xl/styles.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.styles+xml"/>'
      + '</Types>',
    '_rels/.rels': `<?xml version="1.0" encoding="UTF-8" standalone="yes"?><Relationships xmlns="${pkg}">`
      + `<Relationship Id="rId1" Type="${rel}/officeDocument" Target="xl/workbook.xml"/></Relationships>`,
    'xl/workbook.xml': `<?xml version="1.0" encoding="UTF-8" standalone="yes"?><workbook xmlns="${main}" xmlns:r="${rel}">`
      + `<sheets><sheet name="${esc(sheet)}" sheetId="1" r:id="rId1"/></sheets></workbook>`,
    'xl/_rels/workbook.xml.rels': `<?xml version="1.0" encoding="UTF-8" standalone="yes"?><Relationships xmlns="${pkg}">`
      + `<Relationship Id="rId1" Type="${rel}/worksheet" Target="worksheets/sheet1.xml"/>`
      + `<Relationship Id="rId2" Type="${rel}/styles" Target="styles.xml"/></Relationships>`,
    'xl/styles.xml': `<?xml version="1.0" encoding="UTF-8" standalone="yes"?><styleSheet xmlns="${main}">`
      + '<fonts count="2"><font><sz val="11"/><name val="Calibri"/></font><font><b/><sz val="11"/><name val="Calibri"/></font></fonts>'
      + '<fills count="2"><fill><patternFill patternType="none"/></fill><fill><patternFill patternType="gray125"/></fill></fills>'
      + '<borders count="1"><border><left/><right/><top/><bottom/><diagonal/></border></borders>'
      + '<cellStyleXfs count="1"><xf numFmtId="0" fontId="0" fillId="0" borderId="0"/></cellStyleXfs>'
      + '<cellXfs count="3"><xf numFmtId="0" fontId="0" fillId="0" borderId="0" xfId="0"/>'
      + '<xf numFmtId="0" fontId="0" fillId="0" borderId="0" xfId="0" quotePrefix="1"/>'
      + '<xf numFmtId="0" fontId="1" fillId="0" borderId="0" xfId="0" applyFont="1" quotePrefix="1"/></cellXfs>'
      + '<cellStyles count="1"><cellStyle name="Normal" xfId="0" builtinId="0"/></cellStyles></styleSheet>',
    'xl/worksheets/sheet1.xml': `<?xml version="1.0" encoding="UTF-8" standalone="yes"?><worksheet xmlns="${main}">`
      + '<sheetViews><sheetView workbookViewId="0"><pane ySplit="1" topLeftCell="A2" activePane="bottomLeft" state="frozen"/></sheetView></sheetViews>'
      + `<sheetData>${data}</sheetData></worksheet>`,
  })
}
