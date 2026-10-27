-- Narrow, session-authenticated Admin Master company creation.
-- Apply only in an explicitly authorized isolated environment. This migration
-- does not create tenant memberships or grant operational access to a company.

begin;

do $preflight$
begin
  if current_user <> 'postgres' then
    raise exception 'Apply this migration as postgres';
  end if;
  if pg_catalog.to_regclass('public.companies') is null
    or pg_catalog.to_regclass('app_private.master_admins') is null
    or pg_catalog.to_regclass('app_private.provisioning_audit_events') is null
    or pg_catalog.to_regprocedure('public.is_current_user_master()') is null
    or pg_catalog.to_regprocedure('app_private.write_provisioning_audit(text,uuid,uuid,uuid,jsonb)') is null then
    raise exception 'Required company, Master authorization, or audit dependency is missing';
  end if;
  if pg_catalog.to_regprocedure('public.master_create_company(uuid,text)') is not null
    or pg_catalog.to_regclass('app_private.master_company_creation_requests') is not null then
    raise exception 'Master company creation objects already exist; inspect before proceeding';
  end if;
end;
$preflight$;

create table app_private.master_company_creation_requests (
  requested_by_user_id uuid not null references auth.users(id) on delete restrict,
  request_id uuid not null,
  legal_name text not null check (pg_catalog.length(pg_catalog.btrim(legal_name)) between 1 and 200),
  company_id uuid not null references public.companies(id) on delete restrict,
  created_at timestamptz not null default pg_catalog.clock_timestamp(),
  primary key (requested_by_user_id, request_id)
);

alter table app_private.master_company_creation_requests enable row level security;
alter table app_private.master_company_creation_requests force row level security;
revoke all on table app_private.master_company_creation_requests
  from public, anon, authenticated, service_role;

create function public.master_create_company(p_request_id uuid, p_legal_name text)
returns uuid
language plpgsql
volatile
security definer
set search_path = ''
set row_security = off
as $create_company$
declare
  actor_id uuid;
  normalized_name text;
  previous_request app_private.master_company_creation_requests%rowtype;
  new_company_id uuid;
begin
  if coalesce(auth.role(), '') <> 'authenticated' then
    raise exception 'Authenticated session required' using errcode = '42501';
  end if;

  actor_id := auth.uid();
  if actor_id is null then
    raise exception 'Authenticated user identity required' using errcode = '42501';
  end if;
  if public.is_current_user_master() is distinct from true then
    raise exception 'Active Admin Master authorization required' using errcode = '42501';
  end if;
  if p_request_id is null or p_legal_name is null then
    raise exception 'Request key and company legal name are required' using errcode = '22023';
  end if;

  normalized_name := pg_catalog.btrim(p_legal_name);
  if pg_catalog.length(normalized_name) not between 1 and 200 then
    raise exception 'Company legal name must contain between 1 and 200 characters'
      using errcode = '22023';
  end if;

  -- Serialize retries of the same actor/request pair. The lock key is not an
  -- authorization input; identity always comes from the verified JWT claims.
  perform pg_catalog.pg_advisory_xact_lock(
    pg_catalog.hashtextextended(actor_id::text || ':' || p_request_id::text, 0)
  );

  select request_row.* into previous_request
  from app_private.master_company_creation_requests as request_row
  where request_row.requested_by_user_id = actor_id
    and request_row.request_id = p_request_id;

  if found then
    if previous_request.legal_name is distinct from normalized_name then
      raise exception 'Request key was already used for a different company name'
        using errcode = '22023';
    end if;
    return previous_request.company_id;
  end if;

  insert into public.companies (legal_name)
  values (normalized_name)
  returning id into new_company_id;

  insert into app_private.master_company_creation_requests (
    requested_by_user_id, request_id, legal_name, company_id
  ) values (actor_id, p_request_id, normalized_name, new_company_id);

  perform app_private.write_provisioning_audit(
    'company.provisioned',
    new_company_id,
    null,
    actor_id,
    pg_catalog.jsonb_build_object(
      'company_id', new_company_id,
      'creation_request_id', p_request_id,
      'provisioning_path', 'admin_master_session'
    )
  );

  return new_company_id;
end;
$create_company$;

alter function public.master_create_company(uuid, text) owner to postgres;
revoke all on function public.master_create_company(uuid, text)
  from public, anon, authenticated, service_role;
grant usage on schema public to authenticated;
grant execute on function public.master_create_company(uuid, text) to authenticated;

do $verify_acl$
declare
  function_oid oid := pg_catalog.to_regprocedure('public.master_create_company(uuid,text)');
  function_owner_oid oid;
  authenticated_oid oid;
  request_table_oid oid := pg_catalog.to_regclass('app_private.master_company_creation_requests');
  request_table_owner_oid oid;
begin
  select procedure_row.proowner into function_owner_oid
  from pg_catalog.pg_proc as procedure_row
  where procedure_row.oid = function_oid;

  select role_row.oid into authenticated_oid
  from pg_catalog.pg_roles as role_row
  where role_row.rolname = 'authenticated';

  select relation_row.relowner into request_table_owner_oid
  from pg_catalog.pg_class as relation_row
  where relation_row.oid = request_table_oid;

  if function_owner_oid is distinct from (select role_row.oid from pg_catalog.pg_roles as role_row where role_row.rolname = 'postgres')
    or authenticated_oid is null
    or not exists (
      select 1
      from pg_catalog.pg_proc as procedure_row
      cross join lateral pg_catalog.aclexplode(
        coalesce(procedure_row.proacl, pg_catalog.acldefault('f', procedure_row.proowner))
      ) as function_acl
      where procedure_row.oid = function_oid
        and function_acl.grantee = authenticated_oid
        and function_acl.grantor = function_owner_oid
        and function_acl.privilege_type = 'EXECUTE'
        and not function_acl.is_grantable
    ) then
    raise exception 'Master company RPC owner or authenticated EXECUTE grant is invalid';
  end if;

  if exists (
    select 1
    from pg_catalog.pg_proc as procedure_row
    cross join lateral pg_catalog.aclexplode(
      coalesce(procedure_row.proacl, pg_catalog.acldefault('f', procedure_row.proowner))
    ) as function_acl
    where procedure_row.oid = function_oid
      and (
        function_acl.grantee not in (function_owner_oid, authenticated_oid)
        or function_acl.grantor <> function_owner_oid
        or function_acl.privilege_type <> 'EXECUTE'
        or function_acl.is_grantable
      )
  ) then
    raise exception 'Master company RPC has an unexpected explicit EXECUTE grant';
  end if;

  if request_table_owner_oid is distinct from function_owner_oid
    or not exists (
      select 1
      from pg_catalog.pg_class as relation_row
      where relation_row.oid = request_table_oid
        and relation_row.relrowsecurity
        and relation_row.relforcerowsecurity
    )
    or exists (
      select 1
      from pg_catalog.pg_class as relation_row
      cross join lateral pg_catalog.aclexplode(
        coalesce(relation_row.relacl, pg_catalog.acldefault('r', relation_row.relowner))
      ) as table_acl
      where relation_row.oid = request_table_oid
        and (table_acl.grantee <> request_table_owner_oid or table_acl.grantor <> request_table_owner_oid)
    ) then
    raise exception 'Idempotency state ownership, RLS, or table ACL is invalid';
  end if;
end;
$verify_acl$;

comment on function public.master_create_company(uuid, text) is
  'Creates one company for the authenticated, persistently authorized Admin Master. Accepts only an idempotency key and legal name; no membership or tenant data access is granted.';

commit;
