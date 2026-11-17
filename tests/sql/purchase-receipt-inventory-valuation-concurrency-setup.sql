-- Persistent fixtures for real, cross-session Phase 01 concurrency tests.
-- This file is executed only inside the disposable PostgreSQL container.

begin;

insert into auth.users(id,email,email_confirmed_at) values
  ('ca300000-0000-4000-8000-000000000001','phase01-concurrency@example.test',clock_timestamp());
insert into public.companies(id,legal_name,status)
  values ('ca100000-0000-4000-8000-000000000001','Phase 01 Concurrency Company','active');
insert into public.branches(id,tenant_id,code,name,status) values
  ('ca200000-0000-4000-8000-000000000001','ca100000-0000-4000-8000-000000000001','001','Origin','active'),
  ('ca200000-0000-4000-8000-000000000002','ca100000-0000-4000-8000-000000000001','002','Destination','active');
insert into public.company_memberships(id,tenant_id,user_id,status,branch_access_mode,created_by_user_id)
  values ('ca400000-0000-4000-8000-000000000001','ca100000-0000-4000-8000-000000000001','ca300000-0000-4000-8000-000000000001','active','all_branches','ca300000-0000-4000-8000-000000000001');
insert into public.access_role_definitions(role_key,display_name,scope,approval_state)
  values ('phase01_concurrency_role','Phase 01 concurrency role','company','approved');
insert into public.membership_role_assignments(tenant_id,membership_id,role_key,branch_id,assigned_by_user_id)
  values ('ca100000-0000-4000-8000-000000000001','ca400000-0000-4000-8000-000000000001','phase01_concurrency_role',null,'ca300000-0000-4000-8000-000000000001');

update public.permission_definitions set approval_state='approved' where permission_key in (
  'transaction.inventory.stock.move','transaction.inventory.transfer',
  'transaction.inventory.physical.create','transaction.inventory.physical.count','transaction.inventory.physical.adjust',
  'transaction.service_order.create','transaction.service_order.update','transaction.service_order.close',
  'transaction.purchasing.purchase_order.create','transaction.purchasing.purchase_order.read',
  'transaction.purchasing.receipt.manage'
);
insert into public.role_permission_grants(role_key,permission_key)
  select 'phase01_concurrency_role',permission_key from public.permission_definitions where permission_key in (
    'transaction.inventory.stock.move','transaction.inventory.transfer',
    'transaction.inventory.physical.create','transaction.inventory.physical.count','transaction.inventory.physical.adjust',
    'transaction.service_order.create','transaction.service_order.update','transaction.service_order.close',
    'transaction.purchasing.purchase_order.create','transaction.purchasing.purchase_order.read',
    'transaction.purchasing.receipt.manage'
  ) on conflict do nothing;
update public.erp_transaction_authorization_catalog set approval_state='approved' where transaction_code in
  ('MIGO','ZTR01','MI01','MI04','MI07','ZOS01','ZOS02','ZOS04','ME21N','ME23N','ZGR01');
insert into public.company_module_availability(tenant_id,module_code,enabled,changed_by_user_id) values
  ('ca100000-0000-4000-8000-000000000001','INV',true,'ca300000-0000-4000-8000-000000000001'),
  ('ca100000-0000-4000-8000-000000000001','PUR',true,'ca300000-0000-4000-8000-000000000001'),
  ('ca100000-0000-4000-8000-000000000001','SVC',true,'ca300000-0000-4000-8000-000000000001');
insert into public.company_transaction_availability(tenant_id,transaction_code,enabled,changed_by_user_id)
  select 'ca100000-0000-4000-8000-000000000001',transaction_code,true,'ca300000-0000-4000-8000-000000000001'
  from public.erp_transaction_authorization_catalog
  where transaction_code in ('MIGO','ZTR01','MI01','MI04','MI07','ZOS01','ZOS02','ZOS04','ME21N','ME23N','ZGR01');

