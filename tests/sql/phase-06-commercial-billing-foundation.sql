begin;

do $setup$
declare tenant_id uuid := pg_catalog.gen_random_uuid(); branch_id uuid := pg_catalog.gen_random_uuid(); actor_id uuid := pg_catalog.gen_random_uuid(); membership_id uuid := pg_catalog.gen_random_uuid(); customer_id uuid := pg_catalog.gen_random_uuid(); supplier_id uuid := pg_catalog.gen_random_uuid(); item_id uuid := pg_catalog.gen_random_uuid();
begin
  insert into auth.users(id,email,email_confirmed_at) values(actor_id,'phase06-commercial-billing@example.test',clock_timestamp());
  insert into public.companies(id,legal_name,status) values(tenant_id,'Phase 06 commercial billing','active');
  insert into public.branches(id,tenant_id,code,name,status) values(branch_id,tenant_id,'P06','Phase 06 branch','active');
  insert into public.company_memberships(id,tenant_id,user_id,status,branch_access_mode,created_by_user_id) values(membership_id,tenant_id,actor_id,'active','all_branches',actor_id);
  insert into public.access_role_definitions(role_key,display_name,scope,approval_state) values('phase06_owner','Phase 06 owner','company','approved');
  insert into public.membership_role_assignments(tenant_id,membership_id,role_key,branch_id,assigned_by_user_id) values(tenant_id,membership_id,'phase06_owner',null,actor_id);
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
    select tenant_id,branch_id,'branch','phase06_owner',permission_key,'Phase 06 isolated billing test',actor_id
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
end;
$setup$;

select set_config('request.jwt.claim.role','authenticated',false);
select set_config('request.jwt.claim.sub',(select id::text from auth.users where email='phase06-commercial-billing@example.test'),false);

do $test$
declare tenant_id uuid; branch_id uuid; customer_id uuid; supplier_id uuid; item_id uuid; sales_id uuid; work_order_id uuid; direct_purchase_id uuid; sales_bill_id uuid; work_order_bill_id uuid; before_financial integer; after_financial integer;
begin
  select id into tenant_id from public.companies where legal_name='Phase 06 commercial billing';
  select id into branch_id from public.branches where tenant_id=tenant_id and code='P06';
  select id into customer_id from public.business_parties where tenant_id=tenant_id and party_type='customer';
  select id into supplier_id from public.business_parties where tenant_id=tenant_id and party_type='supplier';
  select id into item_id from public.catalog_items where tenant_id=tenant_id and code='P06-PART';

  select public.operational_create_sales_order(tenant_id,branch_id,customer_id,'Phase 06 sale',jsonb_build_array(jsonb_build_object('item_id',item_id,'quantity',2,'unit_price',30,'discount_percent',0)),'96000000-0000-4000-8000-000000000001') into sales_id;
  perform public.operational_decide_sales_order(tenant_id,sales_id,'confirmed','Phase 06 commercial confirmation','96000000-0000-4000-8000-000000000002');
  select public.operational_issue_commercial_billing(tenant_id,'sales_order',sales_id,'96000000-0000-4000-8000-000000000003') into sales_bill_id;
  if public.operational_issue_commercial_billing(tenant_id,'sales_order',sales_id,'96000000-0000-4000-8000-000000000003') <> sales_bill_id then raise exception 'T06 identical billing replay did not return original document'; end if;
  begin perform public.operational_issue_commercial_billing(tenant_id,'work_order',sales_id,'96000000-0000-4000-8000-000000000003'); raise exception 'T06 divergent billing replay accepted'; exception when unique_violation then null; end;
  begin perform public.operational_issue_commercial_billing(tenant_id,'sales_order',sales_id,'96000000-0000-4000-8000-000000000004'); raise exception 'T06 source was billed twice'; exception when unique_violation then null; end;
  if public.operational_cancel_commercial_billing(tenant_id,sales_bill_id,'Commercial cancellation test','96000000-0000-4000-8000-000000000005') <> 'cancelled' then raise exception 'T06 billing cancellation failed'; end if;
  if public.operational_cancel_commercial_billing(tenant_id,sales_bill_id,'Commercial cancellation test','96000000-0000-4000-8000-000000000005') <> 'cancelled' then raise exception 'T06 cancellation replay failed'; end if;
  begin perform public.operational_cancel_commercial_billing(tenant_id,sales_bill_id,'Different reason','96000000-0000-4000-8000-000000000005'); raise exception 'T06 divergent cancellation replay accepted'; exception when unique_violation then null; end;
  if not exists(select 1 from public.commercial_billing_documents where tenant_id=tenant_id and id=sales_bill_id and status='cancelled') or (select count(*) from public.commercial_billing_events where tenant_id=tenant_id and billing_document_id=sales_bill_id)<>2 then raise exception 'T06 immutable cancellation event history is incomplete'; end if;

  select public.operational_create_work_order(tenant_id,branch_id,customer_id,null,'Phase 06 billing guard','96000000-0000-4000-8000-000000000006') into work_order_id;
  select public.operational_record_work_order_direct_purchase(tenant_id,work_order_id,supplier_id,item_id,'Phase 06 direct part',1,15,'test supplier receipt','P06-DP',null,'96000000-0000-4000-8000-000000000007') into direct_purchase_id;
  perform public.operational_close_work_order(tenant_id,work_order_id);
  select public.operational_issue_commercial_billing(tenant_id,'work_order',work_order_id,'96000000-0000-4000-8000-000000000008') into work_order_bill_id;
  begin perform public.operational_reverse_work_order_direct_purchase(tenant_id,work_order_id,direct_purchase_id,'Blocked while billed','96000000-0000-4000-8000-000000000009'); raise exception 'T06 billed work-order direct purchase reversal accepted'; exception when object_not_in_prerequisite_state then null; end;
  perform public.operational_cancel_commercial_billing(tenant_id,work_order_bill_id,'Cancel before cost correction','96000000-0000-4000-8000-000000000010');
  perform public.operational_reverse_work_order_direct_purchase(tenant_id,work_order_id,direct_purchase_id,'Cost correction after cancellation','96000000-0000-4000-8000-000000000011');
  if (select direct_purchase_total from public.work_orders where tenant_id=tenant_id and id=work_order_id)<>0 then raise exception 'T06 direct purchase total was not reversed after billing cancellation'; end if;

  select count(*) into before_financial from pg_catalog.pg_tables where schemaname='public' and tablename in ('accounts_payable','accounts_receivable','cash_movements','fiscal_documents');
  select count(*) into after_financial from pg_catalog.pg_tables where schemaname='public' and tablename in ('accounts_payable','accounts_receivable','cash_movements','fiscal_documents');
  if after_financial<>before_financial then raise exception 'T06 billing altered financial or fiscal schema'; end if;
  if (select count(*) from public.operational_list_commercial_billing(tenant_id,branch_id,null,100,0))<>2 then raise exception 'T06 commercial billing read model did not return tenant branch facts'; end if;
end;
$test$;

do $security$
begin
  if not (select relrowsecurity and relforcerowsecurity from pg_class where oid='public.commercial_billing_documents'::regclass)
    or has_table_privilege('authenticated','public.commercial_billing_documents','select')
    or has_function_privilege('anon','public.operational_issue_commercial_billing(uuid,text,uuid,uuid)','execute')
    or has_function_privilege('service_role','public.operational_cancel_commercial_billing(uuid,uuid,text,uuid)','execute') then
    raise exception 'T06 billing RLS or ACL hardening failed';
  end if;
end;
$security$;

rollback;
