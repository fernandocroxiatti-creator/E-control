-- Admin Master V1: narrow read-only control-plane API.
-- Local candidate only. Do not apply remotely without separate approval.
begin;

do $preflight$
begin
  if current_user <> 'postgres' then
    raise exception 'Apply this migration as postgres';
  end if;
  if pg_catalog.to_regclass('public.companies') is null
    or pg_catalog.to_regclass('public.branches') is null
    or pg_catalog.to_regclass('public.company_memberships') is null
    or pg_catalog.to_regclass('public.user_profiles') is null
    or pg_catalog.to_regclass('public.access_role_definitions') is null
    or pg_catalog.to_regclass('public.permission_definitions') is null
    or pg_catalog.to_regclass('public.role_permission_grants') is null
    or pg_catalog.to_regclass('app_private.master_admin_audit_events') is null
    or pg_catalog.to_regclass('app_private.provisioning_audit_events') is null
    or pg_catalog.to_regprocedure('public.is_current_user_master()') is null then
    raise exception 'Required Admin Master read dependencies are missing';
  end if;
  if pg_catalog.to_regprocedure('public.master_admin_summary()') is not null
    or pg_catalog.to_regprocedure('public.master_admin_list_companies(text,text,integer,integer)') is not null
    or pg_catalog.to_regprocedure('public.master_admin_get_company(uuid)') is not null
    or pg_catalog.to_regprocedure('public.master_admin_list_branches(uuid)') is not null
    or pg_catalog.to_regprocedure('public.master_admin_list_memberships(uuid)') is not null
    or pg_catalog.to_regprocedure('public.master_admin_list_access_catalog()') is not null
    or pg_catalog.to_regprocedure('public.master_admin_list_audit(integer)') is not null then
    raise exception 'Admin Master read API already exists; inspect before applying';
  end if;
  if exists (
    select 1 from (values
      ('public.companies'::pg_catalog.regclass),
      ('public.branches'::pg_catalog.regclass),
      ('public.company_memberships'::pg_catalog.regclass),
      ('public.user_profiles'::pg_catalog.regclass),
      ('public.access_role_definitions'::pg_catalog.regclass),
      ('public.permission_definitions'::pg_catalog.regclass),
      ('public.role_permission_grants'::pg_catalog.regclass)
    ) as protected_tables(relation_oid)
    join pg_catalog.pg_class as relation_row on relation_row.oid = protected_tables.relation_oid
    where not relation_row.relrowsecurity or not relation_row.relforcerowsecurity
  ) then
    raise exception 'Control-plane source tables must retain enabled and forced RLS';
  end if;
end;
$preflight$;

create function public.master_admin_summary()
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
set row_security = off
as $function$
declare result jsonb;
begin
  if coalesce(auth.role(), '') <> 'authenticated' or auth.uid() is null
    or public.is_current_user_master() is distinct from true then
    raise exception 'Active Admin Master authorization required' using errcode = '42501';
  end if;
  select pg_catalog.jsonb_build_object(
    'companies_total', (select pg_catalog.count(*) from public.companies),
    'companies_active', (select pg_catalog.count(*) from public.companies where status = 'active'),
    'companies_suspended', (select pg_catalog.count(*) from public.companies where status = 'suspended'),
    'companies_closed', (select pg_catalog.count(*) from public.companies where status = 'closed'),
    'branches_total', (select pg_catalog.count(*) from public.branches),
    'memberships_active', (select pg_catalog.count(*) from public.company_memberships where status = 'active'),
    'master_events_recent', coalesce((
      select pg_catalog.jsonb_agg(pg_catalog.jsonb_build_object('event_key', event_row.event_key, 'created_at', event_row.created_at)
        order by event_row.created_at desc)
      from (select event_key, created_at from app_private.master_admin_audit_events order by created_at desc limit 10) as event_row
    ), '[]'::jsonb),
    'provisioning_events_recent', coalesce((
      select pg_catalog.jsonb_agg(pg_catalog.jsonb_build_object('event_key', event_row.event_key, 'created_at', event_row.created_at)
        order by event_row.created_at desc)
      from (select event_key, created_at from app_private.provisioning_audit_events order by created_at desc limit 10) as event_row
    ), '[]'::jsonb)
  ) into result;
  return result;