insert into public.business_parties(id,tenant_id,party_type,legal_name,request_id,created_by_user_id) values
  ('ca600000-0000-4000-8000-000000000001','ca100000-0000-4000-8000-000000000001','supplier','Phase 01 Concurrency Supplier','ca900000-0000-4000-8000-000000000001','ca300000-0000-4000-8000-000000000001'),
  ('ca600000-0000-4000-8000-000000000002','ca100000-0000-4000-8000-000000000001','customer','Phase 01 Concurrency Customer','ca900000-0000-4000-8000-000000000002','ca300000-0000-4000-8000-000000000001');
insert into public.catalog_items(id,tenant_id,item_type,code,name,unit_of_measure,current_cost,selling_price,minimum_stock,reorder_point,request_id,created_by_user_id)
  select ('ca500000-0000-4000-8000-' || lpad(n::text,12,'0'))::uuid,'ca100000-0000-4000-8000-000000000001','product',format('CONC-%s',n),format('Phase 01 Concurrency Product %s',n),'UN',0,30,0,0,('ca910000-0000-4000-8000-' || lpad(n::text,12,'0'))::uuid,'ca300000-0000-4000-8000-000000000001'
  from generate_series(1,6) n;
insert into public.purchase_orders(id,tenant_id,branch_id,supplier_id,status,notes,total_amount,request_id,created_by_user_id)
  select ('ca700000-0000-4000-8000-' || lpad(n::text,12,'0'))::uuid,'ca100000-0000-4000-8000-000000000001','ca200000-0000-4000-8000-000000000001','ca600000-0000-4000-8000-000000000001','submitted','Phase 01 concurrency',56,('ca920000-0000-4000-8000-' || lpad(n::text,12,'0'))::uuid,'ca300000-0000-4000-8000-000000000001'
  from generate_series(1,6) n;
insert into public.purchase_order_items(id,tenant_id,purchase_order_id,line_number,item_id,quantity,unit_price,line_total)
  select ('ca710000-0000-4000-8000-' || lpad(n::text,12,'0'))::uuid,'ca100000-0000-4000-8000-000000000001',('ca700000-0000-4000-8000-' || lpad(n::text,12,'0'))::uuid,1,('ca500000-0000-4000-8000-' || lpad(n::text,12,'0'))::uuid,4,14,56
  from generate_series(1,6) n;

select set_config('request.jwt.claim.role','authenticated',false);
select set_config('request.jwt.claim.sub','ca300000-0000-4000-8000-000000000001',false);
select public.operational_record_inventory_movement_valued('ca100000-0000-4000-8000-000000000001','ca200000-0000-4000-8000-000000000001',('ca500000-0000-4000-8000-' || lpad(n::text,12,'0'))::uuid,'initial',10,10,('ca930000-0000-4000-8000-' || lpad(n::text,12,'0'))::uuid,'Phase01 concurrency opening') from generate_series(1,6) n;

select public.operational_create_inventory_count('ca100000-0000-4000-8000-000000000001','ca200000-0000-4000-8000-000000000001','Phase01 concurrency count', 'ca940000-0000-4000-8000-000000000001');
select public.operational_create_inventory_count('ca100000-0000-4000-8000-000000000001','ca200000-0000-4000-8000-000000000001','Phase01 concurrency count', 'ca940000-0000-4000-8000-000000000002');
select public.operational_record_inventory_count('ca100000-0000-4000-8000-000000000001',(select id from public.inventory_count_sessions where tenant_id='ca100000-0000-4000-8000-000000000001' and request_id='ca940000-0000-4000-8000-000000000001'),'ca500000-0000-4000-8000-000000000003',8);
select public.operational_record_inventory_count('ca100000-0000-4000-8000-000000000001',(select id from public.inventory_count_sessions where tenant_id='ca100000-0000-4000-8000-000000000001' and request_id='ca940000-0000-4000-8000-000000000002'),'ca500000-0000-4000-8000-000000000004',8);

