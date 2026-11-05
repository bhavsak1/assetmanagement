-- Story 9.5a: deleted-asset visibility on /v1 (docs/data-model-goal9.md §19 M1).
-- GET /v1/assets?include_deleted=true pages deleted assets as tombstones by (updated_at, id), like live ones.
-- The 3.1 asset_updated_idx covers live rows only. No policy change: asset_select already lets a key read a
-- soft-deleted row it may view in its scope (CLAUDE.md §7).
create index asset_deleted_idx on public.asset (tenant_id, updated_at, id) where deleted_at is not null;
