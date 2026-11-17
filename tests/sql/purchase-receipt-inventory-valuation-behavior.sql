begin;

-- Isolated tenant: proves the receipt workflow does not inherit permissions or
-- availability from earlier package tests.
do $setup$
declare
  tenant_id constant uuid := 'f1000000-0000-4000-8000-000000000001';
  branch_id constant uuid := 'f2000000-0000-4000-8000-000000000001';
  actor_id constant uuid := 'f3000000-0000-4000-8000-000000000001';
  membership_id constant uuid := 'f4000000-0000-4000-8000-000000000001';
begin
  insert into auth.users(id,email,email_confirmed_at) values(actor_id,'phase01@example.test',clock_timestamp());
  insert into public.companies(id,legal_name,status) values(tenant_id,'Phase 01 Test Company','active');
  insert into public.branches(id,tenant_id,code,name,status) values(branch_id,tenant_id,'001','Phase 01 Main','active');
  insert into public.company_memberships(id,tenant_id,user_id,status,branch_access_mode,created_by_user_id) values(membership_id,tenant_id,actor_id,'active','all_branches',actor_id);
  insert into public.access_role_definitions(role_key,display_name,scope,approval_state) values('phase01_role','Phase 01 role','company','approved');
  insert into public.membership_role_assignments(tenant_id,membership_id,role_key,branch_id,assigned_by_user_id) values(tenant_id,membership_id,'phase01_role',null,actor_id);
  update public.permission_definitions set approval_state='approved' where permission_key in ('transaction.inventory.stock.move','transaction.purchasing.purchase_order.create','transaction.purchasing.purchase_order.read','transaction.purchasing.receipt.manage','transaction.inventory.valuation.initial');
  insert into public.role_permission_grants(role_key,permission_key)
    select 'phase01_role',permission_key from public.permission_definitions where permission_key in ('transaction.inventory.stock.move','transaction.purchasing.purchase_order.create','transaction.purchasing.purchase_order.read','transaction.purchasing.receipt.manage','transaction.inventory.valuation.initial');
  update public.erp_transaction_authorization_catalog set approval_state='approved' where transaction_code in ('MIGO','ME21N','ME23N','ZGR01','ZIV01');
  insert into public.company_module_availability(tenant_id,module_code,enabled,changed_by_user_id) values(tenant_id,'INV',true,actor_id),(tenant_id,'PUR',true,actor_id);
  insert into public.company_transaction_availability(tenant_id,transaction_code,enabled,changed_by_user_id)
    select tenant_id,transaction_code,true,actor_id from public.erp_transaction_authorization_catalog where transaction_code in ('MIGO','ME21N','ME23N','ZGR01','ZIV01');
end;
$setup$;

select set_config('request.jwt.claim.role','authenticated',false);
select set_config('request.jwt.claim.sub','f3000000-0000-4000-8000-000000000001',false);

do $receipt$
<<receipt>>
declare
  tenant_id constant uuid := 'f1000000-0000-4000-8000-000000000001';
  branch_id constant uuid := 'f2000000-0000-4000-8000-000000000001';
  actor_id constant uuid := 'f3000000-0000-4000-8000-000000000001';
  product_id uuid := 'f5000000-0000-4000-8000-000000000001';
  supplier_id uuid := 'f6000000-0000-4000-8000-000000000001';
  order_id uuid; order_item_id uuid; receipt_one uuid; receipt_two uuid; same_receipt uuid;
  stock_quantity numeric; stock_value numeric; average_cost numeric; state text;
