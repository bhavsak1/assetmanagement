-- Story 1.5: outbox_event, domain events written in the same transaction as the change.
-- Shape from docs/data-model-goal1.md §2.13. In private, so the API does not expose it.
-- The poller (later goal) reads it with the service role; its grants come with the poller.

create table private.outbox_event (
  id             uuid primary key default gen_random_uuid(),
  tenant_id      uuid not null references public.tenant (id),
  occurred_at    timestamptz not null default now(),
  event_type     text not null,
  aggregate_type text not null,
  aggregate_id   uuid not null,
  payload        jsonb not null,
  published_at   timestamptz null,
  attempts       integer not null default 0,
  last_error     text null
);
-- Poller path.
create index outbox_event_unpublished_idx on private.outbox_event (occurred_at) where published_at is null;

-- On, no policies: users never read it. Written by security definer functions only.
alter table private.outbox_event enable row level security;
revoke all on private.outbox_event from public, anon, authenticated;
