-- Story 2.1: field_definition, custom fields per entity, optionally per asset category
-- (data-model-goal2.md §1.2, G3 to G6). Values live as JSONB on the record, keyed by `key` (3.1).

-- G6: lets a field's domain be pinned to the field's entity with a composite FK.
alter table public.security_domain add constraint security_domain_id_entity_key unique (id, entity);

create table public.field_definition (
  id                 uuid primary key default gen_random_uuid(),
  tenant_id          uuid not null references public.tenant (id),
  entity             text not null check (entity in ('asset', 'vendor', 'coverage')),
  -- Null: every record of the entity. Set: this category and its descendants (G3).
  category_id        uuid null,
  key                text not null check (key ~ '^[a-z][a-z0-9_]*$' and length(key) <= 63),
  label              text not null,
  type               text not null check (type in ('text', 'number', 'date', 'boolean', 'list')),
  -- list: [{"code","label","is_active"}]; values store the code.
  options            jsonb not null default '[]',
  unit               text null,
  is_required        boolean not null default false,
  sort_order         int not null default 0,
  security_domain_id uuid not null,
  is_active          boolean not null default true,
  created_at         timestamptz not null default now(),
  updated_at         timestamptz not null default now(),
  created_by         uuid null references public.user_profile (id),
  updated_by         uuid null references public.user_profile (id),
  deleted_at         timestamptz null,
  unique (tenant_id, id),
  -- G4: not partial. A key is never reused, so a stored value never takes a new meaning.
  unique (tenant_id, entity, key),
  foreign key (tenant_id, category_id) references public.asset_category (tenant_id, id),
  foreign key (security_domain_id, entity) references public.security_domain (id, entity),
  check (category_id is null or entity = 'asset'),
  check (jsonb_typeof(options) = 'array' and (type = 'list') = (jsonb_array_length(options) > 0))
);
create index field_definition_category_idx on public.field_definition (tenant_id, category_id);

create trigger set_updated_at before update on public.field_definition
  for each row execute function private.set_updated_at();
create trigger check_soft_delete before update of deleted_at on public.field_definition
  for each row execute function private.check_soft_delete('category_config', 'manage');
create trigger audit after insert or update or delete on public.field_definition
  for each row execute function private.audit_row('data');

alter table public.field_definition enable row level security;

create policy field_definition_select on public.field_definition
  for select to authenticated
  using (tenant_id = (select private.current_tenant_id())
         and (select private.has_permission('category_config', 'view')));
create policy field_definition_insert on public.field_definition
  for insert to authenticated
  with check (tenant_id = (select private.current_tenant_id())
              and (select private.has_permission('category_config', 'manage'))
              and (select private.tenant_can_write()));
create policy field_definition_update on public.field_definition
  for update to authenticated
  using (tenant_id = (select private.current_tenant_id())
         and (select private.has_permission('category_config', 'manage'))
         and (select private.tenant_can_write()))
  with check (tenant_id = (select private.current_tenant_id())
              and (select private.has_permission('category_config', 'manage'))
              and (select private.tenant_can_write()));

revoke delete, truncate on public.field_definition from anon, authenticated;
-- key, entity and type are immutable: changing them would orphan or corrupt stored values.
revoke update on public.field_definition from anon, authenticated;
grant update (category_id, label, options, unit, is_required, sort_order, security_domain_id,
              is_active, updated_by, deleted_at) on public.field_definition to authenticated;
