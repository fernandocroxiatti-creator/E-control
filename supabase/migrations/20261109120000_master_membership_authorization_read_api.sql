-- Master-only, tenant-bounded read view of membership role assignments.
-- This migration creates no memberships, roles, grants, invitations or approvals.
begin;

do $preflight$
begin
  if current_user <> 'postgres' then
    raise exception 'Apply this migration as postgres';
  end if;
  if pg_catalog.to_regclass('public.company_memberships') is null
    or pg_catalog.to_regclass('public.membership_role_assignments') is null
    or pg_catalog.to_regclass('public.access_role_definitions') is null
    or pg_catalog.to_regclass('public.role_permission_grants') is null
    or pg_catalog.to_regclass('public.user_profiles') is null
    or pg_catalog.to_regprocedure('public.is_current_user_master()') is null then
    raise exception 'Admin Master membership authorization foundations are required';
  end if;
  if pg_catalog.to_regprocedure('public.master_admin_list_membership_authorizations(uuid)') is not null then
    raise exception 'Master membership authorization read API already exists; inspect before proceeding';
  end if;
  if exists (
    select 1 from (values
      ('public.company_memberships'::pg_catalog.regclass),
      ('public.membership_role_assignments'::pg_catalog.regclass),
      ('public.role_permission_grants'::pg_catalog.regclass)
    ) as protected(relation_oid)
    join pg_catalog.pg_class relation_row on relation_row.oid = protected.relation_oid
    where not relation_row.relrowsecurity or not relation_row.relforcerowsecurity
  ) then
    raise exception 'Authorization tables must retain enabled and forced RLS';
  end if;
end;
$preflight$;

create function public.master_admin_list_membership_authorizations(p_tenant_id uuid)
returns table(
  display_name text,
  status text,
  branch_access_mode text,
  created_at timestamptz,
  roles jsonb
)
language plpgsql stable security definer
set search_path = '' set row_security = off
as $function$
begin
  if coalesce(auth.role(), '') <> 'authenticated' or auth.uid() is null
    or public.is_current_user_master() is distinct from true then
    raise exception 'Active Admin Master authorization required' using errcode = '42501';
  end if;
  if p_tenant_id is null or not exists (select 1 from public.companies where id = p_tenant_id) then
    raise exception 'Company is required' using errcode = '22023';
  end if;
  return query
  select profile.display_name,
    membership.status,
    membership.branch_access_mode,
    membership.created_at,
    coalesce(jsonb_agg(jsonb_build_object(
      'role_key', assignment.role_key,
      'display_name', role_definition.display_name,
      'scope', role_definition.scope,
      'approval_state', role_definition.approval_state,
      'branch_name', branch.name,
      'granted_permission_keys', coalesce(grant_keys.permission_keys, '[]'::jsonb)
    ) order by role_definition.display_name, assignment.role_key) filter (where assignment.membership_id is not null), '[]'::jsonb)
  from public.company_memberships membership
  left join public.user_profiles profile on profile.user_id = membership.user_id
  left join public.membership_role_assignments assignment
    on assignment.tenant_id = membership.tenant_id and assignment.membership_id = membership.id
  left join public.access_role_definitions role_definition on role_definition.role_key = assignment.role_key
  left join public.branches branch on branch.id = assignment.branch_id and branch.tenant_id = assignment.tenant_id
  left join lateral (
    select coalesce(jsonb_agg(grant_row.permission_key order by grant_row.permission_key), '[]'::jsonb) as permission_keys
    from public.role_permission_grants grant_row
    where grant_row.role_key = assignment.role_key
  ) grant_keys on true
  where membership.tenant_id = p_tenant_id
  group by membership.id, profile.display_name, membership.status, membership.branch_access_mode, membership.created_at
  order by membership.created_at desc, membership.id;
end;
$function$;

alter function public.master_admin_list_membership_authorizations(uuid) owner to postgres;
revoke all on function public.master_admin_list_membership_authorizations(uuid) from public, anon, authenticated, service_role;
grant execute on function public.master_admin_list_membership_authorizations(uuid) to authenticated;

do $verify$
declare function_oid oid := pg_catalog.to_regprocedure('public.master_admin_list_membership_authorizations(uuid)');
begin
  if function_oid is null or not exists (
    select 1 from pg_catalog.pg_proc routine
    join pg_catalog.pg_roles owner_role on owner_role.oid = routine.proowner
    where routine.oid = function_oid and owner_role.rolname = 'postgres'
      and routine.prosecdef
      and 'search_path=""' = any(routine.proconfig)
      and 'row_security=off' = any(routine.proconfig)
      and pg_catalog.has_function_privilege('authenticated', function_oid, 'EXECUTE')
      and not pg_catalog.has_function_privilege('anon', function_oid, 'EXECUTE')
      and not pg_catalog.has_function_privilege('service_role', function_oid, 'EXECUTE')
      and not exists (select 1 from pg_catalog.aclexplode(coalesce(routine.proacl, pg_catalog.acldefault('f', routine.proowner))) acl where acl.grantee = 0 and acl.privilege_type = 'EXECUTE')
  ) then
    raise exception 'Master membership authorization read API security contract failed';
  end if;
end;
$verify$;

comment on function public.master_admin_list_membership_authorizations(uuid) is
  'Master-only sanitized membership role/grant view. Excludes Auth IDs, e-mails, credentials, invitation tokens and operational records.';

commit;