select public.operational_create_work_order('ca100000-0000-4000-8000-000000000001','ca200000-0000-4000-8000-000000000001','ca600000-0000-4000-8000-000000000002',null,'Phase01 receipt versus O.S.','ca950000-0000-4000-8000-000000000005');
select public.operational_create_work_order('ca100000-0000-4000-8000-000000000001','ca200000-0000-4000-8000-000000000001','ca600000-0000-4000-8000-000000000002',null,'Phase01 O.S. versus receipt','ca950000-0000-4000-8000-000000000006');
select public.operational_update_work_order('ca100000-0000-4000-8000-000000000001',(select id from public.work_orders where tenant_id='ca100000-0000-4000-8000-000000000001' and request_id='ca950000-0000-4000-8000-000000000005'),'','[{"line_type":"part","item_id":"ca500000-0000-4000-8000-000000000005","quantity":3,"unit_price":20,"discount_amount":0}]','ca960000-0000-4000-8000-000000000005');
select public.operational_update_work_order('ca100000-0000-4000-8000-000000000001',(select id from public.work_orders where tenant_id='ca100000-0000-4000-8000-000000000001' and request_id='ca950000-0000-4000-8000-000000000006'),'','[{"line_type":"part","item_id":"ca500000-0000-4000-8000-000000000006","quantity":3,"unit_price":20,"discount_amount":0}]','ca960000-0000-4000-8000-000000000006');
select public.operational_reserve_work_order_parts('ca100000-0000-4000-8000-000000000001',id) from public.work_orders where tenant_id='ca100000-0000-4000-8000-000000000001' and request_id in ('ca950000-0000-4000-8000-000000000005','ca950000-0000-4000-8000-000000000006');

create function app_private.phase01_test_pause_inventory_write() returns trigger language plpgsql set search_path='' as $fn$
begin
  -- The runner observes this backend in pg_stat_activity/PgSleep before it
  -- starts the competing session.  Thus the pause is a synchronization barrier,
  -- not a timing-only approximation of contention.
  if current_setting('phase01.test_pause',true)='on' then perform pg_catalog.pg_sleep(0.75); end if;
  return new;
end;
$fn$;
create trigger phase01_test_pause_inventory_write before insert on public.inventory_movements for each row execute function app_private.phase01_test_pause_inventory_write();

-- Additional fixtures for the hardening scenarios.  They deliberately share
-- stock positions while retaining independent documents, so the runner can
-- demonstrate real advisory-lock contention rather than sequential calls.
insert into public.catalog_items(id,tenant_id,item_type,code,name,unit_of_measure,current_cost,selling_price,minimum_stock,reorder_point,request_id,created_by_user_id)
  select ('ca500000-0000-4000-8000-' || lpad(n::text,12,'0'))::uuid,'ca100000-0000-4000-8000-000000000001','product',format('HARD-%s',n),format('Phase 01 Hardening Product %s',n),'UN',0,30,0,0,('ca970000-0000-4000-8000-' || lpad(n::text,12,'0'))::uuid,'ca300000-0000-4000-8000-000000000001'
  from generate_series(7,13) n;
