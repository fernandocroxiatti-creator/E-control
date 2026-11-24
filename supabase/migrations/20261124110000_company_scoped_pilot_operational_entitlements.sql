-- Extend the existing branch-scoped pilot grant mechanism only for the
-- operational transactions explicitly approved for the pilot.  No grant,
-- availability, membership or catalog approval is created by this migration.
begin;

do $preflight$
begin
  if current_user <> 'postgres'
    or pg_catalog.to_regclass('public.company_role_permission_grants') is null
    or pg_catalog.to_regprocedure('public.master_set_company_role_permission_grant(uuid,uuid,text,text,text,text)') is null
    or pg_catalog.to_regprocedure('app_private.assert_current_master()') is null then
    raise exception 'Company-scoped pilot governance prerequisites are missing';
  end if;
end;
$preflight$;

create or replace function public.master_set_company_role_permission_grant(
  p_tenant_id uuid,
  p_branch_id uuid,
  p_role_key text,
  p_permission_key text,
  p_operation text,
  p_reason text
)
returns text
language plpgsql
volatile
security definer
set search_path = ''
set row_security = off
as $function$
declare
  actor_id uuid;
  role_state text;
  permission_state text;
  changed_count integer;
  normalized_reason text := pg_catalog.btrim(coalesce(p_reason, ''));
  allowed_pilot_permissions constant text[] := array[
    'transaction.masterdata.party.manage',
    'transaction.masterdata.catalog.read',
    'transaction.masterdata.catalog.product.manage',
    'transaction.masterdata.catalog.product.update',
    'transaction.masterdata.catalog.product.read',
    'transaction.masterdata.catalog.service.manage',
    'transaction.purchasing.purchase_order.create',
    'transaction.purchasing.purchase_order.read',
    'transaction.purchasing.receipt.manage'
  ];
begin
  actor_id := app_private.assert_current_master();
  if p_tenant_id is null or p_branch_id is null or p_role_key is null or p_permission_key is null
    or p_operation not in ('grant', 'revoke')
    or pg_catalog.length(normalized_reason) not between 10 and 1000 then
    raise exception 'A company, branch and justification between 10 and 1000 characters are required' using errcode = '22023';
  end if;
  if p_role_key <> 'company_owner' or not (p_permission_key = any(allowed_pilot_permissions)) then
    raise exception 'This scoped pilot grant is limited to company_owner and the approved master-data, purchasing and receipt permissions' using errcode = '22023';
  end if;

  perform pg_catalog.pg_advisory_xact_lock(pg_catalog.hashtextextended(
    'company-scoped-role-permission:' || p_tenant_id::text || ':' || p_branch_id::text || ':' || p_role_key || ':' || p_permission_key, 0
  ));
  perform 1 from public.companies where id = p_tenant_id and status = 'active' for update;
  if not found then raise exception 'Active company not found' using errcode = 'P0002'; end if;
  perform 1 from public.branches
    where tenant_id = p_tenant_id and id = p_branch_id and status = 'active' for update;
  if not found then raise exception 'Active branch not found for company' using errcode = 'P0002'; end if;
  select approval_state into role_state from public.access_role_definitions
    where role_key = p_role_key for update;
  if not found then raise exception 'Role not found' using errcode = 'P0002'; end if;
  select approval_state into permission_state from public.permission_definitions
    where permission_key = p_permission_key for update;
  if not found then raise exception 'Permission not found' using errcode = 'P0002'; end if;

  if p_operation = 'grant' then
    if role_state <> 'approved' or permission_state <> 'approved' then
      raise exception 'Approved role and permission are required before granting' using errcode = '55000';
    end if;
    if exists (
      select 1 from public.role_permission_grants
      where role_key = p_role_key and permission_key = p_permission_key
    ) then
      raise exception 'A global grant already exists; a company-scoped duplicate is not permitted' using errcode = '55000';
    end if;
    insert into public.company_role_permission_grants(
      tenant_id, branch_id, role_key, permission_key, reason, created_by_user_id
    ) values (
      p_tenant_id, p_branch_id, p_role_key, p_permission_key, normalized_reason, actor_id
    ) on conflict (tenant_id, branch_id, role_key, permission_key) do nothing;
    get diagnostics changed_count = row_count;
  else
    delete from public.company_role_permission_grants
      where tenant_id = p_tenant_id and branch_id = p_branch_id
        and role_key = p_role_key and permission_key = p_permission_key;
    get diagnostics changed_count = row_count;
  end if;

  perform app_private.write_provisioning_audit(
    'master_company_role_permission.' || p_operation, p_tenant_id, null, actor_id,
    pg_catalog.jsonb_build_object(
      'branch_id', p_branch_id, 'role_key', p_role_key,
      'permission_key', p_permission_key, 'changed', changed_count = 1,
      'reason', normalized_reason
    )
  );
  return case when changed_count = 1 then p_operation else 'unchanged' end;
end;
$function$;

alter function public.master_set_company_role_permission_grant(uuid,uuid,text,text,text,text) owner to postgres;
revoke all on function public.master_set_company_role_permission_grant(uuid,uuid,text,text,text,text) from public, anon, authenticated, service_role;
grant execute on function public.master_set_company_role_permission_grant(uuid,uuid,text,text,text,text) to authenticated;

do $verify$
declare routine_oid oid;
begin
  routine_oid := pg_catalog.to_regprocedure('public.master_set_company_role_permission_grant(uuid,uuid,text,text,text,text)');
  if routine_oid is null or not exists (
    select 1 from pg_catalog.pg_proc procedure_row
    join pg_catalog.pg_roles owner_role on owner_role.oid = procedure_row.proowner
    where procedure_row.oid = routine_oid
      and owner_role.rolname = 'postgres'
      and procedure_row.prosecdef
      and 'search_path=""' = any(procedure_row.proconfig)
      and 'row_security=off' = any(procedure_row.proconfig)
  ) or not pg_catalog.has_function_privilege('authenticated', routine_oid, 'EXECUTE')
    or pg_catalog.has_function_privilege('anon', routine_oid, 'EXECUTE')
    or pg_catalog.has_function_privilege('service_role', routine_oid, 'EXECUTE') then
    raise exception 'Unsafe company-scoped pilot grant routine';
  end if;
end;
$verify$;

commit;
