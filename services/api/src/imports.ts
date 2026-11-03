// Stages one sheet of an uploaded .xlsx into import_batch and import_row (docs/data-model-goal8.md §13).
// Runs inside withUser, so RLS (excel_import.run, tenant_can_write) decides every insert.
import { createHash } from 'node:crypto';
import type { Query } from './db.ts';
import { suggestFor, type Suggestion } from './mapping.ts';
import { columnName, ImportError, openXlsx, type Cell, type Row, type Warning } from './xlsx.ts';

export const MAX_ROWS = 20_000;
export const HEADER_SCAN = 20; // header row is looked for among the first 20 sheet rows (I4)
const CHUNK = 1000;
const MAX_WARNINGS = 50;
const SAMPLES = 20; // rows handed to the mappers (§14.2)

export type StageResult = {
  batch_id: string;
  sheet: string;
  sheets: string[];
  header_row: number;
  columns: string[];
  row_count: number;
  warnings: { list: (Warning | { code: 'beyond_header'; column: number })[]; total: number };
  mapping: Suggestion[];
  mapping_template_id: string | null;
};

// The row with the most text cells wins; ties go to the earlier row.
export function pickHeader(rows: Row[]): Row | undefined {
  let best: Row | undefined;
  let bestCount = 0;
  for (const r of rows) {
    if (r.row > HEADER_SCAN) break;
    const n = r.cells.filter((c) => typeof c === 'string').length;
    if (n > bestCount) { best = r; bestCount = n; }
  }
  return best ?? rows[0];
}

// Header text as found; blanks become "Column C", repeats become "Name (2)".
export function headerNames(cells: Cell[]): string[] {
  const seen = new Map<string, number>();
  return cells.map((c, i) => {
    const base = c === null ? `Column ${columnName(i)}` : String(c).trim() || `Column ${columnName(i)}`;
    const n = (seen.get(base.toLowerCase()) ?? 0) + 1;
    seen.set(base.toLowerCase(), n);
    return n === 1 ? base : `${base} (${n})`;
  });
}

// headerRow (M10): the user's choice of header row, else pickHeader.
export async function stageXlsx(q: Query, file: Buffer, fileName: string, sheetParam?: string, headerRow?: number): Promise<StageResult> {
  const book = await openXlsx(file);
  if (sheetParam !== undefined && !book.sheets.includes(sheetParam)) throw new ImportError('sheet_not_found');

  const warnings: StageResult['warnings'] = { list: [], total: 0 };
  const warn = (w: StageResult['warnings']['list'][number]) => {
    warnings.total++;
    if (warnings.list.length < MAX_WARNINGS) warnings.list.push(w);
  };

  // I3: the named sheet, else the first visible sheet with data.
  let sheet = '';
  let it: AsyncGenerator<Row> | undefined;
  const head: Row[] = [];
  for (const name of sheetParam !== undefined ? [sheetParam] : book.sheets) {
    it = book.rows(name, warn);
    for (let r = await it.next(); !r.done; r = await it.next()) {
      head.push(r.value);
      if (r.value.row >= HEADER_SCAN) break;
    }
    if (head.length) { sheet = name; break; }
    warnings.list.length = warnings.total = 0;
  }
  const header = headerRow === undefined ? pickHeader(head) : head.find((r) => r.row === headerRow);
  if (!it || !head.length) throw new ImportError('no_data');
  if (!header) throw new ImportError('bad_header_row');
  const columns = headerNames(header.cells);
  const batchId = crypto.randomUUID();

  let rowCount = 0;
  const samples: Cell[][] = [];
  let chunk: Row[] = [];
  const flush = async () => {
    if (!chunk.length) return;
    // import_row.batch_id is a deferred FK: rows go first, the batch with its final counts last.
    await q(
      `insert into public.import_row (tenant_id, batch_id, row_number, cells)
       select private.current_tenant_id(), $1, r, c from unnest($2::int[], $3::jsonb[]) as t (r, c)`,
      [batchId, chunk.map((r) => r.row), chunk.map((r) => JSON.stringify(r.cells))],
    );
    chunk = [];
  };
  const add = async (r: Row) => {
    if (r.row <= header.row) return; // the header and title rows above it are not data
    if (++rowCount > MAX_ROWS) throw new ImportError('too_many_rows', 413);
    for (let i = columns.length; i < r.cells.length; i++) {
      if (r.cells[i] === null) continue;
      columns.push(`Column ${columnName(i)}`);
      warn({ code: 'beyond_header', column: i });
    }
    if (samples.length < SAMPLES) samples.push(r.cells);
    chunk.push(r);
    if (chunk.length >= CHUNK) await flush();
  };
  for (const r of head) await add(r);
  for (let r = await it.next(); !r.done; r = await it.next()) await add(r.value);
  await flush();

  // A suggestion only: the batch stays 'staged' until the user saves through import_save_mapping (M4).
  const { mapping, template_id } = await suggestFor(q, columns, samples);
  await q(
    `insert into public.import_batch (id, tenant_id, file_name, file_size, file_sha256, sheet_name, sheet_names,
                                      header_row, columns, row_count, warnings, mapping, mapping_template_id)
     values ($1, private.current_tenant_id(), $2, $3, $4, $5, $6, $7, $8, $9, $10, $11, $12)`,
    [batchId, fileName, file.length, createHash('sha256').update(file).digest('hex'), sheet, book.sheets,
      header.row, columns, rowCount, JSON.stringify(warnings), JSON.stringify(mapping), template_id],
  );
  return { batch_id: batchId, sheet, sheets: book.sheets, header_row: header.row, columns, row_count: rowCount, warnings,
    mapping, mapping_template_id: template_id };
}