begin
  insert into public.catalog_items(id,tenant_id,item_type,code,name,unit_of_measure,current_cost,selling_price,minimum_stock,reorder_point,request_id,created_by_user_id)
    values(product_id,tenant_id,'product','PHASE01-P','Phase 01 Product','UN',0,20,0,0,'f7000000-0000-4000-8000-000000000001',actor_id);
  insert into public.business_parties(id,tenant_id,party_type,legal_name,request_id,created_by_user_id)
    values(supplier_id,tenant_id,'supplier','Phase 01 Supplier','f7000000-0000-4000-8000-000000000002',actor_id);
  select public.operational_create_purchase_order(tenant_id,branch_id,supplier_id,jsonb_build_array(jsonb_build_object('item_id',product_id,'quantity',10,'unit_price',10)),'Phase 01 order','f7000000-0000-4000-8000-000000000003') into order_id;
  if public.operational_submit_purchase_order(tenant_id,order_id,'f7000000-0000-4000-8000-000000000004') <> 'submitted' then raise exception 'purchase order was not submitted'; end if;
  select id into order_item_id from public.purchase_order_items where purchase_order_id=receipt.order_id;
  select public.operational_receive_purchase_order(tenant_id,order_id,jsonb_build_array(jsonb_build_object('purchase_order_item_id',order_item_id,'quantity',4,'effective_unit_cost',10)),'NF-1','partial','f7000000-0000-4000-8000-000000000005') into receipt_one;
  select public.operational_receive_purchase_order(tenant_id,order_id,jsonb_build_array(jsonb_build_object('purchase_order_item_id',order_item_id,'quantity',4,'effective_unit_cost',10)),'NF-1','partial','f7000000-0000-4000-8000-000000000005') into same_receipt;
  if receipt_one<>same_receipt then raise exception 'receipt request was not idempotent'; end if;
  select status into state from public.purchase_orders where id=order_id; if state<>'partially_received' then raise exception 'partial receipt status was not stored'; end if;
  begin
    perform public.operational_receive_purchase_order(tenant_id,order_id,jsonb_build_array(jsonb_build_object('purchase_order_item_id',order_item_id,'quantity',7,'effective_unit_cost',10)),'NF-over','over','f7000000-0000-4000-8000-000000000006');
    raise exception 'over-receipt was accepted';
  exception when check_violation then null;
  end;
  begin
    perform public.operational_receive_purchase_order(tenant_id,order_id,jsonb_build_array(jsonb_build_object('purchase_order_item_id',order_item_id,'quantity',6,'effective_unit_cost',14)),'NF-2','missing variance','f7000000-0000-4000-8000-000000000007');
    raise exception 'unjustified variance was accepted';
  exception when invalid_parameter_value then null;
  end;
  select public.operational_receive_purchase_order(tenant_id,order_id,jsonb_build_array(jsonb_build_object('purchase_order_item_id',order_item_id,'quantity',6,'effective_unit_cost',14,'variance_reason','Frete adicional confirmado')),'NF-2','complete','f7000000-0000-4000-8000-000000000008') into receipt_two;
  select balance.quantity,balance.stock_value,balance.average_unit_cost into stock_quantity,stock_value,average_cost from public.inventory_balances balance where balance.tenant_id=receipt.tenant_id and balance.branch_id=receipt.branch_id and balance.item_id=receipt.product_id;
  if stock_quantity<>10 or stock_value<>124 or average_cost<>12.4 then raise exception 'moving average receipt valuation failed: %, %, %',stock_quantity,stock_value,average_cost; end if;
  select status into state from public.purchase_orders where id=receipt.order_id; if state<>'received' then raise exception 'completed receipt did not close order'; end if;
  begin
    perform public.operational_reverse_purchase_receipt(tenant_id,receipt_one,jsonb_build_array(jsonb_build_object('purchase_receipt_item_id',(select id from public.purchase_receipt_items where purchase_receipt_id=receipt_one),'quantity',5)),'invalid quantity','f7000000-0000-4000-8000-000000000009');
    raise exception 'over-reversal was accepted';
  exception when check_violation then null;
  end;
  perform public.operational_reverse_purchase_receipt(tenant_id,receipt_one,jsonb_build_array(jsonb_build_object('purchase_receipt_item_id',(select id from public.purchase_receipt_items where purchase_receipt_id=receipt_one),'quantity',4)),'supplier return','f7000000-0000-4000-8000-000000000010');
  select balance.quantity,balance.stock_value into stock_quantity,stock_value from public.inventory_balances balance where balance.tenant_id=receipt.tenant_id and balance.branch_id=receipt.branch_id and balance.item_id=receipt.product_id;
  if stock_quantity<>6 or stock_value<>84 then raise exception 'receipt reversal did not preserve audit value: %, %',stock_quantity,stock_value; end if;
  perform public.operational_reverse_purchase_receipt(tenant_id,receipt_two,jsonb_build_array(jsonb_build_object('purchase_receipt_item_id',(select id from public.purchase_receipt_items where purchase_receipt_id=receipt_two),'quantity',1)),'partial supplier return','f7000000-0000-4000-8000-000000000011');
  select balance.quantity,balance.stock_value into stock_quantity,stock_value from public.inventory_balances balance where balance.tenant_id=receipt.tenant_id and balance.branch_id=receipt.branch_id and balance.item_id=receipt.product_id;
  if stock_quantity<>5 or stock_value<>70 then raise exception 'partial receipt reversal did not preserve audit value: %, %',stock_quantity,stock_value; end if;
  select status into state from public.purchase_receipts where id=receipt_two; if state<>'partially_reversed' then raise exception 'partial receipt reversal state was not stored'; end if;
  if not exists(select 1 from app_private.operational_audit_events audit_event where audit_event.tenant_id=receipt.tenant_id and audit_event.event_key in ('purchase_receipt.created','purchase_receipt.reversed')) then raise exception 'receipt audit events are missing'; end if;
