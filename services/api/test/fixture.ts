// Builds small .xlsx files in memory for tests: a minimal zip writer (stored + deflate) and the parts a reader needs.
import { crc32, deflateRawSync } from 'node:zlib';

export function zip(files: Record<string, string | Buffer>): Buffer {
  const local: Buffer[] = [];
  const central: Buffer[] = [];
  let offset = 0;
  for (const [name, content] of Object.entries(files)) {
    const raw = Buffer.from(content);
    const data = deflateRawSync(raw);
    const fname = Buffer.from(name);
    const head = Buffer.alloc(30);
    head.writeUInt32LE(0x04034b50, 0);
    head.writeUInt16LE(20, 4);
    head.writeUInt16LE(8, 8); // deflate
    head.writeUInt32LE(crc32(raw), 14);
    head.writeUInt32LE(data.length, 18);
    head.writeUInt32LE(raw.length, 22);
    head.writeUInt16LE(fname.length, 26);
    const dir = Buffer.alloc(46);
    dir.writeUInt32LE(0x02014b50, 0);
    dir.writeUInt16LE(20, 4);
    dir.writeUInt16LE(20, 6);
    dir.writeUInt16LE(8, 10);
    dir.writeUInt32LE(crc32(raw), 16);
    dir.writeUInt32LE(data.length, 20);
    dir.writeUInt32LE(raw.length, 24);
    dir.writeUInt16LE(fname.length, 28);
    dir.writeUInt32LE(offset, 42);
    local.push(head, fname, data);
    central.push(dir, fname);
    offset += head.length + fname.length + data.length;
  }
  const dirBuf = Buffer.concat(central);
  const end = Buffer.alloc(22);
  end.writeUInt32LE(0x06054b50, 0);
  end.writeUInt16LE(central.length / 2, 8);
  end.writeUInt16LE(central.length / 2, 10);
  end.writeUInt32LE(dirBuf.length, 12);
  end.writeUInt32LE(offset, 16);
  return Buffer.concat([...local, dirBuf, end]);
}

const esc = (s: string) => s.replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;').replace(/"/g, '&quot;');

// A cell: text (inline string), number, or raw <c> XML for anything else.
export type FCell = string | number | null | { xml: string };

export function sheetXml(rows: FCell[][], firstRow = 1): string {
  const body = rows.map((cells, i) => `<row r="${firstRow + i}">${cells.map((c) => {
    if (c === null) return '<c/>'; // keeps the column position
    if (typeof c === 'number') return `<c><v>${c}</v></c>`;
    if (typeof c === 'string') return `<c t="inlineStr"><is><t>${esc(c)}</t></is></c>`;
    return c.xml;
  }).join('')}</row>`).join('');
  return `<?xml version="1.0"?><worksheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main"><sheetData>${body}</sheetData></worksheet>`;
}

export type FSheet = { name: string; xml: string; hidden?: boolean };

// Style 1 is a built-in date (numFmt 14); style 2 a custom date and time format.
export function book(sheets: FSheet[], shared: string[] = []): Buffer {
  const ns = 'xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main" xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships"';
  const files: Record<string, string> = {
    'xl/workbook.xml': `<?xml version="1.0"?><workbook ${ns}><sheets>${sheets.map((s, i) =>
      `<sheet name="${esc(s.name)}" sheetId="${i + 1}" r:id="rId${i + 1}"${s.hidden ? ' state="hidden"' : ''}/>`).join('')}</sheets></workbook>`,
    'xl/_rels/workbook.xml.rels': `<?xml version="1.0"?><Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">${sheets.map((_, i) =>
      `<Relationship Id="rId${i + 1}" Type="worksheet" Target="worksheets/sheet${i + 1}.xml"/>`).join('')}</Relationships>`,
    'xl/styles.xml': `<?xml version="1.0"?><styleSheet ${ns}><numFmts count="1"><numFmt numFmtId="164" formatCode="dd/mm/yyyy\\ hh:mm"/></numFmts>`
      + '<cellXfs count="3"><xf numFmtId="0"/><xf numFmtId="14"/><xf numFmtId="164"/></cellXfs></styleSheet>',
    'xl/sharedStrings.xml': `<?xml version="1.0"?><sst ${ns}>${shared.map((s) => `<si><t>${esc(s)}</t></si>`).join('')}</sst>`,
  };
  sheets.forEach((s, i) => { files[`xl/worksheets/sheet${i + 1}.xml`] = s.xml; });
  return zip(files);
}

export const simple = (rows: FCell[][]) => book([{ name: 'Sheet1', xml: sheetXml(rows) }]);
