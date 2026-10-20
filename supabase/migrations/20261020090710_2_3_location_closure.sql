-- Story 2.3: location closure table, kept by triggers on public.location (L3, L4 in
-- docs/data-model-goal2-locations.md). One row per (ancestor, descendant) pair, self pair at depth 0.
-- Private on purpose: a forged row would widen 6.1 location scope, so no client can read or write it.

create table private.location_closure (
  tenant_id     uuid not null,
  ancestor_id   uuid not null,
  descendant_id uuid not null,
  depth         smallint not null check (depth >= 0),
  primary key (tenant_id, ancestor_id, descendant_id),  -- descendants of X: the 6.1 scope join
  foreign key (tenant_id, ancestor_id)   references public.location (tenant_id, id),
  foreign key (tenant_id, descendant_id) references public.location (tenant_id, id)
);
create index location_closure_descendant_idx on private.location_closure (tenant_id, descendant_id);  -- ancestors of X
-- On, no policies: read only through security definer code, like user_effective_permission.
alter table private.location_closure enable row level security;
revoke all on private.location_closure from public, anon, authenticated;

-- Insert: the self pair plus one pair per ancestor of the parent.
create function private.location_closure_insert()
returns trigger language plpgsql security definer set search_path = '' as $$
begin
  insert into private.location_closure (tenant_id, ancestor_id, descendant_id, depth)
  select new.tenant_id, new.id, new.id, 0
  union all
  select c.tenant_id, c.ancestor_id, new.id, c.depth + 1
  from private.location_closure c
  where c.tenant_id = new.tenant_id and c.descendant_id = new.parent_id;
  return null;
end;
$$;

-- Move: refuse a cycle, unlink the subtree from its old ancestors, link it under the new parent.
-- Pairs inside the subtree stay, so the whole subtree moves. After-row, so in a multi-row update
-- each row sees the closure the earlier rows left, and the cycle check cannot be skipped.
create function private.location_closure_move()
returns trigger language plpgsql security definer set search_path = '' as $$
begin
  -- One move per tenant at a time: two crossing moves could each pass the cycle check alone.
  perform pg_advisory_xact_lock(hashtextextended('location_move:' || new.tenant_id::text, 0));

  if exists (select 1 from private.location_closure
             where tenant_id = new.tenant_id and ancestor_id = new.id and descendant_id = new.parent_id) then
    raise exception 'a location cannot move under itself or its own descendant' using errcode = '23514';
  end if;

  delete from private.location_closure c
  where c.tenant_id = new.tenant_id
    and c.descendant_id in (select s.descendant_id from private.location_closure s
                            where s.tenant_id = new.tenant_id and s.ancestor_id = new.id)
    and c.ancestor_id not in (select s.descendant_id from private.location_closure s
                              where s.tenant_id = new.tenant_id and s.ancestor_id = new.id);

  insert into private.location_closure (tenant_id, ancestor_id, descendant_id, depth)
  select new.tenant_id, a.ancestor_id, s.descendant_id, a.depth + s.depth + 1
  from private.location_closure a
  join private.location_closure s on s.tenant_id = new.tenant_id and s.ancestor_id = new.id
  where a.tenant_id = new.tenant_id and a.descendant_id = new.parent_id;
  return null;
end;
$$;
revoke all on function private.location_closure_insert(), private.location_closure_move() from public, anon, authenticated;

create trigger location_closure_insert after insert on public.location
  for each row execute function private.location_closure_insert();
create trigger location_closure_move after update of parent_id on public.location
  for each row when (old.parent_id is distinct from new.parent_id)
  execute function private.location_closure_move();