end;
$function$;

create function public.master_admin_list_companies(
  p_search text default null,
  p_status text default null,
  p_limit integer default 50,
  p_offset integer default 0
)
returns table(company_id uuid, legal_name text, status text, created_at timestamptz,
  branch_count bigint, active_membership_count bigint)
language plpgsql
stable
security definer
set search_path = ''
set row_security = off
as $function$
begin
  if coalesce(auth.role(), '') <> 'authenticated' or auth.uid() is null
    or public.is_current_user_master() is distinct from true then
    raise exception 'Active Admin Master authorization required' using errcode = '42501';
  end if;
  if p_search is not null and pg_catalog.length(p_search) > 100 then
    raise exception 'Search text is too long' using errcode = '22023';
  end if;
  if p_status is not null and p_status not in ('active', 'suspended', 'closed') then
    raise exception 'Invalid company status filter' using errcode = '22023';
  end if;
  if p_limit is null or p_limit < 1 or p_limit > 100 or p_offset is null or p_offset < 0 or p_offset > 100000 then
    raise exception 'Invalid pagination values' using errcode = '22023';
  end if;
  return query
    select company.id, company.legal_name, company.status, company.created_at,
      (select pg_catalog.count(*) from public.branches as branch where branch.tenant_id = company.id),
      (select pg_catalog.count(*) from public.company_memberships as membership
        where membership.tenant_id = company.id and membership.status = 'active')
    from public.companies as company
    where (p_status is null or company.status = p_status)
      and (p_search is null or company.legal_name ilike '%' || pg_catalog.replace(pg_catalog.replace(p_search, '%', '\%'), '_', '\_') || '%')
    order by company.created_at desc, company.id
    limit p_limit offset p_offset;
end;
$function$;

create function public.master_admin_get_company(p_company_id uuid)
returns table(company_id uuid, legal_name text, status text, created_at timestamptz,
  branch_count bigint, active_membership_count bigint)
language plpgsql
stable
security definer
set search_path = ''
set row_security = off
as $function$
begin
  if coalesce(auth.role(), '') <> 'authenticated' or auth.uid() is null
    or public.is_current_user_master() is distinct from true then
    raise exception 'Active Admin Master authorization required' using errcode = '42501';
  end if;
  if p_company_id is null then raise exception 'Company is required' using errcode = '22023'; end if;
  return query select company.id, company.legal_name, company.status, company.created_at,
      (select pg_catalog.count(*) from public.branches as branch where branch.tenant_id = company.id),
      (select pg_catalog.count(*) from public.company_memberships as membership
        where membership.tenant_id = company.id and membership.status = 'active')
    from public.companies as company where company.id = p_company_id;
end;
$function$;

create function public.master_admin_list_branches(p_tenant_id uuid)
returns table(branch_id uuid, tenant_id uuid, code text, name text, status text, created_at timestamptz)
language plpgsql
stable
security definer
set search_path = ''
set row_security = off
as $function$
begin
  if coalesce(auth.role(), '') <> 'authenticated' or auth.uid() is null
    or public.is_current_user_master() is distinct from true then
    raise exception 'Active Admin Master authorization required' using errcode = '42501';
  end if;
  if p_tenant_id is null then raise exception 'Company is required' using errcode = '22023'; end if;
  return query select branch.id, branch.tenant_id, branch.code, branch.name, branch.status, branch.created_at
    from public.branches as branch where branch.tenant_id = p_tenant_id
    order by branch.code, branch.id;
end;
$function$;

create function public.master_admin_list_memberships(p_tenant_id uuid)
returns table(display_name text, status text, branch_access_mode text, created_at timestamptz)
language plpgsql
stable
security definer
set search_path = ''
set row_security = off
as $function$
begin
  if coalesce(auth.role(), '') <> 'authenticated' or auth.uid() is null
    or public.is_current_user_master() is distinct from true then
    raise exception 'Active Admin Master authorization required' using errcode = '42501';
  end if;
  if p_tenant_id is null then raise exception 'Company is required' using errcode = '22023'; end if;
  return query select profile.display_name, membership.status,
      membership.branch_access_mode, membership.created_at
    from public.company_memberships as membership
    left join public.user_profiles as profile on profile.user_id = membership.user_id
    where membership.tenant_id = p_tenant_id
    order by membership.created_at desc, membership.id;
