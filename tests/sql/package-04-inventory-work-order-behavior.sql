begin;

-- The compact compatibility harness deliberately starts permissive; replace
-- only these helpers so Package 04 proves membership, branch and grant gates.
create or replace function app_private.is_active_company_member(p_tenant_id uuid) returns boolean language sql stable security definer set search_path='' set row_security=off as $$
  select exists(select 1 from public.company_memberships m join public.companies c on c.id=m.tenant_id where m.tenant_id=p_tenant_id and m.user_id=auth.uid() and m.status='active' and c.status='active')
$$;
create or replace function app_private.can_access_branch(p_tenant_id uuid,p_branch_id uuid) returns boolean language sql stable security definer set search_path='' set row_security=off as $$
  select exists(select 1 from public.company_memberships m join public.branches b on b.tenant_id=m.tenant_id and b.id=p_branch_id where m.tenant_id=p_tenant_id and m.user_id=auth.uid() and m.status='active' and (m.branch_access_mode='all_branches' or exists(select 1 from public.branch_access a where a.tenant_id=m.tenant_id and a.membership_id=m.id and a.branch_id=b.id and a.status='active')))
$$;
create or replace function app_private.has_tenant_permission(p_tenant_id uuid,p_permission_key text,p_branch_id uuid default null) returns boolean language sql stable security definer set search_path='' set row_security=off as $$
  select exists(select 1 from public.company_memberships m join public.membership_role_assignments a on a.tenant_id=m.tenant_id and a.membership_id=m.id join public.access_role_definitions r on r.role_key=a.role_key and r.approval_state='approved' join public.role_permission_grants g on g.role_key=r.role_key join public.permission_definitions p on p.permission_key=g.permission_key and p.approval_state='approved' where m.tenant_id=p_tenant_id and m.user_id=auth.uid() and m.status='active' and g.permission_key=p_permission_key and ((r.scope='company' and a.branch_id is null) or (r.scope='branch' and p_branch_id is not null and a.branch_id=p_branch_id)) and (p_branch_id is null or app_private.can_access_branch(p_tenant_id,p_branch_id)))
$$;

do $setup$
declare
  tenant_a constant uuid := '91000000-0000-4000-8000-000000000001';
  tenant_b constant uuid := '91000000-0000-4000-8000-000000000002';
  branch_a constant uuid := '92000000-0000-4000-8000-000000000001';
  branch_b constant uuid := '92000000-0000-4000-8000-000000000002';
  actor constant uuid := '93000000-0000-4000-8000-000000000001';
  membership uuid := '94000000-0000-4000-8000-000000000001';
begin
  insert into auth.users(id,email,email_confirmed_at) values(actor,'package04@example.test',clock_timestamp());
  insert into public.companies(id,legal_name,status) values(tenant_a,'Package 04 A','active'),(tenant_b,'Package 04 B','active');
  insert into public.branches(id,tenant_id,code,name,status) values(branch_a,tenant_a,'001','Origin','active'),(branch_b,tenant_a,'002','Destination','active');
  insert into public.company_memberships(id,tenant_id,user_id,status,branch_access_mode,created_by_user_id) values(membership,tenant_a,actor,'active','all_branches',actor);
  insert into public.access_role_definitions(role_key,display_name,scope,approval_state) values('package04_role','Package 04 role','company','approved');
  insert into public.membership_role_assignments(tenant_id,membership_id,role_key,branch_id,assigned_by_user_id) values(tenant_a,membership,'package04_role',null,actor);
  update public.permission_definitions set approval_state='approved' where permission_key in ('transaction.inventory.stock.move','transaction.inventory.balance.read','transaction.inventory.history.read','transaction.inventory.transfer','transaction.inventory.physical.create','transaction.inventory.physical.count','transaction.inventory.physical.adjust','transaction.service_order.create','transaction.service_order.update','transaction.service_order.read','transaction.service_order.close');
  insert into public.role_permission_grants(role_key,permission_key) select 'package04_role',permission_key from public.permission_definitions where permission_key in ('transaction.inventory.stock.move','transaction.inventory.balance.read','transaction.inventory.history.read','transaction.inventory.transfer','transaction.inventory.physical.create','transaction.inventory.physical.count','transaction.inventory.physical.adjust','transaction.service_order.create','transaction.service_order.update','transaction.service_order.read','transaction.service_order.close');
  update public.erp_transaction_authorization_catalog set approval_state='approved' where transaction_code in ('MIGO','MB52','MB51','ZTR01','MI01','MI04','MI07','ZOS01','ZOS02','ZOS03','ZOS04');
  insert into public.company_module_availability(tenant_id,module_code,enabled,changed_by_user_id) values(tenant_a,'INV',true,actor),(tenant_a,'SVC',true,actor);
  insert into public.company_transaction_availability(tenant_id,transaction_code,enabled,changed_by_user_id) select tenant_a,transaction_code,true,actor from public.erp_transaction_authorization_catalog where transaction_code in ('MIGO','MB52','MB51','ZTR01','MI01','MI04','MI07','ZOS01','ZOS02','ZOS03','ZOS04');
