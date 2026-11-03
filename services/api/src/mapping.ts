// Column mapping (docs/data-model-goal8.md §14). A chain of mappers suggests a target per column; the user
// confirms it and import_save_mapping checks it in the database. Goal 10 adds an AI mapper at the end of
// the chain, behind the AI gateway; it gets the same input, so it only ever sees targets this user may set.
import type { Query } from './db.ts';
import type { Cell } from './xlsx.ts';
import { zip } from './zip.ts';

export type Target = { target: string; label: string; kind: string; required: boolean; category_id: string | null };
export type Template = { id: string; name: string; headers: string[]; targets: Record<string, string>; updated_at: Date };
export type Suggestion = { target: string; source: 'template' | 'rules' | 'ai' };
export type MapInput = { columns: string[]; samples: Cell[][]; catalog: Target[] };
// One entry per column; undefined means "no opinion, ask the next mapper".
export type Mapper = (input: MapInput) => Promise<(Suggestion | undefined)[]>;

export const normalise = (s: string) => s.toLowerCase().replace(/&/g, 'and').replace(/[^\p{L}\p{N}]/gu, '');

// Header names a person might use, already normalised. English only, like the UI.
const SYNONYMS: Record<string, string> = {
  assettag: 'tag', tagno: 'tag', tagnumber: 'tag', assetcode: 'tag', assetid: 'tag', assetno: 'tag', assetnumber: 'tag',
  assetname: 'name', description: 'name', assetdescription: 'name', equipment: 'name', equipmentname: 'name',
  assetcategory: 'category', cat: 'category', type: 'category', assettype: 'category', equipmenttype: 'category',
  site: 'location', plant: 'location', area: 'location', assetlocation: 'location',
  assetstatus: 'status', condition: 'status',
  qty: 'quantity',
  parent: 'parent_tag', parenttag: 'parent_tag', parentasset: 'parent_tag',
  serialno: 'serial_number', serial: 'serial_number', sn: 'serial_number', serialnum: 'serial_number',
  make: 'manufacturer', oem: 'manufacturer', brand: 'manufacturer', mfr: 'manufacturer',
  modelno: 'model', modelnumber: 'model',
  purchasedate: 'purchase_date', dateofpurchase: 'purchase_date', invoicedate: 'purchase_date', podate: 'purchase_date',
  cost: 'purchase_value', price: 'purchase_value', purchaseprice: 'purchase_value', purchasecost: 'purchase_value', value: 'purchase_value',
  currency: 'purchase_currency',
  commissioningdate: 'in_service_date', installdate: 'in_service_date', installationdate: 'in_service_date',
  oemvendor: 'oem_vendor', supplier: 'om_vendor', vendor: 'om_vendor', amcvendor: 'om_vendor', servicevendor: 'om_vendor',
  warrantyfrom: 'warranty_start', warrantystartdate: 'warranty_start',
  warrantyuntil: 'warranty_end', warrantytill: 'warranty_end', wtytill: 'warranty_end', warrantyexpiry: 'warranty_end',
  warrantyenddate: 'warranty_end', warrantyupto: 'warranty_end',
};
// "Sr. No." in Indian sheets is the row count, not the serial number (§14.3).
const IGNORE = new Set(['srno', 'slno', 'sno', 'sr', 'sl', 'no', 'rowno', 'serialnumberrow']);

// Normalised header -> target, first name wins: core fields (catalog order), then custom fields, then synonyms.
function namesOf(catalog: Target[]): Map<string, string> {
  const names = new Map<string, string>();
  const add = (n: string, target: string) => { if (n && !names.has(n)) names.set(n, target); };
  for (const t of catalog) {
    const key = t.target.replace(/^custom:/, '');
    add(normalise(t.label), t.target);
    add(normalise(key), t.target);
    if (key !== t.target) add(normalise(t.label + key), t.target); // the download template's "Label [key]"
  }
  const allowed = new Set(catalog.map((t) => t.target));
  for (const [n, target] of Object.entries(SYNONYMS)) if (allowed.has(target)) add(n, target);
  return names;
}

export const rulesMapper: Mapper = async ({ columns, catalog }) => {
  const names = namesOf(catalog);
  return columns.map((c) => {
    const n = normalise(c);
    if (IGNORE.has(n)) return { target: 'ignore', source: 'rules' };
    const target = names.get(n);
    return target ? { target, source: 'rules' } : undefined;
  });
};

export const templateMapper = (template: Template): Mapper => async ({ columns }) =>
  columns.map((c) => {
    const target = template.targets[normalise(c)];
    return target ? { target, source: 'template' } : undefined;
  });

// Headers the parser named itself ("Column C") are blank in the file.
const isBlank = (c: string) => /^Column [A-Z]{1,3}$/.test(c);

