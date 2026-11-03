// Builds small .xlsx files in memory for tests: the parts a reader needs, zipped by src/zip.ts.
import { zip } from '../src/zip.ts';

export { zip };

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
