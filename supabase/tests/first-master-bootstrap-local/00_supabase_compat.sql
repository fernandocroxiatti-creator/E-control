-- Local-only PostgreSQL compatibility harness for MASTER-05E.
-- Run only in a newly created disposable database on a dedicated test cluster.
-- The three Supabase-like roles are cluster-wide and may be reused across
-- disposable databases only after their attributes and memberships validate.
begin;

do $roles$
declare
  role_spec record;
  role_oid oid;
begin
  for role_spec in
    select *
    from (values
      ('anon'::text, false),
      ('authenticated'::text, false),
      ('service_role'::text, true)
    ) as expected_roles(role_name, expected_bypassrls)
  loop
    select role_row.oid
      into role_oid
    from pg_catalog.pg_roles as role_row
    where role_row.rolname = role_spec.role_name;

    if role_oid is null then
      if role_spec.expected_bypassrls then
        execute pg_catalog.format(
          'create role %I nologin noinherit bypassrls',
          role_spec.role_name
        );
      else
        execute pg_catalog.format(
          'create role %I nologin noinherit nobypassrls',
          role_spec.role_name
        );
      end if;

      select role_row.oid
        into role_oid
      from pg_catalog.pg_roles as role_row
      where role_row.rolname = role_spec.role_name;
    end if;

    if exists (
      select 1
      from pg_catalog.pg_roles as role_row
      where role_row.oid = role_oid
        and (
          role_row.rolsuper
          or role_row.rolinherit
          or role_row.rolcreaterole
          or role_row.rolcreatedb
          or role_row.rolcanlogin
          or role_row.rolreplication
          or role_row.rolbypassrls <> role_spec.expected_bypassrls
          or role_row.rolconnlimit <> -1
          or role_row.rolvaliduntil is not null
          or (
            role_row.rolconfig is not null
            and pg_catalog.cardinality(role_row.rolconfig) <> 0
          )
        )
    ) then
      raise exception 'Supabase test role % has unexpected attributes',
        role_spec.role_name;
    end if;

    if exists (
      select 1
      from pg_catalog.pg_auth_members as membership
      where membership.roleid = role_oid
         or membership.member = role_oid
    ) then
      raise exception 'Supabase test role % has unexpected role memberships',
        role_spec.role_name;
    end if;

    if exists (
      select 1
      from pg_catalog.pg_database as database_row
      cross join lateral pg_catalog.aclexplode(database_row.datacl) as acl_entry
      where database_row.datname = pg_catalog.current_database()
        and acl_entry.grantee = role_oid
    ) then
      raise exception 'Supabase test role % has unexpected direct database privileges',
        role_spec.role_name;
    end if;

    if exists (
      select 1
      from pg_catalog.pg_namespace as schema_row
      cross join lateral pg_catalog.aclexplode(schema_row.nspacl) as acl_entry
      where schema_row.nspname = 'public'
        and acl_entry.grantee = role_oid
    ) then
      raise exception 'Supabase test role % has unexpected direct public-schema privileges',
        role_spec.role_name;
    end if;

    if exists (
      select 1
      from pg_catalog.pg_default_acl as default_acl
      cross join lateral pg_catalog.aclexplode(default_acl.defaclacl) as acl_entry
      where acl_entry.grantee = role_oid
    ) then
      raise exception 'Supabase test role % has unexpected default privileges',
        role_spec.role_name;
    end if;

    if pg_catalog.has_database_privilege(
         role_oid, pg_catalog.current_database(), 'CREATE'
       )
       or pg_catalog.has_schema_privilege(role_oid, 'public', 'CREATE') then
      raise exception 'Supabase test role % has unexpected object-creation privileges',
        role_spec.role_name;
    end if;
  end loop;

  if pg_catalog.to_regnamespace('auth') is not null then
    raise exception 'The selected test database already has an auth schema; stop and inspect it';
  end if;
end;
$roles$;

create extension if not exists pgcrypto;

create schema auth;
create table auth.users (
  id uuid primary key
);

-- These stubs emulate only the claim lookups needed by the migrations.
-- They do not validate Supabase Auth signatures, JWTs, or Data API behavior.
create function auth.uid()
returns uuid
language sql
stable
set search_path = ''
as $$
  select nullif(pg_catalog.current_setting('request.jwt.claim.sub', true), '')::pg_catalog.uuid
$$;

create function auth.role()
returns text
language sql
stable
set search_path = ''
as $$
  select nullif(pg_catalog.current_setting('request.jwt.claim.role', true), '')
$$;

grant usage on schema auth to anon, authenticated, service_role;
revoke all on function auth.uid() from public;
revoke all on function auth.role() from public;
grant execute on function auth.uid() to anon, authenticated, service_role;
grant execute on function auth.role() to anon, authenticated, service_role;

commit;
