-- The read models must support the exact six transaction grants used by the
-- first company, without broadening an unfiltered catalog lookup.
do $setup$
declare
  v_tenant_id constant uuid := '91000000-0000-4000-8000-000000000001';
  v_branch_id constant uuid := '92000000-0000-4000-8000-000000000001';
  v_actor_id constant uuid := '93000000-0000-4000-8000-000000000001';
  v_membership_id constant uuid := '94000000-0000-4000-8000-000000000001';
begin
  insert into auth.users(id,email,email_confirmed_at) values(v_actor_id,'read-alignment@example.test',clock_timestamp());
  insert into public.companies(id,legal_name,status) values(v_tenant_id,'Read Alignment Company','active');
  insert into public.branches(id,tenant_id,code,name,status) values(v_branch_id,v_tenant_id,'001','Read Alignment Branch','active');
  insert into public.company_memberships(id,tenant_id,user_id,status,branch_access_mode,created_by_user_id) values(v_membership_id,v_tenant_id,v_actor_id,'active','assigned_only',v_actor_id);
  insert into public.branch_access(tenant_id,branch_id,membership_id,status,granted_by_user_id) values(v_tenant_id,v_branch_id,v_membership_id,'active',v_actor_id);
  insert into public.access_role_definitions(role_key,display_name,scope,approval_state) values('read_alignment_role','Read alignment role','company','approved');
  insert into public.membership_role_assignments(tenant_id,membership_id,role_key,branch_id,assigned_by_user_id) values(v_tenant_id,v_membership_id,'read_alignment_role',null,v_actor_id);
  update public.permission_definitions set approval_state='approved' where permission_key in ('transaction.masterdata.party.manage','transaction.masterdata.catalog.product.manage','transaction.masterdata.catalog.service.manage','transaction.inventory.stock.move');
  insert into public.role_permission_grants(role_key,permission_key) values
    ('read_alignment_role','transaction.masterdata.party.manage'),
    ('read_alignment_role','transaction.masterdata.catalog.product.manage'),
    ('read_alignment_role','transaction.masterdata.catalog.service.manage'),
    ('read_alignment_role','transaction.inventory.stock.move');
  update public.erp_transaction_authorization_catalog set approval_state='approved' where transaction_code in ('BP01','MM01','SV01','MIGO');
  insert into public.company_module_availability(tenant_id,module_code,enabled,changed_by_user_id)
    select v_tenant_id,catalog.module_code,true,v_actor_id from public.erp_transaction_authorization_catalog catalog where catalog.transaction_code in ('BP01','MM01','SV01','MIGO') group by catalog.module_code
    on conflict(tenant_id,module_code) do update set enabled=excluded.enabled;
  insert into public.company_transaction_availability(tenant_id,transaction_code,enabled,changed_by_user_id)
    select v_tenant_id,catalog.transaction_code,true,v_actor_id from public.erp_transaction_authorization_catalog catalog where catalog.transaction_code in ('BP01','MM01','SV01','MIGO')
    on conflict(tenant_id,transaction_code) do update set enabled=excluded.enabled;
end;
$setup$;

select set_config('request.jwt.claim.role','authenticated',false);
select set_config('request.jwt.claim.sub','93000000-0000-4000-8000-000000000001',false);

do $read_contract$
declare
  tenant_id constant uuid := '91000000-0000-4000-8000-000000000001';
  branch_id constant uuid := '92000000-0000-4000-8000-000000000001';
  product_id uuid;
  counted integer;
begin
  perform public.operational_create_business_party(tenant_id,'supplier','Read Alignment Supplier','12345678000199',null,null,'{}'::jsonb,'95000000-0000-4000-8000-000000000001');
  select public.operational_create_catalog_item(tenant_id,'product','READ-PRODUCT','Read product',null,null,null,null,'UN',null,null,10,15,null,null,0,0,null,null,'96000000-0000-4000-8000-000000000001') into product_id;
  perform public.operational_create_catalog_item(tenant_id,'service','READ-SERVICE','Read service',null,null,null,null,'UN',null,null,0,20,null,null,0,0,null,null,'96000000-0000-4000-8000-000000000002');
  perform public.operational_record_inventory_movement(tenant_id,branch_id,product_id,'initial',2,'97000000-0000-4000-8000-000000000001','read alignment');

  select count(*) into counted from public.operational_list_business_parties(tenant_id,null,null,null,25,0);
  if counted <> 1 then raise exception 'BP01 cannot read its own commercial parties'; end if;
  select count(*) into counted from public.operational_list_catalog_items(tenant_id,null,'product',null,25,0);
  if counted <> 1 then raise exception 'MM01 cannot read its own product catalog'; end if;
  select count(*) into counted from public.operational_list_catalog_items(tenant_id,null,'service',null,25,0);
  if counted <> 1 then raise exception 'SV01 cannot read its own service catalog'; end if;
  begin
    perform public.operational_list_catalog_items(tenant_id,null,null,null,25,0);
    raise exception 'unfiltered catalog bypassed transaction.masterdata.catalog.read';
  exception when insufficient_privilege then null;
  end;
  select count(*) into counted from public.operational_list_inventory_balances(tenant_id,branch_id,null,25,0);
  if counted <> 1 then raise exception 'MIGO cannot read its branch balance'; end if;
  select count(*) into counted from public.operational_list_inventory_movements(tenant_id,branch_id,null,null,null,null,25,0);
  if counted <> 1 then raise exception 'MIGO cannot read its branch movement history'; end if;
  begin
    perform public.operational_list_inventory_balances('81000000-0000-4000-8000-000000000002','82000000-0000-4000-8000-000000000002',null,25,0);
    raise exception 'MIGO crossed tenant isolation';
  exception when insufficient_privilege then null;
  end;
end;
$read_contract$;