end;
$receipt$;

-- D05 is intentionally conservative: without lot-level provenance, a later
-- outbound movement or an active reservation means the receipt's quantity and
-- historical value cannot be identified safely.  These are business rejections
-- (55000), not retries or silent compensating movements.
do $d05_traceability$
<<d05_traceability>>
declare
  tenant_id constant uuid := 'f1000000-0000-4000-8000-000000000001';
  branch_id constant uuid := 'f2000000-0000-4000-8000-000000000001';
  branch_two_id constant uuid := 'f2000000-0000-4000-8000-000000000002';
  actor_id constant uuid := 'f3000000-0000-4000-8000-000000000001';
  supplier_id constant uuid := 'f6000000-0000-4000-8000-000000000001';
  customer_id constant uuid := 'f6000000-0000-4000-8000-000000000002';
  item_outbound uuid := 'f5000000-0000-4000-8000-000000000003';
  item_transfer uuid := 'f5000000-0000-4000-8000-000000000004';
  item_reservation uuid := 'f5000000-0000-4000-8000-000000000005';
  item_partial uuid := 'f5000000-0000-4000-8000-000000000006';
  order_id uuid; order_item_id uuid; receipt_id uuid; receipt_item_id uuid; work_order_id uuid;
  stock_quantity numeric; stock_value numeric;
