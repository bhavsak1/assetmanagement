-- Story 2.2: my_permission shows only the caller's own grants in the active tenant;
-- field_domains needs category_config.view and returns only the entity's data domains.
begin;
select plan(9);

select ok(not has_table_privilege('anon', 'public.my_permission', 'select'), 'anon cannot read my_permission');
select ok(not has_function_privilege('anon', 'public.field_domains(text)', 'execute'), 'anon cannot call field_domains');

-- a1 gets category_config in tenant A only; a2 gets location_hierarchy in tenant B.
select tests.grant('00000000-0000-0000-0000-00000000000a', '00000000-0000-0000-0000-0000000000a1', 'category_config', '{view,manage}');
select tests.grant('00000000-0000-0000-0000-00000000000b', '00000000-0000-0000-0000-0000000000a1', 'asset_core', '{view}');
select tests.grant('00000000-0000-0000-0000-00000000000b', '00000000-0000-0000-0000-0000000000a2', 'location_hierarchy', '{view}');

select tests.act_as('00000000-0000-0000-0000-0000000000a1', '00000000-0000-0000-0000-00000000000a');
select results_eq(
  'select domain, operation from public.my_permission order by 1, 2',
  $$values ('category_config', 'manage'), ('category_config', 'view')$$,
  'own grants in the active tenant only'
);
select results_eq(
  'select code from public.field_domains(''asset'')',
  $$values ('asset_core'), ('asset_financials')$$,
  'asset data domains, no action domain'
);
select results_eq(
  'select code from public.field_domains(''vendor'')',
  $$values ('vendor_core'), ('vendor_tax_ids')$$,
  'domains follow the entity'
);

-- Same user, other tenant: that tenant's grants, and no category_config there.
reset role;
select tests.act_as('00000000-0000-0000-0000-0000000000a1', '00000000-0000-0000-0000-00000000000b');
select results_eq('select domain, operation from public.my_permission', $$values ('asset_core', 'view')$$, 'switching tenant switches grants');
select is_empty('select * from public.field_domains(''asset'')', 'no category_config.view, no domains');

-- Other user in tenant B never sees a1's rows.
reset role;
select tests.act_as('00000000-0000-0000-0000-0000000000a2', '00000000-0000-0000-0000-00000000000b');
select results_eq('select domain, operation from public.my_permission', $$values ('location_hierarchy', 'view')$$, 'never another user''s grants');

-- Expired grant drops out, as in has_permission().
reset role;
update private.user_effective_permission set effective_to = now() - interval '1 day'
where user_id = '00000000-0000-0000-0000-0000000000a2';
select tests.act_as('00000000-0000-0000-0000-0000000000a2', '00000000-0000-0000-0000-00000000000b');
select is_empty('select * from public.my_permission', 'expired grant not shown');

select * from finish();
rollback;
