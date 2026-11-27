begin;

do $setup$
declare tenant_id constant uuid := 'a5100000-0000-4000-8000-000000000001'; branch_id constant uuid := 'a5200000-0000-4000-8000-000000000001'; actor_id constant uuid := 'a5300000-0000-4000-8000-000000000001'; membership_id constant uuid := 'a5400000-0000-4000-8000-000000000001'; customer_id constant uuid := 'a5500000-0000-4000-8000-000000000001'; item_id constant uuid := 'a5600000-0000-4000-8000-000000000001';
begin
  insert into auth.users(id,email,email_confirmed_at) values(actor_id,'phase05-sales-inventory@example.test',clock_timestamp());
  insert into public.companies(id,legal_name,status) values(tenant_id,'Phase 05 sales inventory','active');
  insert into public.branches(id,tenant_id,code,name,status) values(branch_id,tenant_id,'P05','Phase 05 branch','active');
  insert into public.company_memberships(id,tenant_id,user_id,status,branch_access_mode,created_by_user_id) values(membership_id,tenant_id,actor_id,'active','all_branches',actor_id);
  insert into public.access_role_definitions(role_key,display_name,scope,approval_state) values('phase05_owner','Phase 05 owner','company','approved');
  insert into public.membership_role_assignments(tenant_id,membership_id,role_key,branch_id,assigned_by_user_id) values(tenant_id,membership_id,'phase05_owner',null,actor_id);
  update public.permission_definitions set approval_state='approved' where permission_key in ('transaction.sales.order.create','transaction.sales.order.read','transaction.sales.order.decide','transaction.sales.inventory.reserve','transaction.sales.inventory.fulfill','transaction.sales.inventory.return');
  update public.erp_transaction_authorization_catalog set approval_state='approved' where transaction_code in ('ZVE01','ZVE03','ZVE04','ZVE05','ZVE06','ZVE07');
  insert into public.company_module_availability(tenant_id,module_code,enabled,changed_by_user_id) values(tenant_id,'SAL',true,actor_id);
  insert into public.company_transaction_availability(tenant_id,transaction_code,enabled,changed_by_user_id) values(tenant_id,'ZVE01',true,actor_id),(tenant_id,'ZVE03',true,actor_id),(tenant_id,'ZVE04',true,actor_id),(tenant_id,'ZVE05',true,actor_id),(tenant_id,'ZVE06',true,actor_id),(tenant_id,'ZVE07',true,actor_id);
  insert into public.company_role_permission_grants(tenant_id,branch_id,grant_scope,role_key,permission_key,reason,created_by_user_id) values
    (tenant_id,branch_id,'branch','phase05_owner','transaction.sales.order.create','Phase 05 test',actor_id),(tenant_id,branch_id,'branch','phase05_owner','transaction.sales.order.read','Phase 05 test',actor_id),(tenant_id,branch_id,'branch','phase05_owner','transaction.sales.order.decide','Phase 05 test',actor_id),(tenant_id,branch_id,'branch','phase05_owner','transaction.sales.inventory.reserve','Phase 05 test',actor_id),(tenant_id,branch_id,'branch','phase05_owner','transaction.sales.inventory.fulfill','Phase 05 test',actor_id),(tenant_id,branch_id,'branch','phase05_owner','transaction.sales.inventory.return','Phase 05 test',actor_id);
  insert into public.business_parties(id,tenant_id,party_type,legal_name,request_id,created_by_user_id) values(customer_id,tenant_id,'customer','Phase 05 customer',pg_catalog.gen_random_uuid(),actor_id);
  insert into public.catalog_items(id,tenant_id,item_type,code,name,unit_of_measure,current_cost,selling_price,minimum_stock,reorder_point,request_id,created_by_user_id) values(item_id,tenant_id,'product','P05-PART','Phase 05 part','UN',10,20,0,0,pg_catalog.gen_random_uuid(),actor_id);
  insert into public.inventory_balances(tenant_id,branch_id,item_id,quantity,valuation_status,stock_value,average_unit_cost,valuation_updated_at) values(tenant_id,branch_id,item_id,10,'valued',100,10,clock_timestamp());
end;
$setup$;

select set_config('request.jwt.claim.role','authenticated',false);
select set_config('request.jwt.claim.sub','a5300000-0000-4000-8000-000000000001',false);