end;
$setup$;

select set_config('request.jwt.claim.role','authenticated',false);
select set_config('request.jwt.claim.sub','93000000-0000-4000-8000-000000000001',false);

do $behavior$
declare
  tenant_a constant uuid := '91000000-0000-4000-8000-000000000001';
  tenant_b constant uuid := '91000000-0000-4000-8000-000000000002';
  branch_a constant uuid := '92000000-0000-4000-8000-000000000001';
  branch_b constant uuid := '92000000-0000-4000-8000-000000000002';
  product_id uuid := '95000000-0000-4000-8000-000000000001';
  service_id uuid := '95000000-0000-4000-8000-000000000002';
  customer_id uuid := '96000000-0000-4000-8000-000000000001';
  transfer_id uuid; count_id uuid; work_order_id uuid; quantity_a numeric; quantity_b numeric; listed integer;
begin
  insert into public.catalog_items(id,tenant_id,item_type,code,name,unit_of_measure,current_cost,selling_price,minimum_stock,reorder_point,request_id,created_by_user_id) values
    (product_id,tenant_a,'product','P04-PART','Package 04 Part','UN',10,20,2,3,'97000000-0000-4000-8000-000000000001','93000000-0000-4000-8000-000000000001'),
    (service_id,tenant_a,'service','P04-SERVICE','Package 04 Service','UN',0,50,0,0,'97000000-0000-4000-8000-000000000002','93000000-0000-4000-8000-000000000001');
  insert into public.business_parties(id,tenant_id,party_type,legal_name,request_id,created_by_user_id) values(customer_id,tenant_a,'customer','Package 04 Customer','98000000-0000-4000-8000-000000000001','93000000-0000-4000-8000-000000000001');
  perform * from public.operational_record_inventory_movement(tenant_a,branch_a,product_id,'initial',10,'99000000-0000-4000-8000-000000000001','package 04 initial');
  select count(*) into listed from public.operational_list_inventory_balances(tenant_a,branch_a,null,25,0); if listed<>1 then raise exception 'branch-scoped balance listing failed'; end if;
  select public.operational_create_inventory_transfer(tenant_a,branch_a,branch_b,product_id,3,'transfer','99000000-0000-4000-8000-000000000002') into transfer_id;
  if public.operational_create_inventory_transfer(tenant_a,branch_a,branch_b,product_id,3,'retry','99000000-0000-4000-8000-000000000002')<>transfer_id then raise exception 'transfer idempotency failed'; end if;
  select quantity into quantity_a from public.inventory_balances where tenant_id=tenant_a and branch_id=branch_a and item_id=product_id;
  select quantity into quantity_b from public.inventory_balances where tenant_id=tenant_a and branch_id=branch_b and item_id=product_id;
  if quantity_a<>7 or quantity_b<>3 then raise exception 'transfer balances are not atomic'; end if;
  select public.operational_create_inventory_count(tenant_a,branch_b,'count','99000000-0000-4000-8000-000000000003') into count_id;
  perform public.operational_record_inventory_count(tenant_a,count_id,product_id,2);
  if public.operational_post_inventory_count(tenant_a,count_id)<>'posted' then raise exception 'inventory count was not posted'; end if;
  select quantity into quantity_b from public.inventory_balances where tenant_id=tenant_a and branch_id=branch_b and item_id=product_id;
  if quantity_b<>2 then raise exception 'physical count did not apply negative adjustment'; end if;
  select public.operational_create_work_order(tenant_a,branch_a,customer_id,'Vehicle','Noise diagnosis','99000000-0000-4000-8000-000000000004') into work_order_id;
  perform public.operational_update_work_order(tenant_a,work_order_id,'Confirmed',jsonb_build_array(jsonb_build_object('line_type','service','item_id',service_id,'quantity',1,'unit_price',50,'discount_amount',0),jsonb_build_object('line_type','part','item_id',product_id,'quantity',2,'unit_price',20,'discount_amount',0)),'99000000-0000-4000-8000-000000000005');
  perform public.operational_update_work_order(tenant_a,work_order_id,'Ignored retry',jsonb_build_array(jsonb_build_object('line_type','service','item_id',service_id,'quantity',1,'unit_price',1,'discount_amount',0)),'99000000-0000-4000-8000-000000000005');
  if public.operational_reserve_work_order_parts(tenant_a,work_order_id)<>'reserved' then raise exception 'work order reservation failed'; end if;
  if public.operational_close_work_order(tenant_a,work_order_id)<>'closed' then raise exception 'work order close failed'; end if;
  select quantity into quantity_a from public.inventory_balances where tenant_id=tenant_a and branch_id=branch_a and item_id=product_id;
  if quantity_a<>5 then raise exception 'work order consumed inventory more than once or not at all'; end if;
  if public.operational_reverse_work_order_consumption(tenant_a,work_order_id)<>'reversed' then raise exception 'work order reversal failed'; end if;
  if public.operational_reverse_work_order_consumption(tenant_a,work_order_id)<>'reversed' then raise exception 'work order reversal is not idempotent'; end if;
  select quantity into quantity_a from public.inventory_balances where tenant_id=tenant_a and branch_id=branch_a and item_id=product_id;
  if quantity_a<>7 then raise exception 'work order reversal did not restore inventory'; end if;
  select count(*) into listed from public.operational_list_work_orders(tenant_a,branch_a,null,25,0); if listed<>1 then raise exception 'work order listing is not branch scoped'; end if;
  begin perform public.operational_create_work_order(tenant_b,branch_a,customer_id,null,'Denied','99000000-0000-4000-8000-000000000006'); raise exception 'cross-company work order accepted'; exception when insufficient_privilege then null; end;
end;
$behavior$;

do $security$
begin
  if exists(select 1 from pg_class where oid in ('public.inventory_transfers'::regclass,'public.inventory_count_sessions'::regclass,'public.inventory_count_lines'::regclass,'public.work_orders'::regclass,'public.work_order_lines'::regclass,'public.work_order_part_reservations'::regclass,'public.work_order_events'::regclass) and (not relrowsecurity or not relforcerowsecurity)) then raise exception 'Package 04 table lost FORCE RLS'; end if;
  if has_function_privilege('anon','public.operational_create_work_order(uuid,uuid,uuid,text,text,uuid)','execute') or has_function_privilege('service_role','public.operational_create_inventory_transfer(uuid,uuid,uuid,uuid,numeric,text,uuid)','execute') then raise exception 'Package 04 broad RPC grant detected'; end if;
end;
$security$;
rollback;
