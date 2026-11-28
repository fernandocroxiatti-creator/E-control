begin;

do $setup$
declare tenant_id uuid := pg_catalog.gen_random_uuid(); branch_id uuid := pg_catalog.gen_random_uuid(); actor_id uuid := pg_catalog.gen_random_uuid(); membership_id uuid := pg_catalog.gen_random_uuid(); customer_id uuid := pg_catalog.gen_random_uuid(); supplier_id uuid := pg_catalog.gen_random_uuid(); item_id uuid := pg_catalog.gen_random_uuid();
begin
  insert into auth.users(id,email,email_confirmed_at) values(actor_id,'direct-reversal-acl@example.test',clock_timestamp());
  insert into public.companies(id,legal_name,status) values(tenant_id,'Phase 06 commercial billing','active');
  insert into public.branches(id,tenant_id,code,name,status) values(branch_id,tenant_id,'P06','Phase 06 branch','active');
  insert into public.company_memberships(id,tenant_id,user_id,status,branch_access_mode,created_by_user_id) values(membership_id,tenant_id,actor_id,'active','all_branches',actor_id);
  insert into public.access_role_definitions(role_key,display_name,scope,approval_state) values('direct_reversal_owner','Phase 06 owner','company','approved');
  insert into public.membership_role_assignments(tenant_id,membership_id,role_key,branch_id,assigned_by_user_id) values(tenant_id,membership_id,'direct_reversal_owner',null,actor_id);
  update public.permission_definitions set approval_state='approved' where permission_key in (
    'transaction.sales.order.create','transaction.sales.order.manage','transaction.sales.order.read','transaction.sales.order.decide',
    'transaction.service_order.create','transaction.service_order.update','transaction.service_order.read','transaction.service_order.close',
    'transaction.billing.issue','transaction.billing.read','transaction.billing.cancel'
  );
  update public.erp_transaction_authorization_catalog set approval_state='approved' where transaction_code in ('ZVE01','ZVE02','ZVE03','ZVE04','ZOS01','ZOS02','ZOS03','ZOS04','ZFB01','ZFB02','ZFB03');
  insert into public.company_module_availability(tenant_id,module_code,enabled,changed_by_user_id) values(tenant_id,'SAL',true,actor_id),(tenant_id,'SVC',true,actor_id),(tenant_id,'FIN',true,actor_id);
  insert into public.company_transaction_availability(tenant_id,transaction_code,enabled,changed_by_user_id) values
    (tenant_id,'ZVE01',true,actor_id),(tenant_id,'ZVE02',true,actor_id),(tenant_id,'ZVE03',true,actor_id),(tenant_id,'ZVE04',true,actor_id),
    (tenant_id,'ZOS01',true,actor_id),(tenant_id,'ZOS02',true,actor_id),(tenant_id,'ZOS03',true,actor_id),(tenant_id,'ZOS04',true,actor_id),
    (tenant_id,'ZFB01',true,actor_id),(tenant_id,'ZFB02',true,actor_id),(tenant_id,'ZFB03',true,actor_id);
  insert into public.company_role_permission_grants(tenant_id,branch_id,grant_scope,role_key,permission_key,reason,created_by_user_id)
    select tenant_id,branch_id,'branch','direct_reversal_owner',permission_key,'Phase 06 isolated billing test',actor_id
    from (values
      ('transaction.sales.order.create'),('transaction.sales.order.manage'),('transaction.sales.order.read'),('transaction.sales.order.decide'),
      ('transaction.service_order.create'),('transaction.service_order.update'),('transaction.service_order.read'),('transaction.service_order.close'),
      ('transaction.billing.issue'),('transaction.billing.read'),('transaction.billing.cancel')
    ) granted(permission_key);
  insert into public.business_parties(id,tenant_id,party_type,legal_name,request_id,created_by_user_id) values
    (customer_id,tenant_id,'customer','Phase 06 customer',pg_catalog.gen_random_uuid(),actor_id),
    (supplier_id,tenant_id,'supplier','Phase 06 supplier',pg_catalog.gen_random_uuid(),actor_id);
  insert into public.catalog_items(id,tenant_id,item_type,code,name,unit_of_measure,current_cost,selling_price,minimum_stock,reorder_point,request_id,created_by_user_id)
    values(item_id,tenant_id,'product','P06-PART','Phase 06 part','UN',10,20,0,0,pg_catalog.gen_random_uuid(),actor_id);
  perform set_config('test.tenant_id',tenant_id::text,true);
  perform set_config('test.branch_id',branch_id::text,true);
  perform set_config('test.customer_id',customer_id::text,true);
  perform set_config('test.supplier_id',supplier_id::text,true);
  perform set_config('test.item_id',item_id::text,true);
  perform set_config('test.actor_id',actor_id::text,true);
end;
$setup$;

-- Exercise the PostgREST database role, not only JWT claims as postgres.
select set_config('request.jwt.claim.role','authenticated',true);
select set_config('request.jwt.claim.sub',current_setting('test.actor_id'),true);
set local role authenticated;

