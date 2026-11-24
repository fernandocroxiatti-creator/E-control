begin;

do $test$
declare
  tenant_a constant uuid := 'e2000000-0000-4000-8000-000000000001';
  tenant_b constant uuid := 'e2000000-0000-4000-8000-000000000002';
  branch_a constant uuid := 'e3000000-0000-4000-8000-000000000001';
  branch_b constant uuid := 'e3000000-0000-4000-8000-000000000002';
  master_user constant uuid := 'e1000000-0000-4000-8000-000000000001';
  owner_a constant uuid := 'e1000000-0000-4000-8000-000000000002';
  permission_key text;
begin
  perform set_config('request.jwt.claim.role', 'authenticated', true);
  perform set_config('request.jwt.claim.sub', master_user::text, true);

  update public.access_role_definitions set approval_state = 'approved' where role_key = 'company_owner';
  update public.permission_definitions as permission_definition set approval_state = 'approved'
    where permission_definition.permission_key = any(array[
      'transaction.masterdata.party.manage',
      'transaction.masterdata.catalog.read',
      'transaction.masterdata.catalog.product.manage',
      'transaction.masterdata.catalog.product.update',
      'transaction.masterdata.catalog.product.read',
      'transaction.masterdata.catalog.service.manage',
      'transaction.purchasing.purchase_order.create',
      'transaction.purchasing.purchase_order.read',
      'transaction.purchasing.receipt.manage'
    ]);
  update public.erp_transaction_authorization_catalog set approval_state = 'approved'
    where transaction_code = any(array['BP01','MM01','MM02','MM03','SV01','ME21N','ME23N','ZGR01']);
  perform public.master_set_company_transaction_availability(
    tenant_a,
    array['BP01','MM01','MM02','MM03','SV01','ME21N','ME23N','ZGR01'],
    'Pilot operational availability for isolated company tests'
  );

  foreach permission_key in array array[
    'transaction.masterdata.party.manage',
    'transaction.masterdata.catalog.read',
    'transaction.masterdata.catalog.product.manage',
    'transaction.masterdata.catalog.product.update',
    'transaction.masterdata.catalog.product.read',
    'transaction.masterdata.catalog.service.manage',
    'transaction.purchasing.purchase_order.create',
    'transaction.purchasing.purchase_order.read',
    'transaction.purchasing.receipt.manage'
  ] loop
    if public.master_set_company_role_permission_grant(
      tenant_a, branch_a, 'company_owner', permission_key, 'grant', 'Pilot scoped operational permission approval'
    ) <> 'grant' then
      raise exception 'scoped pilot permission was not granted: %', permission_key;
    end if;
  end loop;

  begin
    perform public.master_set_company_role_permission_grant(
      tenant_a, branch_a, 'company_owner', 'transaction.inventory.valuation.initial', 'grant', 'Attempt to grant valuation outside pilot scope'
    );
    raise exception 'ZIV01 permission was accepted by scoped pilot governance';
  exception when invalid_parameter_value then null;
  end;
  begin
    perform public.master_set_company_role_permission_grant(
      tenant_a, branch_a, 'branch_operator', 'transaction.masterdata.party.manage', 'grant', 'Attempt to grant a role outside pilot scope'
    );
    raise exception 'non-owner role was accepted by scoped pilot governance';
  exception when invalid_parameter_value then null;
  end;

  perform set_config('request.jwt.claim.sub', owner_a::text, true);
  if not app_private.has_tenant_permission(tenant_a, 'transaction.masterdata.party.manage', branch_a)
    or not app_private.has_tenant_permission(tenant_a, 'transaction.purchasing.purchase_order.create', branch_a)
    or not app_private.has_tenant_permission(tenant_a, 'transaction.purchasing.receipt.manage', branch_a)
    or not public.authorize_company_transaction(tenant_a, branch_a, 'BP01')
    or not public.authorize_company_transaction(tenant_a, branch_a, 'ME21N')
    or not public.authorize_company_transaction(tenant_a, branch_a, 'ZGR01') then
    raise exception 'company owner did not receive the exact scoped pilot authorizations';
  end if;
  if app_private.has_tenant_permission(tenant_a, 'transaction.masterdata.party.manage', branch_b)
    or app_private.has_tenant_permission(tenant_b, 'transaction.masterdata.party.manage', branch_a)
    or public.authorize_company_transaction(tenant_a, branch_a, 'ZIV01') then
    raise exception 'pilot scoped operational grant crossed a branch, tenant or ZIV01 boundary';
  end if;

  perform set_config('request.jwt.claim.sub', master_user::text, true);
  if public.master_set_company_role_permission_grant(
    tenant_a, branch_a, 'company_owner', 'transaction.masterdata.party.manage', 'revoke', 'Pilot scoped operational permission revocation'
  ) <> 'revoke' then
    raise exception 'pilot scoped permission revocation did not persist';
  end if;
end;
$test$;

rollback;
