begin;

do $setup$
declare tenant_id uuid := pg_catalog.gen_random_uuid(); branch_id uuid := pg_catalog.gen_random_uuid(); actor_id uuid := pg_catalog.gen_random_uuid(); membership_id uuid := pg_catalog.gen_random_uuid(); customer_id uuid := pg_catalog.gen_random_uuid(); item_id uuid := pg_catalog.gen_random_uuid();
begin
  insert into auth.users(id,email,email_confirmed_at) values(actor_id,'phase04-sales-foundation@example.test',clock_timestamp());
  insert into public.companies(id,legal_name,status) values(tenant_id,'Phase 04 sales','active');
  insert into public.branches(id,tenant_id,code,name,status) values(branch_id,tenant_id,'P04','Phase 04 branch','active');
  insert into public.company_memberships(id,tenant_id,user_id,status,branch_access_mode,created_by_user_id) values(membership_id,tenant_id,actor_id,'active','all_branches',actor_id);
  insert into public.access_role_definitions(role_key,display_name,scope,approval_state) values('phase04_owner','Phase 04 owner','company','approved');
  insert into public.membership_role_assignments(tenant_id,membership_id,role_key,branch_id,assigned_by_user_id) values(tenant_id,membership_id,'phase04_owner',null,actor_id);
  update public.permission_definitions set approval_state='approved' where permission_key in ('transaction.sales.order.create','transaction.sales.order.manage','transaction.sales.order.read','transaction.sales.order.decide','transaction.quotation.create','transaction.quotation.approve','transaction.quotation.read');
  update public.erp_transaction_authorization_catalog set approval_state='approved' where transaction_code in ('ZVE01','ZVE02','ZVE03','ZVE04','ZQT01','ZQT03','ZQT04');
  insert into public.company_module_availability(tenant_id,module_code,enabled,changed_by_user_id) values(tenant_id,'SAL',true,actor_id),(tenant_id,'BUD',true,actor_id);
  insert into public.company_transaction_availability(tenant_id,transaction_code,enabled,changed_by_user_id) values(tenant_id,'ZVE01',true,actor_id),(tenant_id,'ZVE02',true,actor_id),(tenant_id,'ZVE03',true,actor_id),(tenant_id,'ZVE04',true,actor_id),(tenant_id,'ZQT01',true,actor_id),(tenant_id,'ZQT03',true,actor_id),(tenant_id,'ZQT04',true,actor_id);
  insert into public.company_role_permission_grants(tenant_id,branch_id,grant_scope,role_key,permission_key,reason,created_by_user_id) values
    (tenant_id,branch_id,'branch','phase04_owner','transaction.sales.order.create','Phase 04 isolated test',actor_id),(tenant_id,branch_id,'branch','phase04_owner','transaction.sales.order.manage','Phase 04 isolated test',actor_id),(tenant_id,branch_id,'branch','phase04_owner','transaction.sales.order.read','Phase 04 isolated test',actor_id),(tenant_id,branch_id,'branch','phase04_owner','transaction.sales.order.decide','Phase 04 isolated test',actor_id),(tenant_id,branch_id,'branch','phase04_owner','transaction.quotation.create','Phase 04 isolated test',actor_id),(tenant_id,branch_id,'branch','phase04_owner','transaction.quotation.read','Phase 04 isolated test',actor_id),(tenant_id,branch_id,'branch','phase04_owner','transaction.quotation.approve','Phase 04 isolated test',actor_id);
  insert into public.business_parties(id,tenant_id,party_type,legal_name,request_id,created_by_user_id) values(customer_id,tenant_id,'customer','Phase 04 sales customer',pg_catalog.gen_random_uuid(),actor_id);
  insert into public.catalog_items(id,tenant_id,item_type,code,name,unit_of_measure,current_cost,selling_price,minimum_stock,reorder_point,request_id,created_by_user_id) values(item_id,tenant_id,'product','P04-SALES-PART','Phase 04 sales part','UN',10,20,0,0,pg_catalog.gen_random_uuid(),actor_id);
end;
$setup$;

select set_config('request.jwt.claim.role','authenticated',false);
select set_config('request.jwt.claim.sub',(select id::text from auth.users where email='phase04-sales-foundation@example.test'),false);