end;
$function$;

create function public.master_admin_list_access_catalog()
returns table(item_type text, item_key text, display_name text, scope text, approval_state text, related_permission_count bigint)
language plpgsql
stable
security definer
set search_path = ''
set row_security = off
as $function$
begin
  if coalesce(auth.role(), '') <> 'authenticated' or auth.uid() is null
    or public.is_current_user_master() is distinct from true then
    raise exception 'Active Admin Master authorization required' using errcode = '42501';
  end if;
  return query
    select 'role'::text, role_row.role_key, role_row.display_name, role_row.scope,
      role_row.approval_state,
      (select pg_catalog.count(*) from public.role_permission_grants as grant_row where grant_row.role_key = role_row.role_key)
    from public.access_role_definitions as role_row
    union all
    select 'permission'::text, permission_row.permission_key, permission_row.description, null::text,
      permission_row.approval_state, 0::bigint
    from public.permission_definitions as permission_row
    union all
    select 'role_permission'::text, grant_row.role_key || ':' || grant_row.permission_key,
      permission_row.description, role_row.scope,
      role_row.approval_state || ' / ' || permission_row.approval_state, 0::bigint
    from public.role_permission_grants as grant_row
    join public.access_role_definitions as role_row on role_row.role_key = grant_row.role_key
    join public.permission_definitions as permission_row on permission_row.permission_key = grant_row.permission_key
    order by 1, 2;
end;
$function$;

create function public.master_admin_list_audit(p_limit integer default 50)
returns table(event_source text, event_key text, created_at timestamptz)
language plpgsql
stable
security definer
set search_path = ''
set row_security = off
as $function$
begin
  if coalesce(auth.role(), '') <> 'authenticated' or auth.uid() is null
    or public.is_current_user_master() is distinct from true then
    raise exception 'Active Admin Master authorization required' using errcode = '42501';
  end if;
  if p_limit is null or p_limit < 1 or p_limit > 100 then
    raise exception 'Invalid audit page size' using errcode = '22023';
  end if;
  return query
    select audit_rows.event_source, audit_rows.event_key, audit_rows.created_at
    from (
      select 'master'::text as event_source, master_event.event_key, master_event.created_at
        from app_private.master_admin_audit_events as master_event
      union all
      select 'provisioning'::text, provisioning_event.event_key, provisioning_event.created_at
        from app_private.provisioning_audit_events as provisioning_event
    ) as audit_rows
    order by audit_rows.created_at desc
    limit p_limit;
end;
$function$;

alter function public.master_admin_summary() owner to postgres;
alter function public.master_admin_list_companies(text,text,integer,integer) owner to postgres;
alter function public.master_admin_get_company(uuid) owner to postgres;
alter function public.master_admin_list_branches(uuid) owner to postgres;
alter function public.master_admin_list_memberships(uuid) owner to postgres;
alter function public.master_admin_list_access_catalog() owner to postgres;
alter function public.master_admin_list_audit(integer) owner to postgres;

revoke all on function public.master_admin_summary() from public, anon, authenticated, service_role;
revoke all on function public.master_admin_list_companies(text,text,integer,integer) from public, anon, authenticated, service_role;
revoke all on function public.master_admin_get_company(uuid) from public, anon, authenticated, service_role;
revoke all on function public.master_admin_list_branches(uuid) from public, anon, authenticated, service_role;
revoke all on function public.master_admin_list_memberships(uuid) from public, anon, authenticated, service_role;
revoke all on function public.master_admin_list_access_catalog() from public, anon, authenticated, service_role;
revoke all on function public.master_admin_list_audit(integer) from public, anon, authenticated, service_role;

