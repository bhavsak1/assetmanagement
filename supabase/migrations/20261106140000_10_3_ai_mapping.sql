-- Story 10.3: AI column mapping (docs/data-model-goal10.md §4.1).
-- OWNER REVIEW (CLAUDE.md §9): a change to the security definer import_save_mapping.
-- The service suggests AI targets (source 'ai'); the user confirms them here like any other entry. A mapping
-- entry may now carry confidence, a number from 0 to 1, on 'ai' entries only. The batch keeps it (§6.4: the
-- AI mark lives in the import, audited by the 1.5 row trigger). No new table, column or right. Same body as
-- 8.4 otherwise.
create or replace function public.import_save_mapping(p_batch_id uuid, p_mapping jsonb, p_template_id uuid default null)
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
  if v_batch.status not in ('staged', 'mapped', 'validated') then
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
  if exists (select 1 from jsonb_array_elements(p_mapping) e
             where e ? 'confidence' and jsonb_typeof(e -> 'confidence') <> 'null'
               and (e ->> 'source' <> 'ai' or jsonb_typeof(e -> 'confidence') <> 'number'
                    or case when jsonb_typeof(e -> 'confidence') = 'number'
                            then (e ->> 'confidence')::numeric not between 0 and 1 end)) then
    raise exception 'mapping: confidence is a number from 0 to 1, on AI entries only' using errcode = '22023';
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
  set mapping = (select jsonb_agg(jsonb_strip_nulls(jsonb_build_object('target', e ->> 'target', 'source', e ->> 'source',
                                                                    'confidence', e -> 'confidence'))
                                  order by n)
                 from jsonb_array_elements(p_mapping) with ordinality as x (e, n)),
      mapping_template_id = p_template_id,
      status = 'mapped',
      summary = null,
      updated_by = auth.uid()
  where id = v_batch.id;
end;
$$;
