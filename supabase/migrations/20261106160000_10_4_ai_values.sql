-- Story 10.4: AI value matching (docs/data-model-goal10.md §4.2).
-- OWNER REVIEW (CLAUDE.md §9): a new security definer import_decide_values, and import_validate (definer) now
-- reads accepted matches. The service suggests an existing record for a category, location, vendor or status
-- value that 8.4 could not find; a person accepts or rejects it here. Nothing creates master data (D5). The batch
-- keeps the raw value (a cell the user uploaded, like import_row), the record id, confidence and reason; the 1.5
-- row trigger audits every change (§6.4).

alter table public.import_batch
  add column value_suggestions jsonb null
    check (value_suggestions is null or jsonb_typeof(value_suggestions) = 'array');

-- Merges decisions into value_suggestions by (column, raw), last write wins. The service stores its
-- suggestions here with status 'suggested'; the user then accepts (the AI pick or another record) or rejects.
-- Definer because users have no update on import_batch (8.2). So the checks an RLS read would make are made
-- here by hand: the record must be live, active and in a domain the caller may view.
create function public.import_decide_values(p_batch_id uuid, p_decisions jsonb)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare
  v_batch  public.import_batch;
  v_merged jsonb;
  v_decide boolean;
begin
  if not private.has_permission('excel_import', 'review') or not private.tenant_can_write() then
    raise exception 'not allowed' using errcode = '42501';
  end if;
  select * into v_batch from public.import_batch
  where id = p_batch_id and tenant_id = private.current_tenant_id() for update;
  if not found then
    raise exception 'batch not found' using errcode = 'P0002';
  end if;
  if v_batch.status not in ('mapped', 'validated') then
    raise exception 'batch is %', v_batch.status using errcode = '22023';
  end if;
  if p_decisions is null or jsonb_typeof(p_decisions) <> 'array' or jsonb_array_length(p_decisions) not between 1 and 200 then
    raise exception 'decisions: 1 to 200 entries' using errcode = '22023';
  end if;
  if exists (select 1 from jsonb_array_elements(p_decisions) e
             where jsonb_typeof(e) <> 'object'
                or coalesce(e ->> 'column', '') not in ('category', 'location', 'vendor', 'status')
                or coalesce(jsonb_typeof(e -> 'raw'), '') <> 'string' or length(e ->> 'raw') not between 1 and 80
                or coalesce(e ->> 'status', '') not in ('suggested', 'accepted', 'rejected')
                or coalesce(jsonb_typeof(e -> 'target_id'), '') <> 'string'
                or (e ->> 'target_id') !~ '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'
                or coalesce(jsonb_typeof(e -> 'confidence'), 'null') not in ('null', 'number')
                or coalesce(jsonb_typeof(e -> 'reason'), 'null') not in ('null', 'string')
                or coalesce(e ->> 'reason', 'similar') not in ('name_variant', 'abbreviation', 'similar')) then
    raise exception 'decisions: each entry needs column, raw, target_id and status' using errcode = '22023';
  end if;
  if exists (select 1 from jsonb_array_elements(p_decisions) e
             where jsonb_typeof(e -> 'confidence') = 'number' and (e ->> 'confidence')::numeric not between 0 and 1) then
    raise exception 'decisions: confidence is a number from 0 to 1' using errcode = '22023';
  end if;
  if (select count(*) <> count(distinct (e ->> 'column', e ->> 'raw')) from jsonb_array_elements(p_decisions) e) then
    raise exception 'decisions: a value is decided twice' using errcode = '22023';
  end if;
  -- Only existing records the caller may see (the select policies of 2.1, 2.3, 3.7 and 4.1). Never a new one.
  if exists (select 1 from jsonb_array_elements(p_decisions) e
             where not case e ->> 'column'
               when 'category' then private.has_permission('category_config', 'view') and exists (
                 select 1 from public.asset_category c where c.tenant_id = v_batch.tenant_id
                   and c.id = (e ->> 'target_id')::uuid and c.is_active and c.deleted_at is null)
               when 'location' then private.has_permission('location_hierarchy', 'view') and exists (
                 select 1 from public.location l where l.tenant_id = v_batch.tenant_id
                   and l.id = (e ->> 'target_id')::uuid and l.active and l.deleted_at is null)
               when 'vendor' then private.has_permission('vendor_core', 'view') and exists (
                 select 1 from public.vendor o where o.tenant_id = v_batch.tenant_id
                   and o.id = (e ->> 'target_id')::uuid and o.is_active and o.deleted_at is null)
               else (private.has_permission('category_config', 'view') or private.has_permission('asset_core', 'view'))
                 and exists (select 1 from public.asset_status s where s.tenant_id = v_batch.tenant_id
                   and s.id = (e ->> 'target_id')::uuid and s.is_active and s.deleted_at is null)
             end) then
    raise exception 'decisions: unknown or not allowed record' using errcode = '22023';
  end if;

  select coalesce(jsonb_agg(x.e order by x.e ->> 'column', x.e ->> 'raw'), '[]') into v_merged
  from (select o as e from jsonb_array_elements(coalesce(v_batch.value_suggestions, '[]')) o
        where not exists (select 1 from jsonb_array_elements(p_decisions) d
                          where d ->> 'column' = o ->> 'column' and d ->> 'raw' = o ->> 'raw')
        union all
        select jsonb_strip_nulls(jsonb_build_object('column', d ->> 'column', 'raw', d ->> 'raw',
                 'target_id', d ->> 'target_id', 'confidence', d -> 'confidence', 'reason', d -> 'reason',
                 'status', d ->> 'status'))
        from jsonb_array_elements(p_decisions) d) x;
  if jsonb_array_length(v_merged) > 1000 then
    raise exception 'decisions: too many values in one batch' using errcode = '22023';
  end if;

  -- A decision changes what validation finds (V8): the batch is mapped again until import_validate runs.
  -- Suggestions alone leave the results as they are.
  v_decide := exists (select 1 from jsonb_array_elements(p_decisions) d where d ->> 'status' <> 'suggested');
  update public.import_batch
  set value_suggestions = v_merged,
      status = case when v_decide then 'mapped' else status end,
      summary = case when v_decide then null else summary end,
      updated_by = auth.uid()
  where id = v_batch.id;
  return v_merged;