do $test$
declare v_tenant_id constant uuid := 'a5100000-0000-4000-8000-000000000001'; v_branch_id constant uuid := 'a5200000-0000-4000-8000-000000000001'; v_customer_id constant uuid := 'a5500000-0000-4000-8000-000000000001'; v_item_id constant uuid := 'a5600000-0000-4000-8000-000000000001'; sale_id uuid; released_sale_id uuid; delivered_movement uuid;
begin
  select public.operational_create_sales_order(v_tenant_id,v_branch_id,v_customer_id,'Phase 05 delivery',jsonb_build_array(jsonb_build_object('item_id',v_item_id,'quantity',3,'unit_price',20,'discount_percent',0)),'a5700000-0000-4000-8000-000000000001') into sale_id;
  perform public.operational_decide_sales_order(v_tenant_id,sale_id,'confirmed','Test confirmation','a5700000-0000-4000-8000-000000000002');
  if public.operational_reserve_sales_order_inventory(v_tenant_id,sale_id,'a5700000-0000-4000-8000-000000000003')<>'reserved' then raise exception 'reservation failed'; end if;
  if public.operational_reserve_sales_order_inventory(v_tenant_id,sale_id,'a5700000-0000-4000-8000-000000000003')<>'reserved' then raise exception 'reservation replay failed'; end if;
  if (select r.quantity from public.sales_order_inventory_reservations r where r.sales_order_id=sale_id and r.item_id=v_item_id)<>3 then raise exception 'reservation quantity incorrect'; end if;
  if public.operational_fulfill_sales_order(v_tenant_id,sale_id,'a5700000-0000-4000-8000-000000000004')<>'fulfilled' then raise exception 'fulfilment failed'; end if;
  if public.operational_fulfill_sales_order(v_tenant_id,sale_id,'a5700000-0000-4000-8000-000000000004')<>'fulfilled' then raise exception 'fulfilment replay failed'; end if;
  select r.fulfilled_movement_id into delivered_movement from public.sales_order_inventory_reservations r where r.sales_order_id=sale_id and r.item_id=v_item_id;
  if (select b.quantity from public.inventory_balances b where b.tenant_id=v_tenant_id and b.branch_id=v_branch_id and b.item_id=v_item_id)<>7 or (select b.stock_value from public.inventory_balances b where b.tenant_id=v_tenant_id and b.branch_id=v_branch_id and b.item_id=v_item_id)<>70 or (select m.unit_cost_applied from public.inventory_movements m where m.id=delivered_movement)<>10 then raise exception 'delivery valuation incorrect'; end if;
  if public.operational_return_sales_order_inventory(v_tenant_id,sale_id,'Customer returned material','a5700000-0000-4000-8000-000000000005')<>'returned' then raise exception 'return failed'; end if;
  if public.operational_return_sales_order_inventory(v_tenant_id,sale_id,'Customer returned material','a5700000-0000-4000-8000-000000000005')<>'returned' then raise exception 'return replay failed'; end if;
  if (select b.quantity from public.inventory_balances b where b.tenant_id=v_tenant_id and b.branch_id=v_branch_id and b.item_id=v_item_id)<>10 or (select b.stock_value from public.inventory_balances b where b.tenant_id=v_tenant_id and b.branch_id=v_branch_id and b.item_id=v_item_id)<>100 then raise exception 'return did not restore immutable delivered value'; end if;
  begin perform public.operational_return_sales_order_inventory(v_tenant_id,sale_id,'Different reason','a5700000-0000-4000-8000-000000000005'); raise exception 'divergent return replay accepted'; exception when unique_violation then null; end;
  if not exists(select 1 from public.inventory_movements m where m.id=delivered_movement and m.movement_type='sales_delivery') or not exists(select 1 from public.inventory_movements m where m.tenant_id=v_tenant_id and m.movement_type='sales_return') or exists(select 1 from public.inventory_movements m where m.tenant_id=v_tenant_id and m.movement_type in ('purchase_receipt','purchase_receipt_reversal')) then raise exception 'stock ledger facts incorrect'; end if;
  if exists(select 1 from public.inventory_movements m where m.tenant_id=v_tenant_id and m.source_document_id=sale_id and m.movement_type='sales_delivery' group by m.item_id having count(*)<>1) then raise exception 'duplicate delivery movement'; end if;
  select public.operational_create_sales_order(v_tenant_id,v_branch_id,v_customer_id,'Phase 05 release',jsonb_build_array(jsonb_build_object('item_id',v_item_id,'quantity',2,'unit_price',20,'discount_percent',0)),'a5700000-0000-4000-8000-000000000006') into released_sale_id;
  perform public.operational_decide_sales_order(v_tenant_id,released_sale_id,'confirmed','Test release','a5700000-0000-4000-8000-000000000007');
  if public.operational_reserve_sales_order_inventory(v_tenant_id,released_sale_id,'a5700000-0000-4000-8000-000000000008')<>'reserved' then raise exception 'release reservation failed'; end if;
  if public.operational_release_sales_order_inventory(v_tenant_id,released_sale_id,'Customer cancelled before delivery','a5700000-0000-4000-8000-000000000009')<>'released' then raise exception 'reservation release failed'; end if;
  if public.operational_release_sales_order_inventory(v_tenant_id,released_sale_id,'Customer cancelled before delivery','a5700000-0000-4000-8000-000000000009')<>'released' then raise exception 'reservation release replay failed'; end if;
  begin perform public.operational_release_sales_order_inventory(v_tenant_id,released_sale_id,'Different cancellation reason','a5700000-0000-4000-8000-000000000009'); raise exception 'divergent release replay accepted'; exception when unique_violation then null; end;
  if (select status from public.sales_orders where id=released_sale_id)<>'cancelled' or exists(select 1 from public.inventory_movements where tenant_id=v_tenant_id and source_document_id=released_sale_id) or (select b.quantity from public.inventory_balances b where b.tenant_id=v_tenant_id and b.branch_id=v_branch_id and b.item_id=v_item_id)<>10 then raise exception 'reservation release changed stock or order state incorrectly'; end if;
end;
$test$;

do $security$
begin
  if not (select relrowsecurity and relforcerowsecurity from pg_class where oid='public.sales_order_inventory_reservations'::regclass) or has_table_privilege('authenticated','public.sales_order_inventory_reservations','select') or has_function_privilege('anon','public.operational_fulfill_sales_order(uuid,uuid,uuid)','execute') or has_function_privilege('service_role','public.operational_return_sales_order_inventory(uuid,uuid,text,uuid)','execute') then raise exception 'sales inventory RLS or ACL hardening failed'; end if;
end;
$security$;

rollback;
