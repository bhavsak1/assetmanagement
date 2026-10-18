-- Helper and internal functions live here (CLAUDE.md §7.6). Not exposed through the API.
-- Grants to authenticated come with the first helper (story 1.3).
create schema if not exists private;
revoke all on schema private from public, anon, authenticated;
