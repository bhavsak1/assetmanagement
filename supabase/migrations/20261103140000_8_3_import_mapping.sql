-- Story 8.3: column mapping and mapping templates. docs/data-model-goal8.md §14.
-- OWNER REVIEW (CLAUDE.md §9): RLS policies, two security definer functions.
-- The service suggests a mapping at upload (stored with the batch insert); the user changes it and saves
-- through import_save_mapping, the only way a batch becomes 'mapped' (M4). Templates use the excel_import
-- domain (M5): read with run or review, write with run.

alter table public.import_batch
  add column mapping jsonb null check (mapping is null or jsonb_typeof(mapping) = 'array'),
  add column mapping_template_id uuid null;
alter table public.import_batch drop constraint import_batch_status_check;
alter table public.import_batch add constraint import_batch_status_check check (status in ('staged', 'mapped', 'expired'));

drop index public.import_batch_expiry_idx;
create index import_batch_expiry_idx on public.import_batch (expires_at) where status in ('staged', 'mapped');

-- Only the save function sets 'mapped': a direct insert is always 'staged'.
drop policy import_batch_insert on public.import_batch;
create policy import_batch_insert on public.import_batch
  for insert to authenticated
  with check (tenant_id = (select private.current_tenant_id())
              and status = 'staged'
              and (select private.has_permission('excel_import', 'run'))
              and (select private.tenant_can_write()));

create table public.import_mapping_template (
  id         uuid primary key default gen_random_uuid(),
  tenant_id  uuid not null references public.tenant (id),
  name       text not null check (length(btrim(name)) between 1 and 100),
  -- Normalised header text in file order, and normalised header -> target (M6: matched by text, not letter).
  headers    text[] not null check (cardinality(headers) between 1 and 200),
  targets    jsonb not null check (jsonb_typeof(targets) = 'object'),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  created_by uuid null default auth.uid() references public.user_profile (id),
  updated_by uuid null references public.user_profile (id),
  deleted_at timestamptz null,
  unique (tenant_id, id)
);
create unique index import_mapping_template_name_uq on public.import_mapping_template (tenant_id, lower(btrim(name)))
  where deleted_at is null;

alter table public.import_batch add foreign key (tenant_id, mapping_template_id)
  references public.import_mapping_template (tenant_id, id);

create trigger set_updated_at before update on public.import_mapping_template
  for each row execute function private.set_updated_at();
create trigger check_soft_delete before update of deleted_at on public.import_mapping_template
  for each row execute function private.check_soft_delete('excel_import', 'run');
create trigger audit after insert or update or delete on public.import_mapping_template
  for each row execute function private.audit_row('data');

alter table public.import_mapping_template enable row level security;

create policy import_mapping_template_select on public.import_mapping_template
  for select to authenticated
  using (tenant_id = (select private.current_tenant_id())
         and ((select private.has_permission('excel_import', 'run'))
              or (select private.has_permission('excel_import', 'review'))));
create policy import_mapping_template_insert on public.import_mapping_template
  for insert to authenticated
  with check (tenant_id = (select private.current_tenant_id())
              and (select private.has_permission('excel_import', 'run'))
              and (select private.tenant_can_write()));
create policy import_mapping_template_update on public.import_mapping_template
  for update to authenticated
  using (tenant_id = (select private.current_tenant_id())
         and (select private.has_permission('excel_import', 'run'))
         and (select private.tenant_can_write()))
  with check (tenant_id = (select private.current_tenant_id())
              and (select private.has_permission('excel_import', 'run'))
              and (select private.tenant_can_write()));

revoke delete, truncate on public.import_mapping_template from anon, authenticated;

-- M2, M3: the targets this user may set. Core fields need excel_import; field-domain columns and custom
-- fields also need view and update on their domain (the asset write checks ask for both); warranty needs
-- coverage_contract.create. Definer: field_definition is readable only with category_config.view.
create function public.import_target_catalog()
returns table (target text, label text, kind text, required boolean, category_id uuid, sort_order int)
language sql stable security definer set search_path = '' as $$
  select c.target, c.label, c.kind, c.required, null::uuid, c.sort_order
  from (values
    ('tag',               'Asset tag',         'text',     false, 1,  null),
    ('name',              'Name',              'text',     true,  2,  null),
    ('category',          'Category',          'category', true,  3,  null),
    ('location',          'Location',          'location', false, 4,  null),
    ('status',            'Status',            'status',   false, 5,  null),
    ('criticality',       'Criticality',       'text',     false, 6,  null),
    ('quantity',          'Quantity',          'number',   false, 7,  null),
    ('parent_tag',        'Parent asset tag',  'text',     false, 8,  null),
    ('serial_number',     'Serial number',     'text',     false, 9,  null),
    ('manufacturer',      'Manufacturer',      'text',     false, 10, null),
    ('model',             'Model',             'text',     false, 11, null),
    ('purchase_date',     'Purchase date',     'date',     false, 12, null),
    ('purchase_value',    'Purchase value',    'number',   false, 13, 'asset_financials'),
    ('purchase_currency', 'Purchase currency', 'text',     false, 14, 'asset_financials'),
    ('in_service_date',   'In service date',   'date',     false, 15, null),
    ('oem_vendor',        'OEM vendor',        'vendor',   false, 16, null),
    ('om_vendor',         'O&M vendor',        'vendor',   false, 17, null),
    ('warranty_start',    'Warranty start',    'date',     false, 18, 'coverage_contract'),
    ('warranty_end',      'Warranty end',      'date',     false, 19, 'coverage_contract')
  ) as c (target, label, kind, required, sort_order, domain)
  where (private.has_permission('excel_import', 'run') or private.has_permission('excel_import', 'review'))
    and (c.domain is null
         or (c.domain = 'coverage_contract' and private.has_permission(c.domain, 'create'))
         or (c.domain <> 'coverage_contract' and private.has_permission(c.domain, 'view')
             and private.has_permission(c.domain, 'update')))
  union all
  select 'custom:' || f.key, f.label, f.type, f.is_required, f.category_id, 100 + f.sort_order
  from public.field_definition f
  join public.security_domain d on d.id = f.security_domain_id
  where f.tenant_id = private.current_tenant_id()
    and f.entity = 'asset' and f.is_active and f.deleted_at is null
    and (private.has_permission('excel_import', 'run') or private.has_permission('excel_import', 'review'))
    and private.has_permission(d.code, 'view') and private.has_permission(d.code, 'update')
  order by 6, 2;
