// The one data layer (CLAUDE.md §6.6). Routes get withUser, never the pool.
import pg from 'pg';

export type Claims = Record<string, unknown>;
export type Query = <R extends pg.QueryResultRow>(text: string, values?: unknown[]) => Promise<pg.QueryResult<R>>;

export function createDb(connectionString: string, max = 5) {
  const pool = new pg.Pool({ connectionString, max });

  // Runs fn as the token's user under RLS. Role and claims are transaction-local (set_config ..., true),
  // so they end at commit or rollback and a pooled connection never carries them to the next request.
  async function withUser<T>(claims: Claims, fn: (q: Query) => Promise<T>): Promise<T> {
    const client = await pool.connect();
    let broken: Error | undefined;
    try {
      await client.query('begin');
      await client.query("select set_config('role', 'authenticated', true), set_config('request.jwt.claims', $1, true)", [JSON.stringify(claims)]);
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

  return { pool, withUser };
}

// System jobs (story 9.1): role assetly_jobs, which can only run the job functions it is granted. No user,
// no tenant context, no service-role key (CLAUDE.md §6.4). Each call is its own transaction.
export function createJobsDb(connectionString: string, max = 2) {
  const pool = new pg.Pool({ connectionString, max });
  const query: Query = (text, values) => pool.query(text, values);
  return { pool, query };
}