grant execute on function public.master_admin_summary() to authenticated;
grant execute on function public.master_admin_list_companies(text,text,integer,integer) to authenticated;
grant execute on function public.master_admin_get_company(uuid) to authenticated;
grant execute on function public.master_admin_list_branches(uuid) to authenticated;
grant execute on function public.master_admin_list_memberships(uuid) to authenticated;
grant execute on function public.master_admin_list_access_catalog() to authenticated;
grant execute on function public.master_admin_list_audit(integer) to authenticated;

do $verify$
declare
  function_oid oid;
  owner_oid oid;
  authenticated_oid oid;
begin
  select oid into owner_oid from pg_catalog.pg_roles where rolname = 'postgres';
  select oid into authenticated_oid from pg_catalog.pg_roles where rolname = 'authenticated';
  if owner_oid is null or authenticated_oid is null then
    raise exception 'Required database roles are missing';
  end if;
  foreach function_oid in array array[
    pg_catalog.to_regprocedure('public.master_admin_summary()'),
    pg_catalog.to_regprocedure('public.master_admin_list_companies(text,text,integer,integer)'),
    pg_catalog.to_regprocedure('public.master_admin_get_company(uuid)'),
    pg_catalog.to_regprocedure('public.master_admin_list_branches(uuid)'),
    pg_catalog.to_regprocedure('public.master_admin_list_memberships(uuid)'),
    pg_catalog.to_regprocedure('public.master_admin_list_access_catalog()'),
    pg_catalog.to_regprocedure('public.master_admin_list_audit(integer)')
  ] loop
    if function_oid is null or not pg_catalog.has_function_privilege('authenticated', function_oid, 'EXECUTE')
      or pg_catalog.has_function_privilege('anon', function_oid, 'EXECUTE')
      or pg_catalog.has_function_privilege('service_role', function_oid, 'EXECUTE') then
      raise exception 'Admin Master read RPC ACL is broader or narrower than expected';
    end if;
    if not exists (select 1 from pg_catalog.pg_proc p where p.oid = function_oid
      and p.proowner = owner_oid
      and p.prosecdef and 'search_path=""' = any(p.proconfig) and 'row_security=off' = any(p.proconfig)) then
      raise exception 'Admin Master read RPC security configuration is invalid';
    end if;
    if exists (
      select 1 from pg_catalog.pg_proc p
      cross join lateral pg_catalog.aclexplode(
        coalesce(p.proacl, pg_catalog.acldefault('f', p.proowner))
      ) as acl
      where p.oid = function_oid
        and (acl.grantee not in (owner_oid, authenticated_oid)
          or acl.grantor <> owner_oid
          or acl.privilege_type <> 'EXECUTE'
          or acl.is_grantable)
    ) or not exists (
      select 1 from pg_catalog.pg_proc p
      cross join lateral pg_catalog.aclexplode(
        coalesce(p.proacl, pg_catalog.acldefault('f', p.proowner))
      ) as acl
      where p.oid = function_oid
        and acl.grantee = authenticated_oid
        and acl.grantor = owner_oid
        and acl.privilege_type = 'EXECUTE'
        and not acl.is_grantable
    ) then
      raise exception 'Admin Master read RPC has an unexpected explicit ACL';
    end if;
  end loop;
end;
$verify$;

comment on function public.master_admin_summary() is 'Read-only Admin Master summary; authenticated session and active Master authorization required.';
comment on function public.master_admin_list_companies(text,text,integer,integer) is 'Read-only Admin Master company metadata and aggregates; no tenant operational records.';
comment on function public.master_admin_get_company(uuid) is 'Read-only Admin Master company metadata and aggregates; no tenant operational records.';
comment on function public.master_admin_list_branches(uuid) is 'Read-only Admin Master branch metadata for one company; no operational records.';
comment on function public.master_admin_list_memberships(uuid) is 'Read-only Admin Master membership metadata; excludes email, credentials and Auth tokens.';
comment on function public.master_admin_list_access_catalog() is 'Read-only role, permission and role-permission definitions; catalog state is not an entitlement.';
comment on function public.master_admin_list_audit(integer) is 'Read-only sanitized audit index; excludes private details and credentials.';

commit;