insert into public.purchase_orders(id,tenant_id,branch_id,supplier_id,status,notes,total_amount,request_id,created_by_user_id) values
  ('ca700000-0000-4000-8000-000000000007','ca100000-0000-4000-8000-000000000001','ca200000-0000-4000-8000-000000000001','ca600000-0000-4000-8000-000000000001','submitted','hard reverse source',40,'ca980000-0000-4000-8000-000000000007','ca300000-0000-4000-8000-000000000001'),
  ('ca700000-0000-4000-8000-000000000008','ca100000-0000-4000-8000-000000000001','ca200000-0000-4000-8000-000000000001','ca600000-0000-4000-8000-000000000001','submitted','hard concurrent receipt',40,'ca980000-0000-4000-8000-000000000008','ca300000-0000-4000-8000-000000000001'),
  ('ca700000-0000-4000-8000-000000000009','ca100000-0000-4000-8000-000000000001','ca200000-0000-4000-8000-000000000001','ca600000-0000-4000-8000-000000000001','submitted','hard transfer source',40,'ca980000-0000-4000-8000-000000000009','ca300000-0000-4000-8000-000000000001'),
  ('ca700000-0000-4000-8000-000000000010','ca100000-0000-4000-8000-000000000001','ca200000-0000-4000-8000-000000000001','ca600000-0000-4000-8000-000000000001','submitted','hard os source',40,'ca980000-0000-4000-8000-000000000010','ca300000-0000-4000-8000-000000000001'),
  ('ca700000-0000-4000-8000-000000000011','ca100000-0000-4000-8000-000000000001','ca200000-0000-4000-8000-000000000001','ca600000-0000-4000-8000-000000000001','submitted','hard multi receipt one',80,'ca980000-0000-4000-8000-000000000011','ca300000-0000-4000-8000-000000000001'),
  ('ca700000-0000-4000-8000-000000000012','ca100000-0000-4000-8000-000000000001','ca200000-0000-4000-8000-000000000001','ca600000-0000-4000-8000-000000000001','submitted','hard multi receipt two',80,'ca980000-0000-4000-8000-000000000012','ca300000-0000-4000-8000-000000000001'),
  ('ca700000-0000-4000-8000-000000000013','ca100000-0000-4000-8000-000000000001','ca200000-0000-4000-8000-000000000001','ca600000-0000-4000-8000-000000000001','submitted','hard multi reversal one',80,'ca980000-0000-4000-8000-000000000013','ca300000-0000-4000-8000-000000000001'),
  ('ca700000-0000-4000-8000-000000000014','ca100000-0000-4000-8000-000000000001','ca200000-0000-4000-8000-000000000001','ca600000-0000-4000-8000-000000000001','submitted','hard multi reversal two',80,'ca980000-0000-4000-8000-000000000014','ca300000-0000-4000-8000-000000000001');
insert into public.purchase_order_items(id,tenant_id,purchase_order_id,line_number,item_id,quantity,unit_price,line_total) values
  ('ca710000-0000-4000-8000-000000000007','ca100000-0000-4000-8000-000000000001','ca700000-0000-4000-8000-000000000007',1,'ca500000-0000-4000-8000-000000000007',4,10,40),
  ('ca710000-0000-4000-8000-000000000008','ca100000-0000-4000-8000-000000000001','ca700000-0000-4000-8000-000000000008',1,'ca500000-0000-4000-8000-000000000007',4,14,56),
  ('ca710000-0000-4000-8000-000000000009','ca100000-0000-4000-8000-000000000001','ca700000-0000-4000-8000-000000000009',1,'ca500000-0000-4000-8000-000000000008',4,10,40),
  ('ca710000-0000-4000-8000-000000000010','ca100000-0000-4000-8000-000000000001','ca700000-0000-4000-8000-000000000010',1,'ca500000-0000-4000-8000-000000000009',4,10,40),
  ('ca710000-0000-4000-8000-000000000011','ca100000-0000-4000-8000-000000000001','ca700000-0000-4000-8000-000000000011',1,'ca500000-0000-4000-8000-000000000010',4,10,40),
  ('ca710000-0000-4000-8000-000000000111','ca100000-0000-4000-8000-000000000001','ca700000-0000-4000-8000-000000000011',2,'ca500000-0000-4000-8000-000000000011',4,10,40),
  ('ca710000-0000-4000-8000-000000000012','ca100000-0000-4000-8000-000000000001','ca700000-0000-4000-8000-000000000012',1,'ca500000-0000-4000-8000-000000000011',4,10,40),
  ('ca710000-0000-4000-8000-000000000112','ca100000-0000-4000-8000-000000000001','ca700000-0000-4000-8000-000000000012',2,'ca500000-0000-4000-8000-000000000010',4,10,40),
  ('ca710000-0000-4000-8000-000000000013','ca100000-0000-4000-8000-000000000001','ca700000-0000-4000-8000-000000000013',1,'ca500000-0000-4000-8000-000000000012',4,10,40),
  ('ca710000-0000-4000-8000-000000000113','ca100000-0000-4000-8000-000000000001','ca700000-0000-4000-8000-000000000013',2,'ca500000-0000-4000-8000-000000000013',4,10,40),
  ('ca710000-0000-4000-8000-000000000014','ca100000-0000-4000-8000-000000000001','ca700000-0000-4000-8000-000000000014',1,'ca500000-0000-4000-8000-000000000012',4,10,40),
  ('ca710000-0000-4000-8000-000000000114','ca100000-0000-4000-8000-000000000001','ca700000-0000-4000-8000-000000000014',2,'ca500000-0000-4000-8000-000000000013',4,10,40);
