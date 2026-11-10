// Story 10.1 (D7): the golden eval. Calls the real providers with the owner's own key; never in CI, never
// writes ai_call. Run before a prompt or model change and paste the output in the PR:
//   ANTHROPIC_API_KEY=... [VERTEX_PROJECT=... VERTEX_REGION=...] npm run eval [feature]
// Each file in eval/cases is a list of { name, feature, system, input, schema, expect }. Later stories add files.
import { readdirSync, readFileSync } from 'node:fs';
import { isDeepStrictEqual } from 'node:util';
import { Ajv } from 'ajv';
import { cost, MODEL, providersFromEnv, type Feature } from '../src/ai.ts';
import { aiChecked, type AiOutput, type Target } from '../src/mapping.ts';
import { aiChecked as valuesChecked, type AiOutput as ValuesOutput } from '../src/values.ts';
import { ASK_SCHEMA, askInput, askSystem, shape, type AskOutput } from '../src/ask.ts';
import { buildCatalog, publicCatalog } from '../src/insights.ts';
import { assistInput, assistSchema, assistShape, assistSystem, offer, type AssistOutput } from '../src/assist.ts';

type Case = { name: string; feature: Feature; system: string; input: string; schema: Record<string, unknown>; expect: unknown;
  question?: string; message?: string };
// insights (10.7): a case holds only the question; the prompt is the route's, over a catalog with every view domain.
const EVAL_RIGHTS = ['asset_core', 'asset_financials', 'category_config', 'location_hierarchy', 'vendor_core',
  'coverage_contract', 'coverage_values', 'obligation', 'service_record', 'service_values'].map((d) => `${d}.view`);
const insightsSystem = askSystem(publicCatalog(buildCatalog(new Set(EVAL_RIGHTS), [])), new Date().toISOString().slice(0, 10));
// assist (10.9): a case holds only the message; the prompt offers every intent and system field.
const assistOffer = offer(new Set([...EVAL_RIGHTS, 'asset_core.create', 'asset_core.update', 'asset_core.set_tag',
  'asset_financials.update', 'asset_lifecycle.execute']), true, []);
const assistSys = assistSystem(assistOffer, publicCatalog(buildCatalog(new Set(EVAL_RIGHTS), [])), new Date().toISOString().slice(0, 10));
const searchShape = (q: unknown) => shape({ query: q });
const dir = new URL('./cases/', import.meta.url);
const only = process.argv[2];
const cases: Case[] = readdirSync(dir).filter((f) => f.endsWith('.json'))
  .flatMap((f) => JSON.parse(readFileSync(new URL(f, dir), 'utf8')) as Case[])
  .filter((c) => !only || c.feature === only)
  .map((c) => (c.message !== undefined
    ? { ...c, system: assistSys, input: assistInput(c.message), schema: assistSchema(assistOffer), expect: assistShape(c.expect as AssistOutput, searchShape) }
    : c.question === undefined ? c : { ...c, system: insightsSystem, input: askInput(c.question), schema: ASK_SCHEMA,
      expect: (c.expect as { cannot_answer?: true }).cannot_answer ? c.expect : shape({ query: c.expect }) }));
const providers = providersFromEnv();
if (!providers.length) throw new Error('Set ANTHROPIC_API_KEY and/or VERTEX_PROJECT to run the eval.');
const ajv = new Ajv({ strict: false });

// import_map (10.3): confidence varies run to run, so score what the user would see after the code checks:
// expect is { column: target } for every column that should get a suggestion; the rest must get none.
// import_values (10.4): expect is { value: candidate index } for every value that should get a pick.
// insights (10.7): expect is shape() of the right answer (subject, filters by field, group_by, measures).
// assist (10.9): expect is the intent, the asset text and the values by field (assistShape); a search as 10.7.
function asShown(c: Case, out: unknown): unknown {
  if (c.feature === 'insights') return shape(out as AskOutput);
  if (c.feature === 'assist') return assistShape(out as AssistOutput, searchShape);
  if (c.feature === 'import_values') {
    const { values } = JSON.parse(c.input) as { values: { field: 'vendor'; text: string; candidates: { candidate: number; name: string }[] }[] };
    const ask = values.map((v) => ({ column: v.field, raw: v.text, candidates: v.candidates.map((x) => ({ id: String(x.candidate), label: x.name })) }));
    return Object.fromEntries(valuesChecked(out as ValuesOutput, ask).map((s) => [String(ask.findIndex((a) => a.raw === s.raw)), Number(s.target_id)]));
  }
  if (c.feature !== 'import_map') return out;
  const input = JSON.parse(c.input) as { fields: { key: string }[]; columns: { column: number }[] };
  const open = input.columns.map((x) => x.column);
  const catalog = input.fields.map((f) => ({ target: f.key }) as Target);
  const checked = aiChecked(out as AiOutput, open, catalog, Array.from({ length: Math.max(...open) + 1 }, () => undefined));
  return Object.fromEntries(checked.flatMap((s, i) => (s ? [[String(i), s.target]] : [])));
}

for (const p of providers) {
  const score = new Map<string, { pass: number; total: number; micro: number }>();
  for (const c of cases) {
    const model = MODEL[c.feature];
    const s = score.get(c.feature) ?? { pass: 0, total: 0, micro: 0 };
    score.set(c.feature, s);
    s.total++;
    let verdict = 'FAIL';
    try {
      const r = await p.call({ model, system: c.system, input: c.input, schema: c.schema, maxTokens: 4000 });
      s.micro += cost(model, r.usage);
      const out: unknown = JSON.parse(r.text);
      if (ajv.validate(c.schema, out) && isDeepStrictEqual(asShown(c, out), c.expect)) { s.pass++; verdict = 'pass'; }
    } catch (e) {
      verdict = `FAIL (${(e as Error).name})`;
    }
    console.log(`${p.name}  ${c.feature}  ${verdict}  ${c.name}`);
  }
  for (const [f, s] of score) console.log(`${p.name}  ${f}: ${s.pass}/${s.total}  cost $${(s.micro / 1e6).toFixed(5)}`);
}
