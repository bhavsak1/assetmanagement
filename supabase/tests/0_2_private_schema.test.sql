begin;
select plan(3);

select has_schema('private');
select schema_privs_are('private', 'anon', array[]::text[], 'anon has no access to private');
select schema_privs_are('private', 'authenticated', array[]::text[], 'authenticated has no access to private yet');

select * from finish();
rollback;
