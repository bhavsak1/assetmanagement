// The one data layer (CLAUDE.md §6.6). Routes get withUser or withKey, never the pool.
import pg from 'pg';

export type Claims = Record<string, unknown>;
export type Query = <R extends pg.QueryResultRow>(text: string, values?: unknown[]) => Promise<pg.QueryResult<R>>;
export type KeyIdentity = { user_id: string; tenant_id: string; key_id: string; calls: number };

// Thrown by withKey before any route query runs. The transaction rolls back.
export class KeyError extends Error {
  readonly code: 'unauthorized' | 'rate_limited';
  constructor(code: 'unauthorized' | 'rate_limited') {
    super(code);
    this.code = code;
  }
}

const SET_CLAIMS = "select set_config('role', 'authenticated', true), set_config('request.jwt.claims', $1, true)";

export function createDb(connectionString: string, max = 5) {
  const pool = new pg.Pool({ connectionString, max });

  // One transaction. Role and claims are transaction-local (set_config ..., true), so they end at commit or
  // rollback and a pooled connection never carries them to the next request.
  async function transaction<T>(fn: (q: Query) => Promise<T>): Promise<T> {
    const client = await pool.connect();
    let broken: Error | undefined;
    try {
      await client.query('begin');
      const result = await fn((text, values) => client.query(text, values));
      await client.query('commit');
      return result;
    } catch (e) {
      await client.query('rollback').catch((err: Error) => { broken = err; });
      throw e;
    } finally {
      client.release(broken); // a connection that cannot roll back is destroyed, not reused
    }
  }

  // Runs fn as the token's user under RLS.
  function withUser<T>(claims: Claims, fn: (q: Query) => Promise<T>): Promise<T> {
    return transaction(async (q) => {
      await q(SET_CLAIMS, [JSON.stringify(claims)]);
      return fn(q);
    });
  }

  // Story 9.2 (data-model-goal9.md §17 A5): runs fn as the key's integration user under RLS. The lookup runs
  // first, as the bare assetly_api role (no rights but that one function). No service-role key, no minted JWT.
  function withKey<T>(key: string, limit: number, fn: (q: Query, who: KeyIdentity) => Promise<T>): Promise<T> {
    return transaction(async (q) => {
      const who = (await q<KeyIdentity>('select user_id, tenant_id, key_id, calls from private.api_key_identity($1)', [key])).rows[0];
      if (!who) throw new KeyError('unauthorized');
      if (who.calls > limit) throw new KeyError('rate_limited');
      const claims = { sub: who.user_id, tenant_id: who.tenant_id, role: 'authenticated', aud: 'authenticated', api_key_id: who.key_id };
      await q(SET_CLAIMS, [JSON.stringify(claims)]);
      return fn(q, who);
    });
  }

  return { pool, withUser, withKey };
}

// System jobs (story 9.1): role assetly_jobs, which can only run the job functions it is granted. No user,
// no tenant context, no service-role key (CLAUDE.md §6.4). Each call is its own transaction.
export function createJobsDb(connectionString: string, max = 2) {
  const pool = new pg.Pool({ connectionString, max });
  const query: Query = (text, values) => pool.query(text, values);
  return { pool, query };
}