begin
  update public.permission_definitions set approval_state='approved' where permission_key in ('transaction.inventory.transfer','transaction.service_order.create','transaction.service_order.update');
  insert into public.role_permission_grants(role_key,permission_key)
    select 'phase01_role',permission_key from public.permission_definitions where permission_key in ('transaction.inventory.transfer','transaction.service_order.create','transaction.service_order.update') on conflict do nothing;
  update public.erp_transaction_authorization_catalog set approval_state='approved' where transaction_code in ('ZTR01','ZOS01','ZOS02');
  insert into public.company_transaction_availability(tenant_id,transaction_code,enabled,changed_by_user_id)
    select d05_traceability.tenant_id,catalog.transaction_code,true,d05_traceability.actor_id from public.erp_transaction_authorization_catalog catalog where catalog.transaction_code in ('ZTR01','ZOS01','ZOS02') on conflict on constraint company_transaction_availability_pkey do update set enabled=true;
  insert into public.company_module_availability(tenant_id,module_code,enabled,changed_by_user_id) values(d05_traceability.tenant_id,'SVC',true,d05_traceability.actor_id) on conflict on constraint company_module_availability_pkey do update set enabled=true;
  insert into public.branches(id,tenant_id,code,name,status) values(branch_two_id,tenant_id,'002','Phase 01 D05 Destination','active');
  insert into public.business_parties(id,tenant_id,party_type,legal_name,request_id,created_by_user_id) values(customer_id,tenant_id,'customer','Phase 01 D05 Customer','f7000000-0000-4000-8000-000000000101',actor_id);
  insert into public.catalog_items(id,tenant_id,item_type,code,name,unit_of_measure,current_cost,selling_price,minimum_stock,reorder_point,request_id,created_by_user_id)
  values
    (item_outbound,tenant_id,'product','D05-OUT','D05 outbound','UN',0,20,0,0,'f7000000-0000-4000-8000-000000000102',actor_id),
    (item_transfer,tenant_id,'product','D05-TRF','D05 transfer','UN',0,20,0,0,'f7000000-0000-4000-8000-000000000103',actor_id),
    (item_reservation,tenant_id,'product','D05-RES','D05 reservation','UN',0,20,0,0,'f7000000-0000-4000-8000-000000000104',actor_id),
    (item_partial,tenant_id,'product','D05-PART','D05 partial','UN',0,20,0,0,'f7000000-0000-4000-8000-000000000105',actor_id);

  -- A later outbound movement, including after a changed moving-average inbound,
  -- blocks reversal rather than rewriting its historical cost.
  select public.operational_create_purchase_order(tenant_id,branch_id,supplier_id,jsonb_build_array(jsonb_build_object('item_id',item_outbound,'quantity',12,'unit_price',10)),'D05 outbound','f7000000-0000-4000-8000-000000000110') into order_id;
  perform public.operational_submit_purchase_order(tenant_id,order_id,'f7000000-0000-4000-8000-000000000111');
  select id into order_item_id from public.purchase_order_items where purchase_order_id=order_id;
  select public.operational_receive_purchase_order(tenant_id,order_id,jsonb_build_array(jsonb_build_object('purchase_order_item_id',order_item_id,'quantity',10,'effective_unit_cost',10)),'D05-OUT-1','base','f7000000-0000-4000-8000-000000000112') into receipt_id;
  select id into receipt_item_id from public.purchase_receipt_items where purchase_receipt_id=receipt_id;
  perform public.operational_record_inventory_movement_valued(tenant_id,branch_id,item_outbound,'entry',2,14,'f7000000-0000-4000-8000-000000000113','later cost-changing inbound');
  perform public.operational_record_inventory_movement_valued(tenant_id,branch_id,item_outbound,'exit',1,null,'f7000000-0000-4000-8000-000000000114','later outbound');
  begin
    perform public.operational_reverse_purchase_receipt(tenant_id,receipt_id,jsonb_build_array(jsonb_build_object('purchase_receipt_item_id',receipt_item_id,'quantity',1)),'blocked after outbound','f7000000-0000-4000-8000-000000000115');
    raise exception 'D05 accepted reversal after later outbound';
  exception when object_not_in_prerequisite_state then null;
  end;

  -- Transfers are outbound facts, even though their value is preserved across
  -- branches; without lots the origin receipt remains ambiguous.
  select public.operational_create_purchase_order(tenant_id,branch_id,supplier_id,jsonb_build_array(jsonb_build_object('item_id',item_transfer,'quantity',10,'unit_price',10)),'D05 transfer','f7000000-0000-4000-8000-000000000120') into order_id;
  perform public.operational_submit_purchase_order(tenant_id,order_id,'f7000000-0000-4000-8000-000000000121');
  select id into order_item_id from public.purchase_order_items where purchase_order_id=order_id;
  select public.operational_receive_purchase_order(tenant_id,order_id,jsonb_build_array(jsonb_build_object('purchase_order_item_id',order_item_id,'quantity',10,'effective_unit_cost',10)),'D05-TRF-1','base','f7000000-0000-4000-8000-000000000122') into receipt_id;
  select id into receipt_item_id from public.purchase_receipt_items where purchase_receipt_id=receipt_id;
  perform public.operational_create_inventory_transfer(tenant_id,branch_id,branch_two_id,item_transfer,1,'later transfer','f7000000-0000-4000-8000-000000000123');
  begin
    perform public.operational_reverse_purchase_receipt(tenant_id,receipt_id,jsonb_build_array(jsonb_build_object('purchase_receipt_item_id',receipt_item_id,'quantity',1)),'blocked after transfer','f7000000-0000-4000-8000-000000000124');
    raise exception 'D05 accepted reversal after transfer';
  exception when object_not_in_prerequisite_state then null;
  end;

  -- An active O.S. reservation is blocked before it can be silently invalidated.
  select public.operational_create_purchase_order(tenant_id,branch_id,supplier_id,jsonb_build_array(jsonb_build_object('item_id',item_reservation,'quantity',10,'unit_price',10)),'D05 reservation','f7000000-0000-4000-8000-000000000130') into order_id;
  perform public.operational_submit_purchase_order(tenant_id,order_id,'f7000000-0000-4000-8000-000000000131');
  select id into order_item_id from public.purchase_order_items where purchase_order_id=order_id;
  select public.operational_receive_purchase_order(tenant_id,order_id,jsonb_build_array(jsonb_build_object('purchase_order_item_id',order_item_id,'quantity',10,'effective_unit_cost',10)),'D05-RES-1','base','f7000000-0000-4000-8000-000000000132') into receipt_id;
  select id into receipt_item_id from public.purchase_receipt_items where purchase_receipt_id=receipt_id;
  select public.operational_create_work_order(tenant_id,branch_id,customer_id,null,'D05 reservation test','f7000000-0000-4000-8000-000000000133') into work_order_id;
  perform public.operational_update_work_order(tenant_id,work_order_id,'',jsonb_build_array(jsonb_build_object('line_type','part','item_id',item_reservation,'quantity',1,'unit_price',20,'discount_amount',0)),'f7000000-0000-4000-8000-000000000134');
  perform public.operational_reserve_work_order_parts(tenant_id,work_order_id);
  begin
    perform public.operational_reverse_purchase_receipt(tenant_id,receipt_id,jsonb_build_array(jsonb_build_object('purchase_receipt_item_id',receipt_item_id,'quantity',1)),'blocked by reservation','f7000000-0000-4000-8000-000000000135');
    raise exception 'D05 accepted reversal with active reservation';
  exception when object_not_in_prerequisite_state then null;
  end;

  -- In the absence of later outbound facts, partial reversals retain their
  -- original cost and may be repeated up to the received quantity.
  select public.operational_create_purchase_order(tenant_id,branch_id,supplier_id,jsonb_build_array(jsonb_build_object('item_id',item_partial,'quantity',10,'unit_price',10)),'D05 partial','f7000000-0000-4000-8000-000000000140') into order_id;
  perform public.operational_submit_purchase_order(tenant_id,order_id,'f7000000-0000-4000-8000-000000000141');
  select id into order_item_id from public.purchase_order_items where purchase_order_id=order_id;
  select public.operational_receive_purchase_order(tenant_id,order_id,jsonb_build_array(jsonb_build_object('purchase_order_item_id',order_item_id,'quantity',10,'effective_unit_cost',10)),'D05-PART-1','base','f7000000-0000-4000-8000-000000000142') into receipt_id;
  select id into receipt_item_id from public.purchase_receipt_items where purchase_receipt_id=receipt_id;
  perform public.operational_reverse_purchase_receipt(tenant_id,receipt_id,jsonb_build_array(jsonb_build_object('purchase_receipt_item_id',receipt_item_id,'quantity',2)),'partial one','f7000000-0000-4000-8000-000000000143');
  perform public.operational_reverse_purchase_receipt(tenant_id,receipt_id,jsonb_build_array(jsonb_build_object('purchase_receipt_item_id',receipt_item_id,'quantity',2)),'partial two','f7000000-0000-4000-8000-000000000144');
  select balance.quantity,balance.stock_value into stock_quantity,stock_value from public.inventory_balances balance where balance.tenant_id=d05_traceability.tenant_id and balance.branch_id=d05_traceability.branch_id and balance.item_id=d05_traceability.item_partial;
  if stock_quantity<>6 or stock_value<>60 then raise exception 'D05 repeated partial reversal valuation failed: %, %',stock_quantity,stock_value; end if;
  begin
    perform public.operational_reverse_purchase_receipt(tenant_id,receipt_id,jsonb_build_array(jsonb_build_object('purchase_receipt_item_id',receipt_item_id,'quantity',1)),'partial two','f7000000-0000-4000-8000-000000000144');
    raise exception 'D05 accepted a request id with a different reversal payload';
  exception when unique_violation then null;
  end;
