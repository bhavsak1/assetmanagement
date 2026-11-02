// Story 8.1: local ES256 key for Supabase Auth (supabase/signing_keys.json, git-ignored).
// The CLI's own `gen signing-key` needs the file to exist already once config.toml points at it.
import { generateKeyPairSync, randomUUID } from 'node:crypto';
import { existsSync, writeFileSync } from 'node:fs';

const path = new URL('../supabase/signing_keys.json', import.meta.url);
if (existsSync(path)) process.exit(0);
const jwk = generateKeyPairSync('ec', { namedCurve: 'P-256' }).privateKey.export({ format: 'jwk' });
writeFileSync(path, JSON.stringify([{ ...jwk, kid: randomUUID(), use: 'sig', key_ops: ['sign', 'verify'], alg: 'ES256', ext: true }]));
