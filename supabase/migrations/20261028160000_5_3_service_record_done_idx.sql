-- Story 5.3 (M2): the Maintenance Completed tab lists the tenant's live service records newest first, keyset
-- paged by (done_on desc, id). docs/data-model-goal5.md §13.2.
create index service_record_done_idx on public.service_record (tenant_id, done_on desc, id) where deleted_at is null;
