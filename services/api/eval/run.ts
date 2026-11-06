// Story 10.1 (D7): the golden eval. Calls the real providers with the owner's own key; never in CI, never
// writes ai_call. Run before a prompt or model change and paste the output in the PR:
//   ANTHROPIC_API_KEY=... [VERTEX_PROJECT=... VERTEX_REGION=...] npm run eval [feature]
// Each file in eval/cases is a list of { name, feature, system, input, schema, expect }. Later stories add files.
import { readdirSync, readFileSync } from 'node:fs';
import { isDeepStrictEqual } from 'node:util';
import { Ajv } from 'ajv';
import { cost, MODEL, providersFromEnv, type Feature } from '../src/ai.ts';

type Case = { name: string; feature: Feature; system: string; input: string; schema: Record<string, unknown>; expect: unknown };
const dir = new URL('./cases/', import.meta.url);
const only = process.argv[2];
const cases: Case[] = readdirSync(dir).filter((f) => f.endsWith('.json'))
  .flatMap((f) => JSON.parse(readFileSync(new URL(f, dir), 'utf8')) as Case[])
  .filter((c) => !only || c.feature === only);
const providers = providersFromEnv();
if (!providers.length) throw new Error('Set ANTHROPIC_API_KEY and/or VERTEX_PROJECT to run the eval.');
const ajv = new Ajv({ strict: false });

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
      if (ajv.validate(c.schema, out) && isDeepStrictEqual(out, c.expect)) { s.pass++; verdict = 'pass'; }
    } catch (e) {
      verdict = `FAIL (${(e as Error).name})`;
    }
    console.log(`${p.name}  ${c.feature}  ${verdict}  ${c.name}`);
  }
  for (const [f, s] of score) console.log(`${p.name}  ${f}: ${s.pass}/${s.total}  cost $${(s.micro / 1e6).toFixed(5)}`);
}