do $test$
declare
  tenant_id uuid := current_setting('test.tenant_id')::uuid;
  branch_id uuid := current_setting('test.branch_id')::uuid;
  customer_id uuid := current_setting('test.customer_id')::uuid;
  supplier_id uuid := current_setting('test.supplier_id')::uuid;
  item_id uuid := current_setting('test.item_id')::uuid;
  order_id uuid; purchase_id uuid; bill_id uuid; reversal_id uuid; open_order_id uuid; open_purchase_id uuid;
  request_id uuid := gen_random_uuid();
begin
  if current_user <> 'authenticated' then raise exception 'ACL regression must run as authenticated'; end if;
  order_id := public.operational_create_work_order(tenant_id,branch_id,customer_id,null,'Direct reversal ACL test',gen_random_uuid());
  purchase_id := public.operational_record_work_order_direct_purchase(tenant_id,order_id,supplier_id,item_id,'Direct cost',1,7,'Fictitious supplier',null,null,gen_random_uuid());
  perform set_config('test.order_id',order_id::text,true);
  perform set_config('test.purchase_id',purchase_id::text,true);
  open_order_id := public.operational_create_work_order(tenant_id,branch_id,customer_id,null,'Open direct reversal ACL test',gen_random_uuid());
  open_purchase_id := public.operational_record_work_order_direct_purchase(tenant_id,open_order_id,supplier_id,item_id,'Open direct cost',1,7,'Fictitious supplier',null,null,gen_random_uuid());
  perform public.operational_reverse_work_order_direct_purchase(tenant_id,open_order_id,open_purchase_id,'Open order cost correction',gen_random_uuid());
  perform set_config('test.open_order_id',open_order_id::text,true);

  perform set_config('request.jwt.claim.sub',gen_random_uuid()::text,true);
  begin
    perform public.operational_reverse_work_order_direct_purchase(tenant_id,order_id,purchase_id,'Unauthorised actor',gen_random_uuid());
    raise exception 'Non-member was allowed to reverse';
  exception when insufficient_privilege then null; end;
  perform set_config('request.jwt.claim.sub',current_setting('test.actor_id'),true);
  begin
    perform public.operational_reverse_work_order_direct_purchase(gen_random_uuid(),order_id,purchase_id,'Wrong company',gen_random_uuid());
    raise exception 'Cross-company reversal was allowed';
  exception when no_data_found then null; end;

  perform public.operational_close_work_order(tenant_id,order_id);
  bill_id := public.operational_issue_commercial_billing(tenant_id,'work_order',order_id,gen_random_uuid());
  begin
    perform public.operational_reverse_work_order_direct_purchase(tenant_id,order_id,purchase_id,'Blocked while billed',gen_random_uuid());
    raise exception 'Billed reversal was allowed';
  exception when object_not_in_prerequisite_state then null; end;
  perform public.operational_cancel_commercial_billing(tenant_id,bill_id,'Cancel before reversal',gen_random_uuid());
  reversal_id := public.operational_reverse_work_order_direct_purchase(tenant_id,order_id,purchase_id,'Authorised reversal',request_id);
  if public.operational_reverse_work_order_direct_purchase(tenant_id,order_id,purchase_id,'Authorised reversal',request_id) <> reversal_id then raise exception 'Replay duplicated reversal'; end if;
  begin
    perform public.operational_reverse_work_order_direct_purchase(tenant_id,order_id,purchase_id,'Second reversal',gen_random_uuid());
    raise exception 'Duplicate reversal was allowed';
  exception when unique_violation then null; end;
end;
$test$;

reset role;
do $verify$
begin
  if not has_function_privilege('authenticated','public.operational_reverse_work_order_direct_purchase(uuid,uuid,uuid,text,uuid)','EXECUTE')
     or has_function_privilege('anon','public.operational_reverse_work_order_direct_purchase(uuid,uuid,uuid,text,uuid)','EXECUTE')
     or has_function_privilege('service_role','public.operational_reverse_work_order_direct_purchase(uuid,uuid,uuid,text,uuid)','EXECUTE') then
    raise exception 'Direct reversal RPC ACL is incorrect';
  end if;
  if (select direct_purchase_total from public.work_orders where id=current_setting('test.open_order_id')::uuid) <> 0
     or (select direct_purchase_total from public.work_orders where id=current_setting('test.order_id')::uuid) <> 0
     or (select count(*) from public.work_order_direct_purchase_reversals where direct_purchase_id=current_setting('test.purchase_id')::uuid) <> 1
     or (select total_cost from public.work_order_direct_purchases where id=current_setting('test.purchase_id')::uuid) <> 7
     or exists(select 1 from public.inventory_movements where tenant_id=current_setting('test.tenant_id')::uuid) then
    raise exception 'Reversal changed original facts, stock or compensation total';
  end if;
end;
$verify$;
rollback;
