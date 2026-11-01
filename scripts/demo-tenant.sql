-- Story 5.6: the demo tenant "Demo Manufacturing Pvt Ltd" (slug demo-manufacturing). Not a migration, not shipped.
-- Design and owner decisions B1 to B7: docs/data-model-goal5.md §15.2 (accepted 1 Nov 2026).
-- Run as postgres: staging via Supabase MCP execute_sql or psql (the 1.6b way); locally
--   docker exec -i supabase_db_assetly psql -U postgres < scripts/demo-tenant.sql
-- One DO block, so it is all or nothing. Each run retires the previous demo copy (renamed, suspended,
-- memberships disabled; the audit log is append-only, so nothing is deleted) and builds a fresh one.
-- Guards: only the tenant with the demo slug AND the demo name is touched; it stops if a demo email is a
-- member of any non-demo tenant. Auth users are never created here and no password is handled: the owner
-- adds them in the dashboard (auto-confirm); a missing one gives a NOTICE and is skipped (B5).
-- Data is deterministic (no random()), dates are relative to the tenant's today.
do $$
declare
  c_slug   constant text := 'demo-manufacturing';
  c_name   constant text := 'Demo Manufacturing Pvt Ltd';
  c_retired constant text := '^demo-manufacturing-r[0-9]{14}$';
  c_users  constant text[][] := array[
    ['bhavsar.krunal.h+demo-admin@gmail.com',   'tenant_admin'],
    ['bhavsar.krunal.h+demo-manager@gmail.com', 'plant_manager'],
    ['bhavsar.krunal.h+demo-planner@gmail.com', 'planner'],
    ['bhavsar.krunal.h+demo-tech@gmail.com',    'technician'],
    ['bhavsar.krunal.h+demo-auditor@gmail.com', 'auditor']];
  v_email  text;
  v_bad    text;
  v_old    uuid;
  v_oldname text;
  v_stamp  timestamptz := clock_timestamp();
  v_tid    uuid;
  v_today  date := (now() at time zone 'Asia/Kolkata')::date;
  v_uid    uuid;
  v_gid    uuid;
  v_tech   uuid;
  v_set    uuid[];
  i        int;
