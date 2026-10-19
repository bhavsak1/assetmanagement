begin;
select plan(3);

select has_schema('private');
select schema_privs_are('private', 'anon', array[]::text[], 'anon has no access to private');
-- Story 1.3: usage only, for the permission helpers. Execute is granted per function.
select schema_privs_are('private', 'authenticated', array['USAGE'], 'authenticated has usage only on private');

select * from finish();
rollback;
