// Verifies a Supabase access token against the project's public keys (docs/data-model-goal8.md §3).
// Postgres trusts the claims the service sets, so this check is the trust boundary.
import { createRemoteJWKSet, errors, jwtVerify, type JWTPayload } from 'jose';

export type Verify = (token: string) => Promise<JWTPayload | null>;

export function createVerifier(supabaseUrl: string): Verify {
  const issuer = `${supabaseUrl}/auth/v1`;
  const jwks = createRemoteJWKSet(new URL(`${issuer}/.well-known/jwks.json`));
  return async (token) => {
    try {
      const { payload } = await jwtVerify(token, jwks, { issuer, audience: 'authenticated', algorithms: ['ES256'] });
      return payload.role === 'authenticated' && typeof payload.sub === 'string' ? payload : null;
    } catch (e) {
      // a bad token is a 401; an unreachable key endpoint is a 500, not a silent 401
      if (e instanceof errors.JOSEError && e.code !== 'ERR_JWKS_TIMEOUT') return null;
      throw e;
    }
  };
}