end;
$$;
revoke all on function public.import_decide_values(uuid, jsonb) from public, anon;
grant execute on function public.import_decide_values(uuid, jsonb) to authenticated;

-- import_validate: the 8.4 body, plus one step after the lookups. An accepted match fills a lookup that found
-- nothing, so every row with that raw value resolves. The record must still be live and active.
create or replace function public.import_validate(p_batch_id uuid)
returns jsonb language plpgsql security definer set search_path = '' set client_min_messages = warning as $$
declare
  v_batch   public.import_batch;
  v_tenant  public.tenant;
  v_col     jsonb;   -- target -> column index (0-based, as in cells)
  v_create  boolean := private.has_permission('asset_core', 'create');
  v_set_tag boolean := private.has_permission('asset_core', 'set_tag');
  v_money   boolean := private.has_permission('asset_financials', 'update');
  v_view    boolean := private.has_permission('asset_core', 'view');
  v_all     boolean := private.scope_all('asset_core', 'create');
  v_summary jsonb;
begin
  if not (private.has_permission('excel_import', 'run') or private.has_permission('excel_import', 'review'))
     or not private.tenant_can_write() then
    raise exception 'not allowed' using errcode = '42501';
  end if;
  select * into v_batch from public.import_batch
  where id = p_batch_id and tenant_id = private.current_tenant_id() for update;
  if not found then
    raise exception 'batch not found' using errcode = 'P0002';
  end if;
  if v_batch.status not in ('mapped', 'validated') then
    raise exception 'batch is %', v_batch.status using errcode = '22023';
  end if;
  -- Rights may have changed since the save: a target the caller may no longer set means map again.
  if exists (select 1 from jsonb_array_elements(v_batch.mapping) e
             where e ->> 'target' <> 'ignore'
               and e ->> 'target' not in (select c.target from public.import_target_catalog() c)) then
    raise exception 'mapping: unknown or not allowed target' using errcode = '22023';
  end if;
  select * into v_tenant from public.tenant where id = v_batch.tenant_id;
  select coalesce(jsonb_object_agg(e ->> 'target', n - 1), '{}') into v_col
  from jsonb_array_elements(v_batch.mapping) with ordinality as x (e, n) where e ->> 'target' <> 'ignore';

  drop table if exists pg_temp.import_v, pg_temp.import_m, pg_temp.import_c, pg_temp.import_line, pg_temp.import_k,
    pg_temp.import_src;
  create temp table import_v (
    id uuid primary key, rn int,
    tag text, name text, category text, location text, status text, criticality text, quantity jsonb,
    parent_tag text, serial_number text, manufacturer text, model text, purchase_date jsonb, purchase_value jsonb,
    purchase_currency text, in_service_date jsonb, oem_vendor text, om_vendor text, warranty_start jsonb, warranty_end jsonb,
    category_id uuid, location_id uuid, location_many boolean, status_id uuid, status_system text, parent_id uuid,
    oem_id uuid, om_id uuid, d_purchase date, d_in_service date, d_w_start date, d_w_end date,
    n_quantity numeric, n_value numeric, currency text, custom jsonb not null default '{}'
  ) on commit drop;
  create temp table import_m (id uuid, col int, code text, params jsonb) on commit drop;
  create temp table import_c (id uuid, col int, key text, raw jsonb, value jsonb) on commit drop;
  create temp table import_line (category_id uuid, ancestor_id uuid, depth int) on commit drop;
  -- One row per distinct cell text and kind, so each lookup runs once per value, not once per row.
  create temp table import_k (kind text, raw text, id uuid, sys text, many boolean) on commit drop;
  -- The batch's rows, analyzed: a batch just uploaded has no stats on import_row, and the planner then
  -- takes 20,000 rows for 1 and picks nested loops that never finish.
  create temp table import_src (id uuid, rn int, cells jsonb) on commit drop;
  insert into pg_temp.import_src
  select r.id, r.row_number, r.cells from public.import_row r
  where r.tenant_id = v_batch.tenant_id and r.batch_id = v_batch.id;
  analyze pg_temp.import_src;

  -- Lookups first (M7), so each row is written once below. Live and active only; nothing is created.
  insert into pg_temp.import_k (kind, raw, id)
  with recursive tree as (
    select c.id, c.is_active, lower(c.code) as code, lower(c.name) as name, lower(c.name) as path
    from public.asset_category c
    where c.tenant_id = v_batch.tenant_id and c.parent_id is null and c.deleted_at is null
    union all
    select c.id, c.is_active, lower(c.code), lower(c.name), t.path || ' / ' || lower(c.name)
    from public.asset_category c join tree t on c.parent_id = t.id
    where c.tenant_id = v_batch.tenant_id and c.deleted_at is null
  ), live as (select * from tree where is_active)
  select 'category', x.raw, coalesce((select l.id from live l where l.code = lower(x.raw) limit 1),
                                     (select l.id from live l where l.name = lower(x.raw) limit 1),
                                     (select l.id from live l where l.path = private.import_path(x.raw) limit 1))
  from (select distinct private.import_text(r.cells -> (v_col ->> 'category')::int) as raw
        from pg_temp.import_src r) x
  where x.raw is not null;

  insert into pg_temp.import_k (kind, raw, id, many)
  with live as (
    select l.id, lower(l.code) as code, lower(l.name) as name,
           (select string_agg(lower(a.name), ' / ' order by c.depth desc)
            from private.location_closure c join public.location a on a.tenant_id = c.tenant_id and a.id = c.ancestor_id
            where c.tenant_id = l.tenant_id and c.descendant_id = l.id) as path
    from public.location l
    where l.tenant_id = v_batch.tenant_id and l.active and l.deleted_at is null
  )
  select 'location', x.raw,
         coalesce((select l.id from live l where l.code = lower(x.raw) limit 1),
                  (select (array_agg(l.id))[1] from live l where l.name = lower(x.raw) having count(*) = 1),
                  (select l.id from live l where l.path = private.import_path(x.raw) limit 1)),
         (select count(*) from live l where l.name = lower(x.raw)) > 1
  from (select distinct private.import_text(r.cells -> (v_col ->> 'location')::int) as raw
        from pg_temp.import_src r) x
  where x.raw is not null;

  -- Status by code, else label. The category's set and the starting status are checked below.
  insert into pg_temp.import_k (kind, raw, id, sys)
  select 'status', x.raw, s.id, s.system_status
  from (select distinct private.import_text(r.cells -> (v_col ->> 'status')::int) as raw
        from pg_temp.import_src r) x
  left join lateral (select s.id, s.system_status from public.asset_status s
                     where s.tenant_id = v_batch.tenant_id and s.is_active and s.deleted_at is null
                       and (s.code = lower(x.raw) or lower(s.label) = lower(x.raw))
                     order by (s.code = lower(x.raw)) desc limit 1) s on true
  where x.raw is not null;

  -- Vendors by code, else name. Role and category tags are checked below.
  insert into pg_temp.import_k (kind, raw, id)
  select 'vendor', x.raw, (select o.id from public.vendor o
                           where o.tenant_id = v_batch.tenant_id and o.is_active and o.deleted_at is null
                             and (o.code = upper(x.raw) or lower(o.name) = lower(x.raw))
                           order by (o.code = upper(x.raw)) desc nulls last limit 1)
  from (select private.import_text(r.cells -> (v_col ->> 'oem_vendor')::int) as raw
        from pg_temp.import_src r
        union
        select private.import_text(r.cells -> (v_col ->> 'om_vendor')::int)
        from pg_temp.import_src r) x
  where x.raw is not null;

  -- V7: an existing live asset the caller can see.
  insert into pg_temp.import_k (kind, raw, id)
  select 'parent', x.raw, a.id
  from (select distinct upper(private.import_text(r.cells -> (v_col ->> 'parent_tag')::int)) as raw
        from pg_temp.import_src r) x
  join public.asset a on a.tenant_id = v_batch.tenant_id and a.tag = x.raw and a.deleted_at is null
  where v_view and private.in_scope('asset_core', 'view', a.location_id, a.category_id);

  -- 10.4: accepted value matches, a raw -> id map for this batch (OEM and O&M vendor share one lookup, as above).
  update pg_temp.import_k k set id = a.id, many = false, sys = a.sys
  from (select s ->> 'column' as kind, s ->> 'raw' as raw, coalesce(c.id, l.id, o.id, st.id) as id, st.system_status as sys
        from jsonb_array_elements(coalesce(v_batch.value_suggestions, '[]')) s
        left join public.asset_category c on s ->> 'column' = 'category' and c.tenant_id = v_batch.tenant_id
          and c.id = (s ->> 'target_id')::uuid and c.is_active and c.deleted_at is null
        left join public.location l on s ->> 'column' = 'location' and l.tenant_id = v_batch.tenant_id
          and l.id = (s ->> 'target_id')::uuid and l.active and l.deleted_at is null
        left join public.vendor o on s ->> 'column' = 'vendor' and o.tenant_id = v_batch.tenant_id
          and o.id = (s ->> 'target_id')::uuid and o.is_active and o.deleted_at is null
        left join public.asset_status st on s ->> 'column' = 'status' and st.tenant_id = v_batch.tenant_id
          and st.id = (s ->> 'target_id')::uuid and st.is_active and st.deleted_at is null
        where s ->> 'status' = 'accepted') a
  where k.id is null and k.kind = a.kind and k.raw = a.raw and a.id is not null;
  analyze pg_temp.import_k;

  -- Custom field values (2.1), parsed by their type. Only fields the caller may set are mapped.
  insert into pg_temp.import_c (id, col, key, raw)
  select r.id, k.col, k.key, r.cells -> k.col
  from pg_temp.import_src r
  cross join (select substr(t.key, 8) as key, t.value::int as col from jsonb_each_text(v_col) t
              where t.key like 'custom:%') k
  where private.import_text(r.cells -> k.col) is not null;
  analyze pg_temp.import_c;

  update pg_temp.import_c c set value = case f.type
      when 'text'    then to_jsonb(private.import_text(c.raw))
      when 'number'  then to_jsonb(private.import_number(c.raw))
      when 'boolean' then to_jsonb(private.import_bool(c.raw))
      when 'date'    then to_jsonb(private.import_date(c.raw, v_tenant.date_format)::text)
      when 'list'    then (select to_jsonb(o ->> 'code') from jsonb_array_elements(f.options) o
                           where coalesce((o ->> 'is_active')::boolean, true)
                             and (lower(o ->> 'code') = lower(private.import_text(c.raw))
                                  or lower(o ->> 'label') = lower(private.import_text(c.raw)))
                           limit 1)
    end
  from public.field_definition f
  where f.tenant_id = v_batch.tenant_id and f.entity = 'asset' and f.key = c.key;

  -- 1 and 2. Read the mapped cells (an unmapped target reads cells -> null), parse them and join the
  -- lookups, in one pass. A blank cell is null, so "given" is just "is not null".
  insert into pg_temp.import_v (id, rn, tag, name, category, location, status, criticality, quantity, parent_tag,
    serial_number, manufacturer, model, purchase_date, purchase_value, purchase_currency, in_service_date,
    oem_vendor, om_vendor, warranty_start, warranty_end,
    d_purchase, d_in_service, d_w_start, d_w_end, n_quantity, n_value, currency,
    category_id, location_id, location_many, status_id, status_system, parent_id, oem_id, om_id, custom)
  select c.id, c.rn, c.tag, c.name, c.category, c.location, c.status, c.criticality, c.quantity, c.parent_tag,
    c.serial_number, c.manufacturer, c.model, c.purchase_date, c.purchase_value, c.purchase_currency, c.in_service_date,
    c.oem_vendor, c.om_vendor, c.warranty_start, c.warranty_end,
    private.import_date(c.purchase_date, v_tenant.date_format), private.import_date(c.in_service_date, v_tenant.date_format),
    private.import_date(c.warranty_start, v_tenant.date_format), private.import_date(c.warranty_end, v_tenant.date_format),
    private.import_number(c.quantity), private.import_number(c.purchase_value),
    coalesce(c.purchase_currency, case when c.purchase_value is not null then v_tenant.currency_code end),
    kc.id, kl.id, kl.many, ks.id, ks.sys, kp.id, ko.id, km.id, coalesce(cu.obj, '{}')
  from (
    select r.id, r.rn,
      upper(private.import_text(r.cells -> (v_col ->> 'tag')::int)) as tag,
      private.import_text(r.cells -> (v_col ->> 'name')::int) as name,
      private.import_text(r.cells -> (v_col ->> 'category')::int) as category,
      private.import_text(r.cells -> (v_col ->> 'location')::int) as location,
      private.import_text(r.cells -> (v_col ->> 'status')::int) as status,
      upper(private.import_text(r.cells -> (v_col ->> 'criticality')::int)) as criticality,
      upper(private.import_text(r.cells -> (v_col ->> 'parent_tag')::int)) as parent_tag,
      private.import_text(r.cells -> (v_col ->> 'serial_number')::int) as serial_number,
      private.import_text(r.cells -> (v_col ->> 'manufacturer')::int) as manufacturer,
      private.import_text(r.cells -> (v_col ->> 'model')::int) as model,
      upper(private.import_text(r.cells -> (v_col ->> 'purchase_currency')::int)) as purchase_currency,
      private.import_text(r.cells -> (v_col ->> 'oem_vendor')::int) as oem_vendor,
      private.import_text(r.cells -> (v_col ->> 'om_vendor')::int) as om_vendor,
      case when private.import_text(j.quantity) is not null then j.quantity end as quantity,
      case when private.import_text(j.purchase_date) is not null then j.purchase_date end as purchase_date,
      case when private.import_text(j.purchase_value) is not null then j.purchase_value end as purchase_value,
      case when private.import_text(j.in_service_date) is not null then j.in_service_date end as in_service_date,
      case when private.import_text(j.warranty_start) is not null then j.warranty_start end as warranty_start,
      case when private.import_text(j.warranty_end) is not null then j.warranty_end end as warranty_end
    from pg_temp.import_src r
    cross join lateral (select r.cells -> (v_col ->> 'quantity')::int as quantity,
                               r.cells -> (v_col ->> 'purchase_date')::int as purchase_date,
                               r.cells -> (v_col ->> 'purchase_value')::int as purchase_value,
                               r.cells -> (v_col ->> 'in_service_date')::int as in_service_date,
                               r.cells -> (v_col ->> 'warranty_start')::int as warranty_start,
                               r.cells -> (v_col ->> 'warranty_end')::int as warranty_end) j
  ) c
  left join pg_temp.import_k kc on kc.kind = 'category' and kc.raw = c.category
  left join pg_temp.import_k kl on kl.kind = 'location' and kl.raw = c.location
  left join pg_temp.import_k ks on ks.kind = 'status' and ks.raw = c.status
  left join pg_temp.import_k kp on kp.kind = 'parent' and kp.raw = c.parent_tag
  left join pg_temp.import_k ko on ko.kind = 'vendor' and ko.raw = c.oem_vendor
  left join pg_temp.import_k km on km.kind = 'vendor' and km.raw = c.om_vendor
  left join (select x.id, jsonb_object_agg(x.key, x.value) as obj from pg_temp.import_c x
             where x.value is not null and x.value <> 'null' group by x.id) cu on cu.id = c.id;
  analyze pg_temp.import_v;  -- temp tables have no stats; without them the joins below plan as nested loops

  insert into pg_temp.import_m (id, col, code, params)
  select v.id, (v_col ->> x.t)::int, 'date_format', jsonb_build_object('format', v_tenant.date_format)
  from pg_temp.import_v v
  cross join lateral (values ('purchase_date', v.purchase_date, v.d_purchase), ('in_service_date', v.in_service_date, v.d_in_service),
                             ('warranty_start', v.warranty_start, v.d_w_start), ('warranty_end', v.warranty_end, v.d_w_end)) x (t, raw, val)
  where x.raw is not null and x.val is null
  union all
  select v.id, (v_col ->> 'quantity')::int, 'number_format', '{"min": 1, "integer": true}'
  from pg_temp.import_v v
  where v.quantity is not null and (v.n_quantity is null or v.n_quantity < 1 or v.n_quantity >= 1e9 or v.n_quantity <> trunc(v.n_quantity))
  union all
  select v.id, (v_col ->> 'purchase_value')::int, 'number_format', '{"min": 0}'
  from pg_temp.import_v v
  where v.purchase_value is not null and (v.n_value is null or v.n_value < 0 or v.n_value >= 1e15)
  union all
  select v.id, (v_col ->> 'purchase_currency')::int, 'currency_format', null::jsonb
  from pg_temp.import_v v where v.purchase_currency is not null and v.purchase_currency !~ '^[A-Z]{3}$'
  union all  -- V10
  select v.id, coalesce((v_col ->> 'purchase_currency')::int, (v_col ->> 'purchase_value')::int), 'currency_defaulted',
         jsonb_build_object('currency', v_tenant.currency_code)
  from pg_temp.import_v v where v.purchase_value is not null and v.purchase_currency is null
  union all
  select v.id, (v_col ->> 'criticality')::int, 'bad_option', '{"options": ["A", "B", "C"]}'
  from pg_temp.import_v v where v.criticality is not null and v.criticality not in ('A', 'B', 'C')
  union all
  select v.id, (v_col ->> 'tag')::int, 'tag_format', null::jsonb
  from pg_temp.import_v v where v.tag is not null and v.tag !~ '^[A-Z0-9][A-Z0-9._/-]{0,59}$';

  -- 3. Required: name, category, the tenant's list (purchase value only for who may set it).
  insert into pg_temp.import_m (id, col, code, params)
  select v.id, (v_col ->> x.t)::int, 'required', jsonb_build_object('field', x.t)
  from pg_temp.import_v v
  cross join lateral (values ('name', v.name is null), ('category', v.category is null),
    ('serial_number', v.serial_number is null), ('manufacturer', v.manufacturer is null), ('model', v.model is null),
    ('location', v.location is null), ('purchase_date', v.purchase_date is null),
    ('purchase_value', v.purchase_value is null), ('in_service_date', v.in_service_date is null)) x (t, missing)
  where x.missing
    and (x.t in ('name', 'category') or x.t = any (v_tenant.required_asset_fields))
    and (x.t <> 'purchase_value' or v_money);

  -- 4. Lookups (found above).
  insert into pg_temp.import_m (id, col, code, params)
  select v.id, (v_col ->> 'category')::int, 'not_found', null::jsonb
  from pg_temp.import_v v where v.category is not null and v.category_id is null
  union all
  select v.id, (v_col ->> 'location')::int, case when v.location_many then 'ambiguous' else 'not_found' end, null::jsonb
  from pg_temp.import_v v where v.location is not null and v.location_id is null
  union all
  select v.id, (v_col ->> 'status')::int, 'not_found', null::jsonb
  from pg_temp.import_v v where v.status is not null and v.status_id is null
  union all
  select v.id, (v_col ->> 'oem_vendor')::int, 'not_found', null::jsonb
  from pg_temp.import_v v where v.oem_vendor is not null and v.oem_id is null
  union all
  select v.id, (v_col ->> 'om_vendor')::int, 'not_found', null::jsonb
  from pg_temp.import_v v where v.om_vendor is not null and v.om_id is null
  union all
  select v.id, (v_col ->> 'parent_tag')::int, 'parent_not_found', null::jsonb
  from pg_temp.import_v v where v.parent_tag is not null and v.parent_id is null;

  -- Per distinct category: its line (self and ancestors), its status set and its vendors.
  insert into pg_temp.import_line (category_id, ancestor_id, depth)
  with recursive up as (
    select c.id as category_id, c.id as ancestor_id, c.parent_id, 0 as depth
    from public.asset_category c
    where c.tenant_id = v_batch.tenant_id and c.id in (select category_id from pg_temp.import_v)
    union all
    select up.category_id, c.id, c.parent_id, up.depth + 1
    from public.asset_category c join up on c.tenant_id = v_batch.tenant_id and c.id = up.parent_id
  )
  select category_id, ancestor_id, depth from up;
  analyze pg_temp.import_line;

  with cat as (
    select c.id, private.effective_status_ids(v_batch.tenant_id, c.id) as statuses,
           private.allowed_vendor_ids(v_batch.tenant_id, c.id, 'oem') as oem,
           private.allowed_vendor_ids(v_batch.tenant_id, c.id, 'om') as om
    from (select distinct category_id as id from pg_temp.import_v where category_id is not null) c
  )
  insert into pg_temp.import_m (id, col, code, params)
  select v.id, (v_col ->> 'status')::int, 'status_not_allowed', null::jsonb
  from pg_temp.import_v v join cat on cat.id = v.category_id
  where v.status_id is not null and (v.status_system not in ('in_stock', 'active') or v.status_id <> all (cat.statuses))
  union all
  select v.id, (v_col ->> 'oem_vendor')::int, 'vendor_not_for_category', null::jsonb
  from pg_temp.import_v v join cat on cat.id = v.category_id
  where v.oem_id is not null and v.oem_id <> all (cat.oem)
  union all
  select v.id, (v_col ->> 'om_vendor')::int, 'vendor_not_for_category', null::jsonb
  from pg_temp.import_v v join cat on cat.id = v.category_id
  where v.om_id is not null and v.om_id <> all (cat.om);

  -- 5. Custom fields (2.1): type, options, category line, required.
  insert into pg_temp.import_m (id, col, code, params)
  with req as materialized (  -- once per field, not per row
    select f.key, f.category_id from public.field_definition f
    join public.security_domain d on d.id = f.security_domain_id
    where f.tenant_id = v_batch.tenant_id and f.entity = 'asset' and f.is_required and f.is_active
      and f.deleted_at is null and private.has_permission(d.code, 'update')
  )
  select c.id, c.col,
         case f.type when 'number' then 'number_format' when 'date' then 'date_format'
                     when 'boolean' then 'bool_format' else 'bad_option' end,
         case when f.type = 'date' then jsonb_build_object('format', v_tenant.date_format) end
  from pg_temp.import_c c
  join public.field_definition f on f.tenant_id = v_batch.tenant_id and f.entity = 'asset' and f.key = c.key
  where c.value is null or c.value = 'null'
  union all
  select c.id, c.col, 'not_for_category', null::jsonb
  from pg_temp.import_c c
  join pg_temp.import_v v on v.id = c.id
  join public.field_definition f on f.tenant_id = v_batch.tenant_id and f.entity = 'asset' and f.key = c.key
  where f.category_id is not null and v.category_id is not null
    and not exists (select 1 from pg_temp.import_line l where l.category_id = v.category_id and l.ancestor_id = f.category_id)
  union all
  select v.id, (v_col ->> ('custom:' || f.key))::int, 'required', jsonb_build_object('field', 'custom:' || f.key)
  from pg_temp.import_v v
  cross join req f
  where v.category_id is not null
    and (f.category_id is null
         or exists (select 1 from pg_temp.import_line l where l.category_id = v.category_id and l.ancestor_id = f.category_id))
    and not exists (select 1 from pg_temp.import_c c where c.id = v.id and c.key = f.key);

  -- 6. Duplicates (V5) and the tag (3.8).
  insert into pg_temp.import_m (id, col, code, params)
  select v.id, (v_col ->> 'tag')::int, 'tag_not_allowed', null::jsonb
  from pg_temp.import_v v where v.tag is not null and not v_set_tag
  union all
  select d.id, (v_col ->> 'tag')::int, 'duplicate_in_file', null::jsonb
  from (select v.id, count(*) over (partition by v.tag) as n from pg_temp.import_v v where v.tag is not null) d
  where d.n > 1
  union all
  select v.id, (v_col ->> 'tag')::int, 'tag_exists', null::jsonb
  from pg_temp.import_v v
  where v.tag is not null
    and exists (select 1 from public.asset a where a.tenant_id = v_batch.tenant_id and a.tag = v.tag and a.deleted_at is null)
  union all
  select v.id, (v_col ->> 'category')::int, 'tag_needs_category_code', null::jsonb
  from pg_temp.import_v v
  where v.tag is null and v.category_id is not null and strpos(v_tenant.asset_tag_pattern, '{CAT}') > 0
    and not exists (select 1 from pg_temp.import_line l
                    join public.asset_category c on c.tenant_id = v_batch.tenant_id and c.id = l.ancestor_id
                    where l.category_id = v.category_id and c.code is not null)
  union all
  select v.id, (v_col ->> 'location')::int, 'tag_needs_location_code', null::jsonb
  from pg_temp.import_v v
  where v.tag is null and strpos(v_tenant.asset_tag_pattern, '{LOC}') > 0
    and (v.location is null or v.location_id is not null)
    and not exists (select 1 from private.location_closure c
                    join public.location l on l.tenant_id = c.tenant_id and l.id = c.ancestor_id
                    where c.tenant_id = v_batch.tenant_id and c.descendant_id = v.location_id and l.code is not null)
  union all
  select d.id, null, 'possible_duplicate', null::jsonb
  from (select v.id, v.tag, v.serial_number, v.manufacturer,
               count(*) over (partition by lower(v.serial_number), lower(v.manufacturer)) as n
        from pg_temp.import_v v where v.serial_number is not null and v.manufacturer is not null) d
  where d.tag is null
    and (d.n > 1 or exists (select 1 from public.asset a where a.tenant_id = v_batch.tenant_id and a.deleted_at is null
                            and lower(a.serial_number) = lower(d.serial_number)
                            and lower(a.manufacturer) = lower(d.manufacturer)));

  -- 7. Warranty pair (M9) and its vendor (V9).
  insert into pg_temp.import_m (id, col, code, params)
  select v.id, (v_col ->> case when v.warranty_start is null then 'warranty_start' else 'warranty_end' end)::int,
         'warranty_incomplete', null::jsonb
  from pg_temp.import_v v where (v.warranty_start is null) <> (v.warranty_end is null)
  union all
  select v.id, (v_col ->> 'warranty_end')::int, 'warranty_dates', null::jsonb
  from pg_temp.import_v v where v.d_w_end < v.d_w_start
  union all
  select v.id, (v_col ->> 'warranty_start')::int, 'warranty_vendor', null::jsonb
  from pg_temp.import_v v
  where v.warranty_start is not null and v.warranty_end is not null and v.oem_vendor is null and v.om_vendor is null;

  -- 8. Rights and row scope (6.1) of the caller, per distinct location and category.
  insert into pg_temp.import_m (id, col, code, params)
  select v.id, null, 'no_create_right', null::jsonb
  from pg_temp.import_v v where not v_create
  union all
  select v.id, coalesce((v_col ->> 'location')::int, (v_col ->> 'category')::int), 'out_of_scope', null::jsonb
  from pg_temp.import_v v
  join (select p.location_id, p.category_id,
               private.in_scope('asset_core', 'create', p.location_id, p.category_id) as ok
        from (select distinct location_id, category_id from pg_temp.import_v where category_id is not null) p) s
    on s.category_id = v.category_id and s.location_id is not distinct from v.location_id
  where v_create and not v_all and not s.ok;

  analyze pg_temp.import_m;

  -- Results, the payload 8.6 inserts (V2), and the summary.
  update public.import_row r set
    messages = m.msgs,
    result   = case when m.err then 'error' when m.msgs is not null then 'warning' else 'ok' end,
    payload  = case when not coalesce(m.err, false) then jsonb_strip_nulls(jsonb_build_object(
      'asset', jsonb_build_object(
        'tag', v.tag, 'name', v.name, 'category_id', v.category_id, 'location_id', v.location_id,
        'status_id', v.status_id, 'criticality', v.criticality, 'quantity', v.n_quantity::int,
        'parent_asset_id', v.parent_id, 'serial_number', v.serial_number, 'manufacturer', v.manufacturer,
        'model', v.model, 'purchase_date', v.d_purchase, 'purchase_value', v.n_value,
        'purchase_currency', case when v.n_value is not null or v.purchase_currency is not null then v.currency end,
        'in_service_date', v.d_in_service, 'oem_vendor_id', v.oem_id, 'om_vendor_id', v.om_id,
        'custom_values', v.custom),
      'coverage', case when v.d_w_start is not null then jsonb_build_object(
        'coverage_type', 'warranty', 'vendor_id', coalesce(v.oem_id, v.om_id),
        'start_date', v.d_w_start, 'end_date', v.d_w_end) end)) end
  from pg_temp.import_v v
  left join (select m.id,
                    jsonb_agg(jsonb_strip_nulls(jsonb_build_object('col', m.col, 'code', m.code, 'params', m.params))
                              order by m.col nulls first, m.code) as msgs,
                    bool_or(m.code not in ('currency_defaulted', 'possible_duplicate')) as err
             from pg_temp.import_m m group by m.id) m on m.id = v.id
  where r.tenant_id = v_batch.tenant_id and r.batch_id = v_batch.id and r.id = v.id;

  select jsonb_build_object(
      'ok', count(*) filter (where r.result = 'ok'),
      'warning', count(*) filter (where r.result = 'warning'),
      'error', count(*) filter (where r.result = 'error'),
      'create_assets', count(*) filter (where r.result <> 'error'),
      'create_coverages', count(*) filter (where r.result <> 'error' and r.payload ? 'coverage'),
      'skip', count(*) filter (where r.result = 'error'),
      'codes', coalesce((select jsonb_object_agg(c.code, c.n)
                         from (select m.code, count(*) as n from pg_temp.import_m m group by m.code) c), '{}'),
      'validated_at', now(),
      'as_user', auth.uid())
  into v_summary
  from public.import_row r
  where r.tenant_id = v_batch.tenant_id and r.batch_id = v_batch.id;

  update public.import_batch set summary = v_summary, status = 'validated', updated_by = auth.uid()
  where id = v_batch.id;
  return v_summary;
end;
$$;
revoke all on function public.import_validate(uuid) from public, anon;
grant execute on function public.import_validate(uuid) to authenticated;
