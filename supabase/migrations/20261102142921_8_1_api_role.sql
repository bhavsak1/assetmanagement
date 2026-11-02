-- Story 8.1: login role for the custom service (docs/data-model-goal8.md §2, G3).
-- The service runs every request as `begin; set local role authenticated; set_config('request.jwt.claims', ..., true)`.
-- noinherit and no grants of its own: outside that transaction it can read nothing (default deny).
-- No password in git: the local seed sets a test one; on staging the owner sets it and keeps it in Secret Manager.
do $$
begin
  if not exists (select 1 from pg_roles where rolname = 'assetly_api') then
    create role assetly_api login noinherit;
  end if;
end $$;

grant authenticated to assetly_api with inherit false, set true;