begin
  -- Guard 1: no demo email may already reach a real tenant (a typo must not give a real user demo access).
  select string_agg(u.email || ' in ' || t.name, ', ') into v_bad
  from auth.users u
  join public.tenant_membership m on m.user_id = u.id and m.deleted_at is null
  join public.tenant t on t.id = m.tenant_id
  where lower(u.email) in (select lower(c_users[k][1]) from generate_subscripts(c_users, 1) k)
    and t.slug <> c_slug and t.slug !~ c_retired;
  if v_bad is not null then
    raise exception 'Stopped: demo users belong to a non-demo tenant: %', v_bad;
  end if;

  -- Guard 2: the slug must hold the demo tenant, by name, before it is retired.
  select id, name into v_old, v_oldname from public.tenant where slug = c_slug;
  if v_old is not null and v_oldname <> c_name then
    raise exception 'Stopped: tenant % is "%", not "%". This script only touches the demo tenant.', c_slug, v_oldname, c_name;
  end if;

  -- Reset (B3): retire the old copy.
  if v_old is not null then
    update public.tenant
    set name = 'Demo Manufacturing (retired ' || to_char(v_stamp at time zone 'UTC', 'YYYY-MM-DD HH24:MI:SS') || ')',
        slug = c_slug || '-r' || to_char(v_stamp at time zone 'UTC', 'YYYYMMDDHH24MISS'),
        status = 'suspended'
    where id = v_old;
    update public.tenant_membership set status = 'disabled' where tenant_id = v_old and status = 'active';
    raise notice 'Retired the previous demo tenant %', v_old;
  end if;

  -- Tenant, starter groups, statuses (5 defaults come from the tenant trigger).
  insert into public.tenant (name, slug, currency_code, locale, time_zone, date_format, fiscal_year_start_month, asset_tag_pattern)
  values (c_name, c_slug, 'INR', 'en-IN', 'Asia/Kolkata', 'dd-MM-yyyy', 4, '{LOC}-{CAT}-{SEQ:4}')
  returning id into v_tid;
  perform private.seed_starter_groups(v_tid);
  insert into public.asset_status (tenant_id, code, label, system_status, tone) values
    (v_tid, 'standby',      'Standby',      'in_stock',          'neutral'),
    (v_tid, 'under_repair', 'Under repair', 'under_maintenance', 'warn');

  -- Demo users (B4, B5): link existing auth users only.
  for i in 1 .. array_length(c_users, 1) loop
    v_email := c_users[i][1];
    select id into v_uid from auth.users where lower(email) = lower(v_email);
    if v_uid is null then
      raise notice 'Skipped %: no auth user. Add it in the dashboard (auto-confirm), then run again.', v_email;
      continue;
    end if;
    select id into v_gid from public.security_group where tenant_id = v_tid and template_code = 'starter.' || c_users[i][2];
    insert into public.user_profile (id, display_name, email)
    values (v_uid, split_part(v_email, '@', 1), v_email)
    on conflict (id) do nothing;
    insert into public.tenant_membership (tenant_id, user_id) values (v_tid, v_uid);
    insert into public.user_group_assignment (tenant_id, user_id, security_group_id) values (v_tid, v_uid, v_gid);
    if c_users[i][2] = 'technician' then
      v_tech := v_uid;
    end if;
  end loop;

  -- Locations: 3 plants (codes feed {LOC} in tags), shops, bays and stores. 14 nodes.
  insert into public.location (tenant_id, name, code, location_type) values
    (v_tid, 'Plant 1 · Pune (Chakan)',      'PUN', 'Plant'),
    (v_tid, 'Plant 2 · Nashik (Satpur)',    'NSK', 'Plant'),
    (v_tid, 'Plant 3 · Aurangabad (Waluj)', 'AUR', 'Plant');
  insert into public.location (tenant_id, parent_id, name, location_type)
  select v_tid, p.id, c.name, c.type
  from (values ('PUN', 'Machine Shop', 'Shop'), ('PUN', 'Utility Bay', 'Bay'), ('PUN', 'Quality Lab', 'Lab'), ('PUN', 'Stores', 'Store'),
               ('NSK', 'Press Shop', 'Shop'), ('NSK', 'Paint Shop', 'Shop'), ('NSK', 'Utility Bay', 'Bay'), ('NSK', 'Stores', 'Store'),
               ('AUR', 'Assembly Line', 'Shop'), ('AUR', 'Utility Bay', 'Bay'), ('AUR', 'Stores', 'Store')) c (plant, name, type)
  join public.location p on p.tenant_id = v_tid and p.code = c.plant;

  -- Vendors: 8, with roles, GSTIN as the optional custom field (vendor_tax_ids), a primary contact each.
  insert into public.field_definition (tenant_id, entity, key, label, type, security_domain_id, pattern)
  select v_tid, 'vendor', 'gstin', 'GSTIN', 'text', d.id, '^[0-9]{2}[A-Z]{5}[0-9]{4}[A-Z][0-9A-Z]Z[0-9A-Z]$'
  from public.security_domain d where d.code = 'vendor_tax_ids';
  insert into public.vendor (tenant_id, name, code, roles, phone, email, address, custom_values)
  select v_tid, v.name, v.code, v.roles, v.phone, v.email, v.address,
         case when v.gstin is null then '{}'::jsonb else jsonb_build_object('gstin', v.gstin) end
  from (values
    ('Deccan Machine Tools Pvt Ltd',       'DMT', '{oem}'::text[],       '+91 20 2712 4400', 'service@deccanmt.example',   'MIDC Bhosari, Pune',       '27AADCD4821K1Z3'),
    ('Sahyadri Compressors & Boilers Ltd', 'SCB', '{oem,om}',            '+91 20 2565 1180', 'care@sahyadricb.example',    'Hadapsar, Pune',           '27AAECS7310M1Z8'),
    ('Godavari Power Systems',             'GPS', '{oem,om}',            '+91 253 235 9020', 'amc@godavaripower.example',  'Ambad MIDC, Nashik',       '27AAFFG2205P1ZQ'),
    ('Polar HVAC Services',                'PHS', '{om}',                '+91 98220 41736',  'desk@polarhvac.example',     'Wakad, Pune',              null),
    ('Shree Ganesh Engineering Works',     'SGE', '{om}',                '+91 98500 22914',  'sgew.works@example.com',     'Chakan MIDC, Pune',        '27ABHPG6634E1ZK'),
    ('Precision Metrology Labs',           'PML', '{om}',                '+91 240 255 7012', 'calib@pmlabs.example',       'Chikalthana, Aurangabad',  '27AAKCP9047H1Z2'),
    ('Konkan Cranes & Forklifts',          'KCF', '{oem,om}',            '+91 22 2778 6650', 'support@konkancf.example',   'Turbhe MIDC, Navi Mumbai', '27AACCK5518R1ZB'),
    ('Western India Industrial Supplies',  'WIS', '{supplier}',          '+91 20 2444 3091', 'orders@wiis.example',        'Bhawani Peth, Pune',       null)
  ) v (name, code, roles, phone, email, address, gstin);
  insert into public.vendor_contact (tenant_id, vendor_id, name, title, phone, email, is_primary)
  select v_tid, v.id, c.name, c.title, c.phone, c.email, true
  from (values ('DMT', 'Rahul Kulkarni', 'Service Manager',  '+91 98230 11872', 'rahul.k@deccanmt.example'),
               ('SCB', 'Sneha Patil',    'Key Accounts',     '+91 98221 50431', 'sneha.p@sahyadricb.example'),
               ('GPS', 'Amit Deshmukh',  'AMC Coordinator',  '+91 98902 66310', 'amit.d@godavaripower.example'),
               ('PHS', 'Imran Shaikh',   'Site Supervisor',  '+91 98220 41736', 'imran@polarhvac.example'),
               ('SGE', 'Ganesh Jadhav',  'Proprietor',       '+91 98500 22914', 'sgew.works@example.com'),
               ('PML', 'Priya Joshi',    'Lab In-charge',    '+91 94220 70815', 'priya.j@pmlabs.example'),
               ('KCF', 'Sanjay Naik',    'Service Engineer', '+91 98670 33528', 'sanjay.n@konkancf.example'),
               ('WIS', 'Meera Shah',     'Sales',            '+91 98810 47291', 'meera@wiis.example')) c (code, name, title, phone, email)
  join public.vendor v on v.tenant_id = v_tid and v.code = c.code;

  -- Categories: 7 groups, 14 leaves with warranty term, default obligations and vendor tags.
  insert into public.asset_category (tenant_id, name, code) values
    (v_tid, 'Machine tools', 'MT'), (v_tid, 'Utilities', 'UT'), (v_tid, 'HVAC', 'HV'),
    (v_tid, 'Material handling', 'MH'), (v_tid, 'Electrical', 'EL'), (v_tid, 'Quality lab', 'QL'), (v_tid, 'IT', 'ITG');

  create temp table demo_leaf (ord int, grp text, name text, code text, asset_name text, n int, months smallint,
    oem text, om text, crit text, maker text, model text, value numeric, obligations jsonb) on commit drop;
  insert into demo_leaf values
    (1,  'MT',  'CNC lathe',    'CNC', 'CNC Turning Centre',          20, 24, 'DMT', 'SGE', 'A', 'Deccan Machine Tools',   'DT-250',  2800000,
     '[{"name":"Quarterly PM service","obligation_type":"service","interval_count":3,"interval_unit":"month","anchor":"completion"},
       {"name":"Half-yearly spindle check","obligation_type":"service","interval_count":6,"interval_unit":"month","anchor":"completion"},
       {"name":"Annual geometry inspection","obligation_type":"inspection","interval_count":1,"interval_unit":"year","anchor":"fixed"}]'),
    (2,  'MT',  'VMC',          'VMC', 'Vertical Machining Centre',   12, 24, 'DMT', 'SGE', 'A', 'Deccan Machine Tools',   'VM-850',  4200000,
     '[{"name":"Quarterly PM service","obligation_type":"service","interval_count":3,"interval_unit":"month","anchor":"completion"},
       {"name":"Half-yearly spindle check","obligation_type":"service","interval_count":6,"interval_unit":"month","anchor":"completion"},
       {"name":"Annual geometry inspection","obligation_type":"inspection","interval_count":1,"interval_unit":"year","anchor":"fixed"}]'),
    (3,  'UT',  'Air compressor', 'CMP', 'Screw Air Compressor',      9, 12, 'SCB', 'SCB', 'B', 'Sahyadri Compressors',   'SC-37',    650000,
     '[{"name":"Quarterly service","obligation_type":"service","interval_count":3,"interval_unit":"month","anchor":"completion"},
       {"name":"Annual pressure vessel inspection","obligation_type":"inspection","interval_count":1,"interval_unit":"year","anchor":"fixed"}]'),
    (4,  'UT',  'DG set',       'DG',  'DG Set 500 kVA',               4, 12, 'GPS', 'GPS', 'A', 'Godavari Power Systems', 'GP-500',  3500000,
     '[{"name":"Quarterly service","obligation_type":"service","interval_count":3,"interval_unit":"month","anchor":"completion"},
       {"name":"Annual load bank test","obligation_type":"inspection","interval_count":1,"interval_unit":"year","anchor":"fixed"}]'),
    (5,  'UT',  'Boiler',       'BLR', 'Steam Boiler 2 TPH',           3, 12, 'SCB', 'SCB', 'A', 'Sahyadri Boilers',       'SB-2T',   2200000,
     '[{"name":"Half-yearly service","obligation_type":"service","interval_count":6,"interval_unit":"month","anchor":"completion"},
       {"name":"Annual boiler inspection (statutory)","obligation_type":"inspection","interval_count":1,"interval_unit":"year","anchor":"fixed"}]'),
    (6,  'HV',  'Chiller',      'CHL', 'Water-cooled Chiller',         6, 12, null,  'PHS', 'B', 'Polar Climate',          'WC-120',  1800000,
     '[{"name":"Quarterly service","obligation_type":"service","interval_count":3,"interval_unit":"month","anchor":"completion"},
       {"name":"Half-yearly condenser cleaning","obligation_type":"service","interval_count":6,"interval_unit":"month","anchor":"completion"}]'),
    (7,  'HV',  'AHU',          'AHU', 'Air Handling Unit',           12, 12, null,  'PHS', 'B', 'Polar Climate',          'AH-20',    350000,
     '[{"name":"Quarterly filter service","obligation_type":"service","interval_count":3,"interval_unit":"month","anchor":"completion"},
       {"name":"Half-yearly belt and bearing check","obligation_type":"service","interval_count":6,"interval_unit":"month","anchor":"completion"}]'),
    (8,  'MH',  'Forklift',     'FLT', 'Forklift 3T',                  9, 12, 'KCF', 'KCF', 'B', 'Konkan Forklifts',       'KF-30D',  1400000,
     '[{"name":"Quarterly service","obligation_type":"service","interval_count":3,"interval_unit":"month","anchor":"completion"},
       {"name":"Annual load test","obligation_type":"inspection","interval_count":1,"interval_unit":"year","anchor":"fixed"}]'),
    (9,  'MH',  'EOT crane',    'EOT', 'EOT Crane 10T',                6, 24, 'KCF', 'KCF', 'A', 'Konkan Cranes',          'KC-10',   2600000,
     '[{"name":"Half-yearly service","obligation_type":"service","interval_count":6,"interval_unit":"month","anchor":"completion"},
       {"name":"Annual statutory inspection","obligation_type":"inspection","interval_count":1,"interval_unit":"year","anchor":"fixed"}]'),
    (10, 'EL',  'Transformer',  'TRF', 'Transformer 1000 kVA',         4, 36, 'GPS', 'GPS', 'A', 'Godavari Power Systems', 'GT-1000', 2400000,
     '[{"name":"Annual oil test","obligation_type":"service","interval_count":1,"interval_unit":"year","anchor":"fixed"},
       {"name":"Half-yearly inspection","obligation_type":"inspection","interval_count":6,"interval_unit":"month","anchor":"completion"}]'),
    (11, 'EL',  'Panel',        'PNL', 'LT Distribution Panel',       15, 12, 'GPS', 'SGE', 'B', 'Godavari Power Systems', 'LT-800',   480000,
     '[{"name":"Half-yearly thermography","obligation_type":"inspection","interval_count":6,"interval_unit":"month","anchor":"completion"},
       {"name":"Annual maintenance","obligation_type":"service","interval_count":1,"interval_unit":"year","anchor":"completion"}]'),
    (12, 'QL',  'CMM',          'CMM', 'Coordinate Measuring Machine', 3, 12, null,  'PML', 'A', 'Metrix',                 'CM-564',  3200000,
     '[{"name":"Annual calibration","obligation_type":"calibration","interval_count":1,"interval_unit":"year","anchor":"fixed"},
       {"name":"Half-yearly service","obligation_type":"service","interval_count":6,"interval_unit":"month","anchor":"completion"}]'),
    (13, 'QL',  'Gauges',       'GAU', 'Gauge Set',                   25, 12, null,  'PML', 'C', 'Mitron',                 'GS-150',    25000,
     '[{"name":"Annual calibration","obligation_type":"calibration","interval_count":1,"interval_unit":"year","anchor":"fixed"}]'),
    (14, 'ITG', 'IT equipment', 'IT',  'Workstation',                 22, 36, null,  null,  'C', 'Infotech',               'WS-5',      85000,
     '[{"name":"Annual preventive maintenance","obligation_type":"service","interval_count":1,"interval_unit":"year","anchor":"completion"}]');

  insert into public.asset_category (tenant_id, parent_id, name, code, default_warranty_months, default_obligations,
                                     oem_vendor_ids, om_vendor_ids)
  select v_tid, g.id, l.name, l.code, l.months, l.obligations,
         array_remove(array[(select v.id from public.vendor v where v.tenant_id = v_tid and v.code = l.oem)], null),
         array_remove(array[(select v.id from public.vendor v where v.tenant_id = v_tid and v.code = l.om)], null)
  from demo_leaf l
  join public.asset_category g on g.tenant_id = v_tid and g.code = l.grp
  order by l.ord;

  -- Tenant statuses on two categories (and their children): Standby and Under repair come first.
  select array_agg(s.id order by array_position(array['active', 'standby', 'in_stock', 'under_repair', 'under_maintenance',
                                                      'inactive', 'disposed'], s.code))
  into v_set from public.asset_status s where s.tenant_id = v_tid;
  update public.asset_category set status_ids = v_set where tenant_id = v_tid and code in ('UT', 'MH');

  -- Assets: 150. i drives every choice, so two runs give the same counts.
  create temp table demo_asset (i int, id uuid, cov_id uuid, leaf text, grp text, months smallint, status text,
    purchase_date date, location_id uuid, skip_cover boolean) on commit drop;
  insert into demo_asset
  select x.i, gen_random_uuid(), gen_random_uuid(), x.code, x.grp, x.months, x.status, x.purchase_date, loc.id,
         x.i % 5 = 0  -- about 20% never covered
  from (
    select s.*,
           case when (s.i * 37) % 100 < 75 then 'active' when (s.i * 37) % 100 < 83 then 'under_maintenance'
                when (s.i * 37) % 100 < 91 then 'in_stock' when (s.i * 37) % 100 < 96 then 'inactive' else 'disposed' end as status,
           -- About 10 bought so their warranty ends within the 60-day window; the rest up to about 5 years ago.
           case when s.i % 15 = 1 then (v_today + 5 + s.i % 50 - make_interval(months => s.months))::date
                else v_today - (60 + (s.i * 53) % 1700) end as purchase_date,
           (array['PUN', 'NSK', 'AUR'])[s.k % 3 + 1] as plant
    from (select l.*, k, row_number() over (order by l.ord, k)::int as i from demo_leaf l cross join generate_series(1, l.n) k) s
  ) x
  join public.location p on p.tenant_id = v_tid and p.code = x.plant
  join lateral (
    select coalesce(
      (select c.id from public.location c where c.tenant_id = v_tid and c.parent_id = p.id
       and c.name = case when x.status = 'in_stock' then 'Stores'
                         when x.grp in ('UT', 'HV', 'EL') then 'Utility Bay'
                         when x.grp = 'QL' and x.plant = 'PUN' then 'Quality Lab'
                         when x.grp = 'ITG' then null
                         when x.plant = 'PUN' then 'Machine Shop'
                         when x.plant = 'NSK' then case when x.grp = 'MH' then 'Paint Shop' else 'Press Shop' end
                         else 'Assembly Line' end),
      p.id) as id
  ) loc on true;

  insert into public.asset (id, tenant_id, name, category_id, location_id, status, status_reason, status_changed_at,
                            criticality, serial_number, manufacturer, model, purchase_date, purchase_value, purchase_currency,
                            in_service_date, oem_vendor_id, om_vendor_id)
  select a.id, v_tid, l.asset_name || ' ' || lpad(row_number() over (partition by l.code order by a.i)::text, 2, '0'),
         c.id, a.location_id, a.status,
         case a.status when 'under_maintenance' then 'Breakdown, waiting for spares' when 'inactive' then 'Idle, no orders on this line'
                       when 'disposed' then 'Scrapped after condition survey' end,
         case when a.status <> 'active' then now() - make_interval(days => a.i % 20) end,
         l.crit, l.code || '-' || to_char(a.purchase_date, 'YYMM') || '-' || lpad(a.i::text, 4, '0'), l.maker, l.model,
         a.purchase_date, l.value * (1 + (a.i % 5) * 0.05), 'INR',
         case when a.status <> 'in_stock' then a.purchase_date + 7 end,
         (select v.id from public.vendor v where v.tenant_id = v_tid and v.code = l.oem),
         (select v.id from public.vendor v where v.tenant_id = v_tid and v.code = l.om)
  from demo_asset a
  join demo_leaf l on l.code = a.leaf
  join public.asset_category c on c.tenant_id = v_tid and c.code = a.leaf
  order by a.i;

  -- Coverage: a warranty per covered asset from the category term (OEM, else the supplier), then 4 AMCs.
  insert into public.coverage (id, tenant_id, coverage_type, vendor_id, reference, start_date, end_date)
  select a.cov_id, v_tid, 'warranty', v.id, 'WTY-' || x.tag, a.purchase_date,
         (a.purchase_date + make_interval(months => a.months))::date - 1
  from demo_asset a
  join public.asset x on x.tenant_id = v_tid and x.id = a.id
  join demo_leaf l on l.code = a.leaf
  join public.vendor v on v.tenant_id = v_tid and v.code = coalesce(l.oem, 'WIS')
  where not a.skip_cover;
  insert into public.coverage_asset (tenant_id, coverage_id, asset_id)
  select v_tid, a.cov_id, a.id from demo_asset a where not a.skip_cover;

  insert into public.coverage (tenant_id, coverage_type, vendor_id, reference, start_date, end_date, contract_value, contract_currency, notes)
  select v_tid, 'amc', v.id, m.ref, m.end_date - 364, m.end_date, m.value, 'INR', m.notes
  from (values ('PHS', 'AMC/PHS/HVAC',   v_today + 20,  540000, 'Comprehensive chiller AMC, all plants. Renewal quote awaited.'),
               ('SCB', 'AMC/SCB/UTIL',   v_today - 15,  380000, 'Compressor and boiler AMC. Lapsed, renewal under negotiation.'),
               ('GPS', 'AMC/GPS/POWER',  v_today + 200, 720000, 'DG, transformer and LT panel AMC.'),
               ('WIS', 'AMC/WIS/IT',     v_today + 300, 260000, 'IT hardware AMC, on-site next business day.')) m (vendor, ref, end_date, value, notes)
  join public.vendor v on v.tenant_id = v_tid and v.code = m.vendor;
  insert into public.coverage_asset (tenant_id, coverage_id, asset_id)
  select v_tid, c.id, a.id
  from demo_asset a
  join public.coverage c on c.tenant_id = v_tid and c.reference = case
    when a.leaf = 'CHL' then 'AMC/PHS/HVAC' when a.leaf in ('CMP', 'BLR') then 'AMC/SCB/UTIL'
    when a.leaf in ('DG', 'TRF', 'PNL') then 'AMC/GPS/POWER' when a.grp = 'ITG' then 'AMC/WIS/IT' end
  where not a.skip_cover;

  -- Obligations came from the category defaults (copy trigger). Set dates so about 10% are overdue, 10% due
  -- soon, the rest scheduled: next due N, last done N - step, first due N - step x records (so fixed anchors
  -- stay on their slots). The rule trigger recomputes next_due_date from these.
  create temp table demo_obl on commit drop as
  select o.id, o.asset_id, o.obligation_type, a.om_vendor_id, a.in_service_date,
         private.obligation_step(o.interval_count, o.interval_unit) as step,
         row_number() over (order by a.tag, o.name)::int as j
  from public.obligation o join public.asset a on a.tenant_id = o.tenant_id and a.id = o.asset_id
  where o.tenant_id = v_tid;
  alter table demo_obl add column n date, add column cnt int;
  update demo_obl set cnt = 2 + j % 2,
    n = case j % 10 when 0 then v_today - (3 + j % 40)
                    when 1 then v_today + 2 + j % 25
                    else v_today + 31 + (j * 17) % greatest((extract(epoch from step) / 86400)::int - 31, 1) end;
  update public.obligation o set first_due_date = (d.n - d.step * d.cnt)::date, last_done_date = (d.n - d.step)::date
  from demo_obl d where o.tenant_id = v_tid and o.id = d.id;

  -- Service history: complete_obligation's record write, 1 to 3 per obligation (the latest always, older ones
  -- within the last 12 months). A vendor or the demo technician did it; outcomes on inspections and calibrations.
  insert into public.service_record (tenant_id, obligation_id, asset_id, done_on, done_by_user_id, vendor_id, outcome,
                                     certificate_expiry, notes, cost_amount, cost_currency, advanced, prev_last_done_date)
  select v_tid, d.id, d.asset_id, r.done_on,
         case when v_tech is not null and (d.j + r.r) % 3 = 0 then v_tech end,
         case when d.obligation_type = 'calibration' then (select v.id from public.vendor v where v.tenant_id = v_tid and v.code = 'PML')
              when v_tech is null or (d.j + r.r) % 3 <> 0 then d.om_vendor_id end,
         case when d.obligation_type in ('inspection', 'calibration') then case when (d.j + r.r) % 9 = 0 then 'fail' else 'pass' end end,
         case when d.obligation_type in ('inspection', 'calibration') and (d.j + r.r) % 9 <> 0 then r.done_on + 365 end,
         case when d.obligation_type in ('inspection', 'calibration') and (d.j + r.r) % 9 = 0 then 'Failed: adjusted and retest booked'
              when (d.j + r.r) % 5 = 0 then 'Issues found: worn belt and seal replaced'
              else 'Done as per checklist' end,
         case when (d.j + r.r) % 3 = 0 then 2500 + (d.j * 137 % 20) * 500 end,
         case when (d.j + r.r) % 3 = 0 then 'INR' end,
         true,
         case when r.r < d.cnt then (d.n - d.step * (r.r + 1))::date end
  from demo_obl d
  cross join lateral (select g as r, (d.n - d.step * g)::date as done_on from generate_series(1, d.cnt) g) r
  where r.r = 1 or r.done_on >= greatest(v_today - 365, coalesce(d.in_service_date, v_today - 365));

  -- Stored states now, not after the 15-minute jobs.
  perform private.refresh_coverage_state(array(select id from public.asset where tenant_id = v_tid));
  perform private.refresh_obligation_state(array(select id from public.obligation where tenant_id = v_tid));

  raise notice 'Demo tenant % ready: % assets, % obligations, % service records',
    v_tid, (select count(*) from public.asset where tenant_id = v_tid),
    (select count(*) from public.obligation where tenant_id = v_tid),
    (select count(*) from public.service_record where tenant_id = v_tid);
end;
$$;