select public.operational_receive_purchase_order('ca100000-0000-4000-8000-000000000001','ca700000-0000-4000-8000-000000000007',jsonb_build_array(jsonb_build_object('purchase_order_item_id','ca710000-0000-4000-8000-000000000007','quantity',4,'effective_unit_cost',10)),'HARD-7','base','ca990000-0000-4000-8000-000000000007');
select public.operational_receive_purchase_order('ca100000-0000-4000-8000-000000000001','ca700000-0000-4000-8000-000000000009',jsonb_build_array(jsonb_build_object('purchase_order_item_id','ca710000-0000-4000-8000-000000000009','quantity',4,'effective_unit_cost',10)),'HARD-9','base','ca990000-0000-4000-8000-000000000009');
select public.operational_receive_purchase_order('ca100000-0000-4000-8000-000000000001','ca700000-0000-4000-8000-000000000010',jsonb_build_array(jsonb_build_object('purchase_order_item_id','ca710000-0000-4000-8000-000000000010','quantity',4,'effective_unit_cost',10)),'HARD-10','base','ca990000-0000-4000-8000-000000000010');
select public.operational_receive_purchase_order('ca100000-0000-4000-8000-000000000001','ca700000-0000-4000-8000-000000000013',jsonb_build_array(jsonb_build_object('purchase_order_item_id','ca710000-0000-4000-8000-000000000013','quantity',4,'effective_unit_cost',10),jsonb_build_object('purchase_order_item_id','ca710000-0000-4000-8000-000000000113','quantity',4,'effective_unit_cost',10)),'HARD-13','base','ca990000-0000-4000-8000-000000000013');
select public.operational_receive_purchase_order('ca100000-0000-4000-8000-000000000001','ca700000-0000-4000-8000-000000000014',jsonb_build_array(jsonb_build_object('purchase_order_item_id','ca710000-0000-4000-8000-000000000014','quantity',4,'effective_unit_cost',10),jsonb_build_object('purchase_order_item_id','ca710000-0000-4000-8000-000000000114','quantity',4,'effective_unit_cost',10)),'HARD-14','base','ca990000-0000-4000-8000-000000000014');
select public.operational_create_work_order('ca100000-0000-4000-8000-000000000001','ca200000-0000-4000-8000-000000000001','ca600000-0000-4000-8000-000000000002',null,'Phase 01 hardening reversal versus consumption','ca990000-0000-4000-8000-000000000015');
select public.operational_update_work_order('ca100000-0000-4000-8000-000000000001',(select id from public.work_orders where request_id='ca990000-0000-4000-8000-000000000015'),'',jsonb_build_array(jsonb_build_object('line_type','part','item_id','ca500000-0000-4000-8000-000000000009','quantity',3,'unit_price',20,'discount_amount',0)),'ca990000-0000-4000-8000-000000000016');
select public.operational_reserve_work_order_parts('ca100000-0000-4000-8000-000000000001',(select id from public.work_orders where request_id='ca990000-0000-4000-8000-000000000015'));

commit;