do $test$
declare v_tenant_id uuid; v_branch_id uuid; v_customer_id uuid; v_item_id uuid; sale_id uuid; quote_id uuid; converted_id uuid; before_stock integer; after_stock integer;
begin
  select id into v_tenant_id from public.companies where legal_name='Phase 04 sales'; select id into v_branch_id from public.branches where tenant_id=v_tenant_id and code='P04'; select id into v_customer_id from public.business_parties where tenant_id=v_tenant_id and legal_name='Phase 04 sales customer'; select id into v_item_id from public.catalog_items where tenant_id=v_tenant_id and code='P04-SALES-PART';
  select public.operational_create_sales_order(v_tenant_id,v_branch_id,v_customer_id,'Phase 04 test',jsonb_build_array(jsonb_build_object('item_id',v_item_id,'quantity',2,'unit_price',30,'discount_percent',10)),'97000000-0000-4000-8000-000000000001') into sale_id;
  if public.operational_create_sales_order(v_tenant_id,v_branch_id,v_customer_id,'Phase 04 test',jsonb_build_array(jsonb_build_object('item_id',v_item_id,'quantity',2,'unit_price',30,'discount_percent',10)),'97000000-0000-4000-8000-000000000001') <> sale_id then raise exception 'sales replay did not return original id'; end if;
  if (select total_amount from public.sales_orders where id=sale_id) <> 54 then raise exception 'sales total was not calculated from snapshots'; end if;
  begin perform public.operational_create_sales_order(v_tenant_id,v_branch_id,v_customer_id,'Different',jsonb_build_array(jsonb_build_object('item_id',v_item_id,'quantity',1,'unit_price',30,'discount_percent',0)),'97000000-0000-4000-8000-000000000001'); raise exception 'divergent sales replay accepted'; exception when unique_violation then null; end;
  perform public.operational_update_sales_order(v_tenant_id,sale_id,v_customer_id,'Updated',jsonb_build_array(jsonb_build_object('item_id',v_item_id,'quantity',3,'unit_price',25,'discount_percent',0)),'97000000-0000-4000-8000-000000000002');
  if (select total_amount from public.sales_orders where id=sale_id) <> 75 then raise exception 'sales update total is incorrect'; end if;
  if public.operational_decide_sales_order(v_tenant_id,sale_id,'confirmed','Commercial confirmation','97000000-0000-4000-8000-000000000003') <> 'confirmed' then raise exception 'sales confirmation failed'; end if;
  select public.operational_create_quotation(v_tenant_id,v_branch_id,v_customer_id,null,'Source quotation',jsonb_build_array(jsonb_build_object('item_id',v_item_id,'quantity',1,'unit_price',40,'discount_percent',0)),'97000000-0000-4000-8000-000000000004') into quote_id;
  perform public.operational_decide_quotation(v_tenant_id,quote_id,'approved','Approved for sales','97000000-0000-4000-8000-000000000005');
  select count(*) into before_stock from public.inventory_movements m where m.tenant_id=v_tenant_id;
  select public.operational_convert_quotation_to_sales_order(v_tenant_id,quote_id,'97000000-0000-4000-8000-000000000006') into converted_id;
  if public.operational_convert_quotation_to_sales_order(v_tenant_id,quote_id,'97000000-0000-4000-8000-000000000006') <> converted_id then raise exception 'quotation sales conversion replay failed'; end if;
  select count(*) into after_stock from public.inventory_movements m where m.tenant_id=v_tenant_id;
  if after_stock<>before_stock or not exists(select 1 from app_private.operational_audit_events e where e.tenant_id=v_tenant_id and e.event_key='sales_order.created_from_quotation') then raise exception 'sales conversion changed stock or missed audit'; end if;
end;
$test$;

do $security$
begin
  if not (select relrowsecurity and relforcerowsecurity from pg_class where oid='public.sales_orders'::regclass) or has_table_privilege('authenticated','public.sales_orders','select') or has_function_privilege('anon','public.operational_create_sales_order(uuid,uuid,uuid,text,jsonb,uuid)','execute') or has_function_privilege('service_role','public.operational_create_sales_order(uuid,uuid,uuid,text,jsonb,uuid)','execute') then raise exception 'sales RLS or ACL hardening failed'; end if;
end;
$security$;
rollback;
