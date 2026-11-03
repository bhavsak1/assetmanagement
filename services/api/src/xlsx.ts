// Reads one sheet of an .xlsx file as a stream of rows (docs/data-model-goal8.md §13.3, I5).
// The file is untrusted: formulas are never evaluated (only the saved value is read), XML entities are
// never expanded (a DOCTYPE refuses the file), and every part has a size limit on the bytes actually inflated.
import path from 'node:path';
import type { Readable } from 'node:stream';
import { SaxesParser, type SaxesTagPlain } from 'saxes';
import yauzl from 'yauzl';

export const LIMITS = {
  entries: 1000,
  sheetBytes: 100 * 2 ** 20, // streamed, never held
  partBytes: 30 * 2 ** 20, // shared strings, styles, workbook: held in memory
  columns: 200,
  cellChars: 4000,
};

export class ImportError extends Error {
  readonly code: string;
  readonly status: number;
  constructor(code: string, status = 400) {
    super(code);
    this.code = code;
    this.status = status;
  }
}

export type Cell = string | number | boolean | null;
export type Warning = { code: 'cell_truncated' | 'error_cell'; row: number; column: number };
export type Row = { row: number; cells: Cell[] };
export type Workbook = {
  sheets: string[]; // visible sheets, in workbook order
  rows: (sheet: string, warn: (w: Warning) => void) => AsyncGenerator<Row>;
};

const local = (name: string) => name.slice(name.indexOf(':') + 1); // some writers prefix tags (x:row)

// Excel escapes characters XML cannot carry as _xHHHH_. Control characters (bar tab and newline) and
// NUL are dropped: Postgres text refuses NUL and none of them belong in a register.
export function cleanText(s: string): string {
  return s
    .replace(/_x([0-9a-fA-F]{4})_/g, (_, h: string) => String.fromCharCode(parseInt(h, 16)))
    .replace(/\r\n?/g, '\n')
    // eslint-disable-next-line no-control-regex -- stripping control characters is the point
    .replace(/[\u0000-\u0008\u000B-\u001F\u007F]/g, '');
}

