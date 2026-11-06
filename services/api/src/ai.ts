// Story 10.1: the AI gateway (docs/data-model-goal10.md §2). The only module that calls a model (CLAUDE.md §11);
// ESLint refuses a model SDK import anywhere else. Flow per call (§2.2): ai_begin (entitlement, right, cap, rate
// limit; commits) -> model call outside any transaction -> ai_finish (tokens, cost) -> Ajv check of the output.
import Anthropic from '@anthropic-ai/sdk';
import { AnthropicVertex } from '@anthropic-ai/vertex-sdk';
import { Ajv } from 'ajv';
import type { Claims, createDb } from './db.ts';

export type Feature = 'import_map' | 'import_values' | 'insights' | 'assist' | 'check';
// Stable codes for the web app (i18n). Every one leaves the manual path open.
export type AiCode = 'ai_off' | 'ai_not_licensed' | 'ai_no_right' | 'ai_cap_reached' | 'ai_rate_limited' | 'ai_failed';
const REFUSALS = new Set(['ai_not_licensed', 'ai_no_right', 'ai_cap_reached', 'ai_rate_limited']);

export class AiError extends Error {
  readonly code: AiCode;
  constructor(code: AiCode) {
    super(code);
    this.code = code;
  }
}

// D3: Haiku 5.5 for every feature until the eval shows a need. Prices in USD per million tokens, which is the
// same number as micro-USD per token (claude-api reference, cached 6 Oct 2026; prompts up to 100K tokens).
export const MODEL: Record<Feature, string> = {
  import_map: 'claude-haiku-5-5', import_values: 'claude-haiku-5-5', insights: 'claude-haiku-5-5',
  assist: 'claude-haiku-5-5', check: 'claude-haiku-5-5',
};
const PRICE: Record<string, { in: number; out: number; cacheRead: number }> = {
  'claude-haiku-5-5': { in: 0.10, out: 0.50, cacheRead: 0.01 },
  'claude-sonnet-5-5': { in: 2, out: 10, cacheRead: 0.20 },
};
const MAX_TOKENS = 4000;
const TIMEOUT_MS = 20_000;

export type ModelRequest = { model: string; system: string; input: string; schema: Record<string, unknown>; maxTokens: number };
export type ModelReply = {
  text: string;
  stopReason: string | null;
  usage: { input_tokens: number; output_tokens: number; cache_read_input_tokens?: number | null };
};
// A provider is one call; retries live in its SDK client. Tests pass a fake.
export type Provider = { name: string; call: (req: ModelRequest) => Promise<ModelReply> };

function sdkProvider(name: string, client: Anthropic | AnthropicVertex): Provider {
  return {
    name,
    async call({ model, system, input, schema, maxTokens }) {
      const m = await client.messages.create({
        model,
        max_tokens: maxTokens,
        system,
        messages: [{ role: 'user', content: input }],
        output_config: { effort: 'low', format: { type: 'json_schema', schema } },
      });
      const text = m.content.flatMap((b) => (b.type === 'text' ? [b.text] : [])).join('');
      return { text, stopReason: m.stop_reason, usage: m.usage };
    },
  };
}

// §2.5: Anthropic API first (key from Secret Manager), then the same models on Vertex AI with the Cloud Run
// service account (no second secret). A provider whose config is missing is left out.
export function providersFromEnv(env = process.env): Provider[] {
  const list: Provider[] = [];
  if (env.ANTHROPIC_API_KEY) {
    list.push(sdkProvider('anthropic', new Anthropic({ apiKey: env.ANTHROPIC_API_KEY, maxRetries: 2, timeout: TIMEOUT_MS })));
  }
  if (env.VERTEX_PROJECT) {
    list.push(sdkProvider('vertex', new AnthropicVertex({
      projectId: env.VERTEX_PROJECT, region: env.VERTEX_REGION || 'global', maxRetries: 2, timeout: TIMEOUT_MS,
    })));
  }
  return list;
}

