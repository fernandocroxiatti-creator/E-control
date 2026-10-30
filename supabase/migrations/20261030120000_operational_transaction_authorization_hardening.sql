-- Prepared only. This migration is intentionally NOT approved for Production.
-- It adds catalog and company-entitlement enforcement to every existing
-- operational RPC through the central assertion, without granting access.
begin;

do $preflight$
begin
  if current_user <> 'postgres' then raise exception 'Apply this migration as postgres'; end if;
  if pg_catalog.to_regclass('public.company_module_availability') is null
    or pg_catalog.to_regclass('public.company_transaction_availability') is null
    or pg_catalog.to_regclass('public.erp_transaction_authorization_catalog') is null
    or pg_catalog.to_regclass('public.permission_definitions') is null
    or pg_catalog.to_regprocedure('app_private.assert_operational_permission(uuid,text,uuid)') is null
    or pg_catalog.to_regprocedure('app_private.has_tenant_permission(uuid,text,uuid)') is null
    or pg_catalog.to_regprocedure('app_private.can_access_branch(uuid,uuid)') is null then
    raise exception 'Operational authorization and company-entitlement foundations are required';
  end if;
end;
$preflight$;

create or replace function app_private.assert_operational_permission(
  p_tenant_id uuid,
  p_permission_key text,
  p_branch_id uuid default null
)
returns uuid language plpgsql stable security definer set search_path='' set row_security=off as $function$
declare
  actor_id uuid;
  required_codes text[];
  approved_code_count integer;
begin
  if coalesce(auth.role(),'') <> 'authenticated' or auth.uid() is null then
    raise exception 'Authenticated session required' using errcode='42501';
  end if;
  actor_id := auth.uid();
  if p_tenant_id is null or p_permission_key is null
    or not exists (select 1 from public.companies where id=p_tenant_id and status='active')
    or not app_private.is_active_company_member(p_tenant_id)
    or (p_branch_id is not null and not app_private.can_access_branch(p_tenant_id,p_branch_id))
    or not app_private.has_tenant_permission(p_tenant_id,p_permission_key,p_branch_id)
    or not exists (select 1 from public.permission_definitions where permission_key=p_permission_key and approval_state='approved') then
    raise exception 'Operational permission denied' using errcode='42501';
  end if;

  -- Read contracts without a branch remain company-scoped. Catalog reads require
  -- both product and service transactions so an unrestricted listing cannot leak
  -- a type from a module that the company did not enable.
  required_codes := case p_permission_key
    when 'transaction.masterdata.party.read' then array['BP01']
    when 'transaction.masterdata.party.manage' then array['BP01']
    when 'transaction.masterdata.catalog.read' then array['MM01','SV01']
    when 'transaction.masterdata.catalog.product.manage' then array['MM01']
    when 'transaction.masterdata.catalog.service.manage' then array['SV01']
    when 'transaction.inventory.stock.read' then array['MIGO']
    when 'transaction.inventory.stock.move' then array['MIGO']
    when 'transaction.purchasing.purchase_order.read' then array['ME23N']
    when 'transaction.purchasing.purchase_order.create' then array['ME21N']
    else null
  end;
  if required_codes is null then
    raise exception 'Operational permission is not mapped to an approved transaction' using errcode='42501';
  end if;

  select count(distinct catalog.transaction_code) into approved_code_count
  from public.erp_transaction_authorization_catalog catalog
  join public.permission_definitions catalog_permission
    on catalog_permission.permission_key=catalog.permission_key
   and catalog_permission.approval_state='approved'
  join public.company_module_availability module_availability
    on module_availability.tenant_id=p_tenant_id
   and module_availability.module_code=catalog.module_code
   and module_availability.enabled
  join public.company_transaction_availability transaction_availability
    on transaction_availability.tenant_id=p_tenant_id
   and transaction_availability.transaction_code=catalog.transaction_code
   and transaction_availability.enabled
  where catalog.transaction_code=any(required_codes)
    and catalog.approval_state='approved';
  if approved_code_count <> cardinality(required_codes) then
    raise exception 'Operational transaction is not approved or available for this company' using errcode='42501';
  end if;
  return actor_id;
end;
$function$;

alter function app_private.assert_operational_permission(uuid,text,uuid) owner to postgres;
revoke all on function app_private.assert_operational_permission(uuid,text,uuid) from public,anon,authenticated,service_role;

do $verify$
declare routine_oid oid;
begin
  routine_oid:=pg_catalog.to_regprocedure('app_private.assert_operational_permission(uuid,text,uuid)');
  if routine_oid is null or not exists (
    select 1 from pg_catalog.pg_proc where oid=routine_oid and proowner='postgres'::regrole
      and prosecdef and 'search_path=""'=any(proconfig) and 'row_security=off'=any(proconfig)
  ) or pg_catalog.has_function_privilege('authenticated',routine_oid,'EXECUTE')
    or pg_catalog.has_function_privilege('service_role',routine_oid,'EXECUTE') then
    raise exception 'Unsafe operational authorization assertion';
  end if;
end;
$verify$;

comment on function app_private.assert_operational_permission(uuid,text,uuid) is
  'Authenticated, role-grant, catalog-approval and company-entitlement authorization for operational RPCs.';
commit;