// Built-in date formats (ECMA-376 18.8.30) or a custom code with date or time letters outside quotes,
// brackets ([Red], [$₹-4009]) and escapes.
export function isDateFormat(id: number, code?: string): boolean {
  if ((id >= 14 && id <= 22) || (id >= 27 && id <= 36) || (id >= 45 && id <= 47) || (id >= 50 && id <= 58)) return true;
  if (!code) return false;
  return /[dmyhs]/i.test(code.replace(/"[^"]*"|\[[^\]]*\]|\\.|_.|\*./g, ''));
}

export function serialToIso(serial: number, date1904: boolean, withTime: boolean): string {
  const seconds = Math.round((serial - 25569 + (date1904 ? 1462 : 0)) * 86400);
  const iso = new Date(seconds * 1000).toISOString();
  return withTime ? iso.slice(0, 19) : iso.slice(0, 10);
}

export function columnIndex(ref: string): number {
  let n = 0;
  for (const ch of ref) {
    const c = ch.charCodeAt(0);
    if (c < 65 || c > 90) break;
    n = n * 26 + (c - 64);
  }
  return n - 1; // A = 0
}

export function columnName(index: number): string {
  let s = '';
  for (let n = index + 1; n > 0; n = Math.floor((n - 1) / 26)) s = String.fromCharCode(65 + ((n - 1) % 26)) + s;
  return s;
}

export async function openXlsx(buf: Buffer): Promise<Workbook> {
  if (buf.length < 4 || buf.readUInt32LE(0) !== 0x04034b50) throw new ImportError('not_xlsx', 415); // PK\3\4
  let zip: yauzl.ZipFile;
  const entries = new Map<string, yauzl.Entry>();
  try {
    zip = await new Promise<yauzl.ZipFile>((ok, ko) =>
      yauzl.fromBuffer(buf, { lazyEntries: true, validateEntrySizes: true, autoClose: false }, (e, z) => (e ? ko(e) : ok(z))));
    if (zip.entryCount > LIMITS.entries) throw new ImportError('file_limits', 413);
    await new Promise<void>((ok, ko) => {
      zip.on('entry', (e: yauzl.Entry) => { entries.set(e.fileName, e); zip.readEntry(); });
      zip.on('end', ok);
      zip.on('error', ko);
      zip.readEntry();
    });
  } catch (e) {
    throw e instanceof ImportError ? e : new ImportError('bad_file');
  }

  // Streams one part through a SAX parser; setup() pushes results into out, which is drained after each chunk.
  async function* part<T>(name: string, limit: number, setup: (p: SaxesParser, out: T[]) => void): AsyncGenerator<T> {
    const entry = entries.get(name);
    if (!entry) return;
    if (entry.uncompressedSize > limit) throw new ImportError('file_limits', 413);
    const p = new SaxesParser();
    p.on('doctype', () => { throw new ImportError('bad_file'); });
    const out: T[] = [];
    setup(p, out);
    let stream: Readable | undefined;
    try {
      stream = await new Promise<Readable>((ok, ko) => zip.openReadStream(entry, (e, s) => (e ? ko(e) : ok(s))));
      stream.setEncoding('utf8'); // decodes multi-byte characters split across chunks
      let size = 0;
      for await (const chunk of stream as AsyncIterable<string>) {
        size += chunk.length;
        if (size > limit) throw new ImportError('file_limits', 413);
        p.write(chunk);
        yield* out.splice(0);
      }
      p.close();
      yield* out.splice(0);
    } catch (e) {
      throw e instanceof ImportError ? e : new ImportError('bad_file');
    } finally {
      stream?.destroy();
    }
  }

  async function all<T>(name: string, setup: (p: SaxesParser, out: T[]) => void): Promise<T[]> {
    const list: T[] = [];
    for await (const x of part(name, LIMITS.partBytes, setup)) list.push(x);
    return list;
  }

  // shortcut: assumes the workbook at xl/workbook.xml (Excel, LibreOffice, Google Sheets); read _rels/.rels if a writer differs.
  type SheetRef = { name: string; rid: string; hidden: boolean } | { date1904: true };
  const book = await all<SheetRef>('xl/workbook.xml', (p, out) => p.on('opentag', (t: SaxesTagPlain) => {
    const n = local(t.name);
    if (n === 'workbookPr' && /^(1|true)$/.test(t.attributes.date1904 ?? '')) out.push({ date1904: true });
    if (n === 'sheet') {
      const rid = Object.entries(t.attributes).find(([k]) => local(k) === 'id')?.[1] ?? '';
      out.push({ name: cleanText(t.attributes.name ?? ''), rid, hidden: !!t.attributes.state && t.attributes.state !== 'visible' });
    }
  }));
  const date1904 = book.some((s) => 'date1904' in s);
  const sheetRefs = book.filter((s): s is Extract<SheetRef, { name: string }> => 'name' in s);
  if (!sheetRefs.length) throw new ImportError('bad_file');

  const rels = new Map((await all<[string, string]>('xl/_rels/workbook.xml.rels', (p, out) => p.on('opentag', (t: SaxesTagPlain) => {
    if (local(t.name) === 'Relationship' && t.attributes.Id && t.attributes.Target) out.push([t.attributes.Id, t.attributes.Target]);
  }))).map(([id, target]) => [id, target.startsWith('/') ? target.slice(1) : path.posix.normalize('xl/' + target)]));

  // Shared strings: <si><t>…</t></si> or rich runs <si><r><t>…</t></r>…</si>; phonetic hints (<rPh>) are skipped.
  const shared = await all<string>('xl/sharedStrings.xml', (p, out) => {
    let text: string | null = null;
    let inT = false;
    let skip = 0;
    p.on('opentag', (t: SaxesTagPlain) => {
      const n = local(t.name);
      if (n === 'si') text = '';
      else if (n === 'rPh') skip++;
      else if (n === 't' && !skip) inT = true;
    });
    p.on('text', (s) => { if (inT && text !== null) text += s; });
    p.on('cdata', (s) => { if (inT && text !== null) text += s; });
    p.on('closetag', (t: SaxesTagPlain) => {
      const n = local(t.name);
      if (n === 't') inT = false;
      else if (n === 'rPh') skip--;
      else if (n === 'si') { out.push(text ?? ''); text = null; }
    });
  });

  // Styles: which cell formats (the s attribute indexes cellXfs) show a number as a date, and with a time.
  const formats = new Map<number, string>();
  const xfs = await all<number>('xl/styles.xml', (p, out) => {
    let inXfs = false;
    p.on('opentag', (t: SaxesTagPlain) => {
      const n = local(t.name);
      if (n === 'numFmt') formats.set(Number(t.attributes.numFmtId), t.attributes.formatCode ?? '');
      else if (n === 'cellXfs') inXfs = true;
      else if (n === 'xf' && inXfs) out.push(Number(t.attributes.numFmtId ?? 0));
    });
    p.on('closetag', (t: SaxesTagPlain) => { if (local(t.name) === 'cellXfs') inXfs = false; });
  });
  const dateStyle = xfs.map((id) => {
    const code = formats.get(id);
    if (!isDateFormat(id, code)) return 0;
    const time = (id >= 18 && id <= 22) || (id >= 45 && id <= 47) || /[hs]/i.test((code ?? '').replace(/"[^"]*"|\[[^\]]*\]|\\./g, ''));
    return time ? 2 : 1; // 1 date, 2 date and time
  });

  const byName = new Map(sheetRefs.filter((s) => !s.hidden).map((s) => [s.name, rels.get(s.rid)]));

  async function* rows(sheet: string, warn: (w: Warning) => void): AsyncGenerator<Row> {
    const file = byName.get(sheet);
    if (!file) throw new ImportError('sheet_not_found');
    yield* part<Row>(file, LIMITS.sheetBytes, (p, out) => {
      let rowNum = 0;
      let cells: Cell[] = [];
      let col = -1;
      let type = '';
      let style = 0;
      let value: string | null = null;
      let inValue = false;
      let skip = 0;
      p.on('opentag', (t: SaxesTagPlain) => {
        const n = local(t.name);
        if (n === 'row') {
          rowNum = Number(t.attributes.r) || rowNum + 1;
          cells = [];
          col = -1;
        } else if (n === 'c') {
          col = t.attributes.r ? columnIndex(t.attributes.r) : col + 1;
          type = t.attributes.t ?? 'n';
          style = Number(t.attributes.s ?? 0);
          value = null;
        } else if (n === 'rPh') skip++;
        else if ((n === 'v' || n === 't') && !skip) { inValue = true; value ??= ''; }
      });
      const onText = (s: string) => { if (inValue) value += s; };
      p.on('text', onText);
      p.on('cdata', onText);
      p.on('closetag', (t: SaxesTagPlain) => {
        const n = local(t.name);
        if (n === 'v' || n === 't') inValue = false;
        else if (n === 'rPh') skip--;
        else if (n === 'c') {
          const cell = toCell(type, value, style);
          if (cell === null) return;
          if (col >= LIMITS.columns || col < 0) throw new ImportError('too_many_columns', 413);
          cells[col] = cell;
        } else if (n === 'row' && cells.length) {
          out.push({ row: rowNum, cells: Array.from(cells, (c) => c ?? null) });
        }
      });
      function toCell(t: string, v: string | null, s: number): Cell {
        if (v === null || v === '') return null;
        switch (t) {
          case 's': return text(shared[Number(v)] ?? null);
          case 'b': return v === '1';
          case 'e': warn({ code: 'error_cell', row: rowNum, column: col }); return null;
          case 'str': case 'inlineStr': case 'd': return text(v);
          default: {
            const num = Number(v);
            if (!Number.isFinite(num)) return text(v);
            return dateStyle[s] ? serialToIso(num, date1904, dateStyle[s] === 2) : num;
          }
        }
      }
      function text(raw: string | null): Cell {
        if (raw === null) return null;
        let s = cleanText(raw);
        if (s.length > LIMITS.cellChars) {
          s = s.slice(0, LIMITS.cellChars);
          warn({ code: 'cell_truncated', row: rowNum, column: col });
        }
        return s === '' ? null : s;
      }
    });
  }

  return { sheets: [...byName.keys()], rows };
}