// Our bug (400) or a refusal: the other provider would answer the same, so no fallback (§2.2).
function errorCode(e: unknown): { code: string; fallback: boolean } {
  if (e instanceof Anthropic.APIConnectionTimeoutError) return { code: 'timeout', fallback: true };
  if (e instanceof Anthropic.APIConnectionError) return { code: 'connection', fallback: true };
  if (e instanceof Anthropic.APIError && typeof e.status === 'number') return { code: `http_${e.status}`, fallback: e.status !== 400 };
  return { code: 'provider_error', fallback: true };
}

export function cost(model: string, u: ModelReply['usage']): number {
  const p = PRICE[model];
  if (!p) throw new Error(`no price for ${model}`);
  return Math.ceil(u.input_tokens * p.in + u.output_tokens * p.out + (u.cache_read_input_tokens ?? 0) * p.cacheRead);
}

const ajv = new Ajv({ allErrors: false, strict: false });

type Deps = { withUser: ReturnType<typeof createDb>['withUser']; providers: Provider[]; enabled: boolean };
export type CallArgs = {
  claims: Claims;
  feature: Feature;
  system: string;           // fixed rules; untrusted text never goes here (§6.2)
  input: string;            // the user turn: untrusted text inside a JSON data block
  schema: Record<string, unknown>;
  subjectId?: string | null;
  maxTokens?: number;
};

export function createGateway({ withUser, providers, enabled }: Deps) {
  return async function callModel<T>({ claims, feature, system, input, schema, subjectId = null, maxTokens = MAX_TOKENS }: CallArgs): Promise<{ output: T; ai_call_id: string }> {
    if (!enabled || !providers.length) throw new AiError('ai_off');
    const model = MODEL[feature];
    const validate = ajv.compile<T>(schema);
    // Worst case: about 3 characters a token in, every allowed token out.
    const est = cost(model, { input_tokens: Math.ceil((system.length + input.length) / 3), output_tokens: maxTokens });

    let id: string;
    try {
      id = await withUser(claims, async (q) => (await q<{ id: string }>('select private.ai_begin($1, $2, $3) as id', [feature, subjectId, est])).rows[0]!.id);
    } catch (e) {
      const msg = (e as { message?: string }).message ?? '';
      if (REFUSALS.has(msg)) throw new AiError(msg as AiCode);
      throw e;
    }

    const started = Date.now();
    let reply: ModelReply | undefined;
    let provider = providers[0]!;
    let error: string | null = null;
    for (const p of providers) {
      provider = p;
      try {
        reply = await p.call({ model, system, input, schema, maxTokens });
        error = null;
        break;
      } catch (e) {
        const r = errorCode(e);
        error = r.code;
        if (!r.fallback) break;
      }
    }

    let output: T | undefined;
    if (reply) {
      if (reply.stopReason === 'refusal') error = 'refusal';
      else if (reply.stopReason === 'max_tokens') error = 'max_tokens';
      else {
        try {
          const parsed: unknown = JSON.parse(reply.text);
          if (validate(parsed)) output = parsed;
          else error = 'bad_output'; // never "best effort"
        } catch {
          error = 'bad_output';
        }
      }
    }

    await withUser(claims, (q) => q('select private.ai_finish($1, $2, $3, $4, $5, $6, $7, $8, $9, $10, $11, $12)', [
      id, output === undefined ? 'error' : 'ok', provider.name, model,
      reply?.usage.input_tokens ?? null, reply?.usage.output_tokens ?? null, reply?.usage.cache_read_input_tokens ?? null,
      reply ? cost(model, reply.usage) : 0, Date.now() - started, error,
      JSON.stringify({ input }), output === undefined ? null : JSON.stringify(output),
    ]));
    if (output === undefined) throw new AiError('ai_failed');
    return { output, ai_call_id: id };
  };
}

export type CallModel = ReturnType<typeof createGateway>;