// M6: applies by itself when every non-blank header is in the template; ties go to the latest saved.
export function matchTemplate(columns: string[], templates: Template[]): Template | undefined {
  const file = columns.filter((c) => !isBlank(c)).map(normalise);
  return templates
    .filter((t) => file.length > 0 && file.every((n) => t.headers.includes(n)))
    .sort((a, b) => b.updated_at.getTime() - a.updated_at.getTime())[0];
}

// Runs the chain; a target the user may not set becomes ignore, and each target is used once (leftmost wins).
export async function suggestMapping(input: MapInput, mappers: Mapper[]): Promise<Suggestion[]> {
  const out: (Suggestion | undefined)[] = input.columns.map(() => undefined);
  for (const m of mappers) {
    const s = await m(input);
    out.forEach((v, i) => { if (!v) out[i] = s[i]; });
  }
  const allowed = new Set(input.catalog.map((t) => t.target));
  const used = new Set<string>();
  return out.map((s) => {
    if (!s || s.target === 'ignore') return s ?? { target: 'ignore', source: 'rules' };
    if (!allowed.has(s.target) || used.has(s.target)) return { target: 'ignore', source: s.source };
    used.add(s.target);
    return s;
  });
}

// Loads what the chain needs under the user's RLS and suggests (template first, then rules).
export async function suggestFor(q: Query, columns: string[], samples: Cell[][]) {
  const catalog = (await q<Target>('select target, label, kind, required, category_id from public.import_target_catalog()')).rows;
  const templates = (await q<Template>(
    'select id, name, headers, targets, updated_at from public.import_mapping_template where deleted_at is null')).rows;
  const template = matchTemplate(columns, templates);
  const mapping = await suggestMapping({ columns, samples, catalog }, template ? [templateMapper(template), rulesMapper] : [rulesMapper]);
  return { mapping, template_id: template?.id ?? null };
}

// Header row of the download template: one column per target; a custom label that clashes gets its key.
export function templateHeaders(catalog: Target[]): string[] {
  const seen = new Set<string>();
  return catalog.map((t) => {
    const key = t.target.replace(/^custom:/, '');
    const plain = !seen.has(normalise(t.label)) && !(key !== t.target && seen.has(normalise(key)));
    const header = plain ? t.label : `${t.label} [${key}]`;
    seen.add(normalise(t.label));
    seen.add(normalise(key));
    return header;
  });
}

const esc = (s: string) => s.replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;').replace(/"/g, '&quot;');

// The smallest .xlsx Excel opens: one sheet "Assets", one bold header row, frozen below it.
export function templateXlsx(headers: string[]): Buffer {
  const main = 'http://schemas.openxmlformats.org/spreadsheetml/2006/main';
  const rel = 'http://schemas.openxmlformats.org/officeDocument/2006/relationships';
  const pkg = 'http://schemas.openxmlformats.org/package/2006/relationships';
  const cells = headers.map((h) => `<c t="inlineStr" s="1"><is><t>${esc(h)}</t></is></c>`).join('');
  return zip({
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
      + '<sheets><sheet name="Assets" sheetId="1" r:id="rId1"/></sheets></workbook>',
    'xl/_rels/workbook.xml.rels': `<?xml version="1.0" encoding="UTF-8" standalone="yes"?><Relationships xmlns="${pkg}">`
      + `<Relationship Id="rId1" Type="${rel}/worksheet" Target="worksheets/sheet1.xml"/>`
      + `<Relationship Id="rId2" Type="${rel}/styles" Target="styles.xml"/></Relationships>`,
    'xl/styles.xml': `<?xml version="1.0" encoding="UTF-8" standalone="yes"?><styleSheet xmlns="${main}">`
      + '<fonts count="2"><font><sz val="11"/><name val="Calibri"/></font><font><b/><sz val="11"/><name val="Calibri"/></font></fonts>'
      + '<fills count="2"><fill><patternFill patternType="none"/></fill><fill><patternFill patternType="gray125"/></fill></fills>'
      + '<borders count="1"><border><left/><right/><top/><bottom/><diagonal/></border></borders>'
      + '<cellStyleXfs count="1"><xf numFmtId="0" fontId="0" fillId="0" borderId="0"/></cellStyleXfs>'
      + '<cellXfs count="2"><xf numFmtId="0" fontId="0" fillId="0" borderId="0" xfId="0"/>'
      + '<xf numFmtId="0" fontId="1" fillId="0" borderId="0" xfId="0" applyFont="1"/></cellXfs>'
      + '<cellStyles count="1"><cellStyle name="Normal" xfId="0" builtinId="0"/></cellStyles></styleSheet>',
    'xl/worksheets/sheet1.xml': `<?xml version="1.0" encoding="UTF-8" standalone="yes"?><worksheet xmlns="${main}">`
      + '<sheetViews><sheetView workbookViewId="0"><pane ySplit="1" topLeftCell="A2" activePane="bottomLeft" state="frozen"/></sheetView></sheetViews>'
      + `<sheetData><row r="1">${cells}</row></sheetData></worksheet>`,
  });
}