end;
$d05_traceability$;

do $legacy_and_security$
<<legacy_and_security>>
declare
  tenant_id constant uuid := 'f1000000-0000-4000-8000-000000000001';
  branch_id constant uuid := 'f2000000-0000-4000-8000-000000000001';
  actor_id constant uuid := 'f3000000-0000-4000-8000-000000000001';
  legacy_item uuid := 'f5000000-0000-4000-8000-000000000002';
  event_one uuid; event_two uuid; value_after numeric;
begin
  insert into public.catalog_items(id,tenant_id,item_type,code,name,unit_of_measure,current_cost,selling_price,minimum_stock,reorder_point,request_id,created_by_user_id)
    values(legacy_item,tenant_id,'product','PHASE01-LEGACY','Legacy Product','UN',0,20,0,0,'f7000000-0000-4000-8000-000000000012',actor_id);
  insert into public.inventory_balances(tenant_id,branch_id,item_id,quantity) values(tenant_id,branch_id,legacy_item,3);
  begin
    perform public.operational_record_inventory_movement_valued(tenant_id,branch_id,legacy_item,'exit',1,null,'f7000000-0000-4000-8000-000000000013','blocked pending valuation');
    raise exception 'legacy pending valuation allowed outbound movement';
  exception when object_not_in_prerequisite_state then null;
  end;
  select public.operational_record_initial_inventory_valuation(tenant_id,branch_id,legacy_item,7,'Opening balance verified','f7000000-0000-4000-8000-000000000014') into event_one;
  select public.operational_record_initial_inventory_valuation(tenant_id,branch_id,legacy_item,7,'Opening balance verified','f7000000-0000-4000-8000-000000000014') into event_two;
  if event_one<>event_two then raise exception 'initial valuation was not idempotent'; end if;
  select balance.stock_value into value_after from public.inventory_balances balance where balance.tenant_id=legacy_and_security.tenant_id and balance.branch_id=legacy_and_security.branch_id and balance.item_id=legacy_and_security.legacy_item;
  if value_after<>21 then raise exception 'initial valuation did not value legacy balance'; end if;
  begin
    perform public.operational_list_purchase_receiving('f1000000-0000-4000-8000-000000000099',branch_id,1,0);
    raise exception 'cross-tenant receipt read was accepted';
  exception when insufficient_privilege then null;
  end;
  if has_function_privilege('anon','public.operational_receive_purchase_order(uuid,uuid,jsonb,text,text,uuid)','execute') or has_function_privilege('service_role','public.operational_receive_purchase_order(uuid,uuid,jsonb,text,text,uuid)','execute') then raise exception 'broad receipt RPC grant detected'; end if;
end;
$legacy_and_security$;

rollback;