$$;
revoke all on function public.import_target_catalog() from public, anon;
grant execute on function public.import_target_catalog() to authenticated;

-- M4: the one way to set a batch's mapping. p_mapping is an array aligned with the batch columns,
-- each {"target": "<target or ignore>", "source": "template|rules|user"}.
create function public.import_save_mapping(p_batch_id uuid, p_mapping jsonb, p_template_id uuid default null)
returns void language plpgsql security definer set search_path = '' as $$
declare
  v_batch   public.import_batch;
  v_targets text[];
  v_allowed text[];
begin
  if not private.has_permission('excel_import', 'run') or not private.tenant_can_write() then
    raise exception 'not allowed' using errcode = '42501';
  end if;
  select * into v_batch from public.import_batch
  where id = p_batch_id and tenant_id = private.current_tenant_id() for update;
  if not found then
    raise exception 'batch not found' using errcode = 'P0002';
  end if;
  if v_batch.status not in ('staged', 'mapped') then
    raise exception 'batch is %', v_batch.status using errcode = '22023';
  end if;
  if p_mapping is null or jsonb_typeof(p_mapping) <> 'array'
     or jsonb_array_length(p_mapping) <> cardinality(v_batch.columns) then
    raise exception 'mapping: one entry per column' using errcode = '22023';
  end if;
  if exists (select 1 from jsonb_array_elements(p_mapping) e
             where jsonb_typeof(e) <> 'object' or jsonb_typeof(e -> 'target') <> 'string'
                or coalesce(e ->> 'source', '') not in ('template', 'rules', 'user', 'ai')) then
    raise exception 'mapping: each entry needs a target and a source' using errcode = '22023';
  end if;

  select array_agg(e ->> 'target') into v_targets
  from jsonb_array_elements(p_mapping) e where e ->> 'target' <> 'ignore';
  select array_agg(c.target) into v_allowed from public.import_target_catalog() c;
  if exists (select 1 from unnest(v_targets) t where not t = any (coalesce(v_allowed, '{}'))) then
    raise exception 'mapping: unknown or not allowed target' using errcode = '22023';
  end if;
  if (select count(*) <> count(distinct t) from unnest(v_targets) t) then
    raise exception 'mapping: a target is used twice' using errcode = '22023';
  end if;
  if not ('name' = any (coalesce(v_targets, '{}')) and 'category' = any (coalesce(v_targets, '{}'))) then
    raise exception 'mapping: name and category are required' using errcode = '22023';
  end if;
  if p_template_id is not null and not exists (
    select 1 from public.import_mapping_template
    where id = p_template_id and tenant_id = v_batch.tenant_id and deleted_at is null) then
    raise exception 'template not found' using errcode = 'P0002';
  end if;

  update public.import_batch
  set mapping = (select jsonb_agg(jsonb_build_object('target', e ->> 'target', 'source', e ->> 'source')
                                  order by n)
                 from jsonb_array_elements(p_mapping) with ordinality as x (e, n)),
      mapping_template_id = p_template_id,
      status = 'mapped',
      updated_by = auth.uid()
  where id = v_batch.id;
end;
$$;
revoke all on function public.import_save_mapping(uuid, jsonb, uuid) from public, anon;
grant execute on function public.import_save_mapping(uuid, jsonb, uuid) to authenticated;

-- I9 again: mapped batches expire the same way as staged ones.
create or replace function private.purge_expired_imports()
returns void language plpgsql set search_path = '' as $$
begin
  delete from public.import_row r
  using public.import_batch b
  where b.tenant_id = r.tenant_id and b.id = r.batch_id
    and b.status in ('staged', 'mapped') and b.expires_at <= now();
  update public.import_batch set status = 'expired'
  where status in ('staged', 'mapped') and expires_at <= now();
end;
$$;
