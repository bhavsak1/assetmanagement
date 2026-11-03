// The .xlsx reader on its own: no database (data-model-goal8.md §13.3).
import assert from 'node:assert/strict';
import { test } from 'node:test';
import { headerNames, pickHeader } from '../src/imports.ts';
import { ImportError, isDateFormat, LIMITS, openXlsx, type Row, type Warning } from '../src/xlsx.ts';
import { book, sheetXml, simple, zip } from './fixture.ts';

async function read(buf: Buffer, sheet?: string) {
  const wb = await openXlsx(buf);
  const warnings: Warning[] = [];
  const rows: Row[] = [];
  for await (const r of wb.rows(sheet ?? wb.sheets[0]!, (w) => warnings.push(w))) rows.push(r);
  return { sheets: wb.sheets, rows, warnings };
}

const refused = (code: string) => (e: unknown) => e instanceof ImportError && e.code === code;

test('cell types: shared, inline, number, boolean, dates, errors, formulas', async () => {
  const xml = sheetXml([[
    { xml: '<c r="A1" t="s"><v>1</v></c>' },
    { xml: '<c r="B1" t="inlineStr"><is><r><t>Air </t></r><r><t>pump</t></r></is></c>' },
    { xml: '<c r="C1"><v>42.5</v></c>' },
    { xml: '<c r="D1" t="b"><v>1</v></c>' },
    { xml: '<c r="E1" s="1"><v>45839</v></c>' },
    { xml: '<c r="F1" s="2"><v>45839.5</v></c>' },
    { xml: '<c r="G1" t="e"><v>#N/A</v></c>' },
    // A formula: only the saved value is read, never the formula.
    { xml: '<c r="H1" t="str"><f>HYPERLINK("http://x","y")</f><v>y</v></c>' },
    // Text that looks like a formula stays as the text it is (escaped on export, §13.3).
    '=HYPERLINK("http://evil","click")',
    { xml: '<c r="K1" t="s"><v>99</v></c>' },
  ]]);
  const { rows, warnings } = await read(book([{ name: 'S', xml }], ['zero', 'Pump']));
  assert.deepEqual(rows, [{ row: 1, cells: ['Pump', 'Air pump', 42.5, true, '2025-07-01', '2025-07-01T12:00:00', null, 'y', '=HYPERLINK("http://evil","click")'] }]);
  assert.deepEqual(warnings, [{ code: 'error_cell', row: 1, column: 6 }]);
});

test('text is cleaned: NUL and control characters dropped, _xHHHH_ decoded, long cells cut', async () => {
  const long = 'x'.repeat(LIMITS.cellChars + 10);
  // Raw control characters are invalid XML; Excel writes them as _xHHHH_.
  const { rows, warnings } = await read(simple([['a_x0001_b_x0000__x000D_\nc', long]]));
  assert.equal(rows[0]!.cells[0], 'ab\nc');
  assert.equal((rows[0]!.cells[1] as string).length, LIMITS.cellChars);
  assert.deepEqual(warnings, [{ code: 'cell_truncated', row: 1, column: 1 }]);
});

test('empty rows are skipped; sparse cells keep their columns', async () => {
  const xml = sheetXml([[null, null], [{ xml: '<c r="C3"><v>7</v></c>' }]], 2);
  const { rows } = await read(book([{ name: 'S', xml }]));
  assert.deepEqual(rows, [{ row: 3, cells: [null, null, 7] }]);
});

test('hidden sheets are not listed', async () => {
  const { sheets } = await read(book([{ name: 'Old', xml: sheetXml([['x']]), hidden: true }, { name: 'Assets', xml: sheetXml([['y']]) }]));
  assert.deepEqual(sheets, ['Assets']);
});

test('date formats', () => {
  assert.ok(isDateFormat(14));
  assert.ok(isDateFormat(164, 'dd/mm/yyyy'));
  assert.ok(!isDateFormat(164, '#,##0.00'));
  assert.ok(!isDateFormat(164, '[$₹-4009] #,##0'));
  assert.ok(!isDateFormat(164, '0.00 "days"'));
});

test('header: the fullest text row in the first 20, skipping a title row', () => {
  const rows: Row[] = [
    { row: 1, cells: ['Asset register, Pune plant'] },
    { row: 3, cells: ['Name', 'Tag', null, 'tag', 'Cost'] },
    { row: 4, cells: ['Pump', 'P-1', 'x', 'y', 100] },
  ];
  assert.equal(pickHeader(rows)!.row, 3);
  assert.deepEqual(headerNames(rows[1]!.cells), ['Name', 'Tag', 'Column C', 'tag (2)', 'Cost']);
});

test('not a zip: 415', async () => {
  await assert.rejects(openXlsx(Buffer.from('Name,Tag\nPump,P-1')), refused('not_xlsx'));
});

test('a DOCTYPE (entity expansion) refuses the file', async () => {
  const xml = '<?xml version="1.0"?><!DOCTYPE x [<!ENTITY a "aaaa">]><worksheet><sheetData><row r="1"><c t="inlineStr"><is><t>&a;</t></is></c></row></sheetData></worksheet>';
  await assert.rejects(read(book([{ name: 'S', xml }])), refused('bad_file'));
});

test('zip bomb: a sheet that inflates past the limit is refused', async () => {
  const saved = LIMITS.sheetBytes;
  LIMITS.sheetBytes = 2 ** 20;
  try {
    const xml = sheetXml([]).replace('<sheetData>', '<sheetData>' + '<row/>'.repeat(400_000)); // 2.4 MB, deflates to a few KB
    await assert.rejects(read(book([{ name: 'S', xml }])), refused('file_limits'));
  } finally {
    LIMITS.sheetBytes = saved;
  }
});

test('too many zip entries is refused', async () => {
  const files: Record<string, string> = {};
  for (let i = 0; i <= LIMITS.entries; i++) files[`f${i}`] = '';
  await assert.rejects(openXlsx(zip(files)), refused('file_limits'));
});

test('a value beyond 200 columns is refused', async () => {
  const xml = sheetXml([[{ xml: '<c r="GS1"><v>1</v></c>' }]]); // GS = column 201
  await assert.rejects(read(book([{ name: 'S', xml }])), refused('too_many_columns'));
});

test('a broken file: bad_file', async () => {
  await assert.rejects(read(zip({ 'xl/workbook.xml': '<workbook><sheets>' })), refused('bad_file'));
});
