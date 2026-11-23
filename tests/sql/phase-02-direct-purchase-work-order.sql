begin;

create or replace function app_private.has_tenant_permission(p_tenant_id uuid,p_permission_key text,p_branch_id uuid default null)
returns boolean language sql stable security definer set search_path='' set row_security=off as $fn$
  select exists(
    select 1 from public.company_memberships m
    join public.companies c on c.id=m.tenant_id and c.status='active'
    join public.membership_role_assignments a on a.tenant_id=m.tenant_id and a.membership_id=m.id
    join public.access_role_definitions r on r.role_key=a.role_key and r.approval_state='approved'
    join public.permission_definitions p on p.permission_key=p_permission_key and p.approval_state='approved'
    join public.role_permission_grants g on g.role_key=r.role_key and g.permission_key=p_permission_key
    where m.tenant_id=p_tenant_id and m.user_id=auth.uid() and m.status='active'
      and ((r.scope='company' and a.branch_id is null) or (r.scope='branch' and a.branch_id=p_branch_id))
      and app_private.can_access_branch(p_tenant_id,p_branch_id)
  )
$fn$;

do $setup$
declare tenant_a constant uuid := 'f2000000-0000-4000-8000-000000000001'; tenant_b constant uuid := 'f2000000-0000-4000-8000-000000000002'; branch_a constant uuid := 'f2100000-0000-4000-8000-000000000001'; actor constant uuid := 'f2200000-0000-4000-8000-000000000001'; membership constant uuid := 'f2300000-0000-4000-8000-000000000001';
begin
  insert into auth.users(id,email,email_confirmed_at) values(actor,'phase02@example.test',clock_timestamp());
  insert into public.companies(id,legal_name,status) values(tenant_a,'Phase 02 A','active'),(tenant_b,'Phase 02 B','active');
  insert into public.branches(id,tenant_id,code,name,status) values(branch_a,tenant_a,'P02','Phase 02 branch','active');
  insert into public.company_memberships(id,tenant_id,user_id,status,branch_access_mode,created_by_user_id) values(membership,tenant_a,actor,'active','all_branches',actor);
  insert into public.access_role_definitions(role_key,display_name,scope,approval_state) values('phase02_owner','Phase 02 owner','company','approved');
  insert into public.membership_role_assignments(tenant_id,membership_id,role_key,branch_id,assigned_by_user_id) values(tenant_a,membership,'phase02_owner',null,actor);
  update public.permission_definitions set approval_state='approved' where permission_key in ('transaction.service_order.create','transaction.service_order.update','transaction.service_order.read');
  insert into public.role_permission_grants(role_key,permission_key) values('phase02_owner','transaction.service_order.create'),('phase02_owner','transaction.service_order.update'),('phase02_owner','transaction.service_order.read');
  update public.erp_transaction_authorization_catalog set approval_state='approved' where transaction_code in ('ZOS01','ZOS02','ZOS03');
  insert into public.company_module_availability(tenant_id,module_code,enabled,changed_by_user_id) values(tenant_a,'SVC',true,actor);
  insert into public.company_transaction_availability(tenant_id,transaction_code,enabled,changed_by_user_id) values(tenant_a,'ZOS01',true,actor),(tenant_a,'ZOS02',true,actor),(tenant_a,'ZOS03',true,actor);
  insert into public.business_parties(id,tenant_id,party_type,legal_name,request_id,created_by_user_id) values
    ('f2400000-0000-4000-8000-000000000001',tenant_a,'customer','Phase 02 customer','f2500000-0000-4000-8000-000000000001',actor),
    ('f2400000-0000-4000-8000-000000000002',tenant_a,'supplier','Phase 02 supplier','f2500000-0000-4000-8000-000000000002',actor);
  insert into public.catalog_items(id,tenant_id,item_type,code,name,unit_of_measure,current_cost,selling_price,minimum_stock,reorder_point,request_id,created_by_user_id) values('f2600000-0000-4000-8000-000000000001',tenant_a,'product','P02-DIRECT','Direct part','UN',0,0,0,0,'f2500000-0000-4000-8000-000000000003',actor);
end;
$setup$;

select set_config('request.jwt.claim.role','authenticated',false);
select set_config('request.jwt.claim.sub','f2200000-0000-4000-8000-000000000001',false);

do $test$
declare tenant_a constant uuid := 'f2000000-0000-4000-8000-000000000001'; tenant_b constant uuid := 'f2000000-0000-4000-8000-000000000002'; branch_a constant uuid := 'f2100000-0000-4000-8000-000000000001'; order_id uuid; purchase_id uuid; total numeric; stock_events integer; listed integer; listed_total numeric;
begin
  select public.operational_create_work_order(tenant_a,branch_a,'f2400000-0000-4000-8000-000000000001',null,'Phase 02 test','f2700000-0000-4000-8000-000000000001') into order_id;
  -- T01 valid record; T07 identical replay; T10/T11 no stock fact;
  -- T12 total; T13 audit. T15 has no financial ledger in the current model.
  select public.operational_record_work_order_direct_purchase(tenant_a,order_id,'f2400000-0000-4000-8000-000000000002','f2600000-0000-4000-8000-000000000001','Direct material',2,12.5,'supplier receipt','P02-1',null,'f2700000-0000-4000-8000-000000000002') into purchase_id;
  if public.operational_record_work_order_direct_purchase(tenant_a,order_id,'f2400000-0000-4000-8000-000000000002','f2600000-0000-4000-8000-000000000001','Direct material',2,12.5,'supplier receipt','P02-1',null,'f2700000-0000-4000-8000-000000000002')<>purchase_id then raise exception 'T07 idempotency failed'; end if;
  select direct_purchase_total into total from public.work_orders where id=order_id; if total<>25 then raise exception 'T12 direct cost total incorrect'; end if;
  select count(*) into stock_events from public.inventory_movements where tenant_id=tenant_a; if stock_events<>0 then raise exception 'T10/T11 direct purchase changed inventory'; end if;
  select count(*) into listed from public.operational_list_work_order_direct_purchases(tenant_a,branch_a,order_id,100,0); if listed<>1 then raise exception 'T01 list failed'; end if;
  select total_direct_cost into listed_total from public.operational_list_work_order_direct_purchase_totals(tenant_a,branch_a) where work_order_id=order_id; if listed_total<>25 then raise exception 'T12 direct cost total read failed'; end if;
  -- T04: branch is derived from the O.S.; callers cannot select a different one.
  if exists(select 1 from public.work_order_direct_purchases where id=purchase_id and branch_id<>branch_a) then raise exception 'T04 branch scope was not derived from the work order'; end if;
  if not exists(select 1 from public.work_order_events where work_order_id=order_id and event_key='work_order.direct_purchase.recorded') or not exists(select 1 from app_private.operational_audit_events where event_key='work_order.direct_purchase.recorded') then raise exception 'T13 audit missing'; end if;
  -- T08 divergent replay.
  begin perform public.operational_record_work_order_direct_purchase(tenant_a,order_id,null,null,'Direct material',2,13,'supplier receipt','P02-1',null,'f2700000-0000-4000-8000-000000000002'); raise exception 'T08 divergent replay accepted'; exception when unique_violation then null; end;
  -- T02 missing order; T03/T16 cross-tenant denial; T05/T06 invalid value validation.
  begin perform public.operational_record_work_order_direct_purchase(tenant_a,'f2800000-0000-4000-8000-000000000001',null,null,'Missing',1,1,'other',null,null,'f2700000-0000-4000-8000-000000000003'); raise exception 'T02 missing order accepted'; exception when no_data_found then null; end;
  begin perform public.operational_record_work_order_direct_purchase(tenant_b,order_id,null,null,'Cross tenant',1,1,'other',null,null,'f2700000-0000-4000-8000-000000000004'); raise exception 'T03/T16 cross tenant accepted'; exception when no_data_found then null; when insufficient_privilege then null; end;
  begin perform public.operational_record_work_order_direct_purchase(tenant_a,order_id,null,null,'Invalid quantity',0,1,'other',null,null,'f2700000-0000-4000-8000-000000000005'); raise exception 'T05 invalid quantity accepted'; exception when invalid_parameter_value then null; end;
  begin perform public.operational_record_work_order_direct_purchase(tenant_a,order_id,null,null,'Invalid cost',1,-1,'other',null,null,'f2700000-0000-4000-8000-000000000006'); raise exception 'T06 invalid cost accepted'; exception when invalid_parameter_value then null; end;
  -- T14/T18: direct purchases are immutable and blocked after close; cancellation/reversal is intentionally absent pending an approved rule.
  update public.work_orders set status='closed' where id=order_id;
  begin perform public.operational_record_work_order_direct_purchase(tenant_a,order_id,null,null,'After close',1,1,'other',null,null,'f2700000-0000-4000-8000-000000000007'); raise exception 'T14 closed order accepted'; exception when object_not_in_prerequisite_state then null; end;
end;
$test$;

do $security$
begin
  if not (select relrowsecurity and relforcerowsecurity from pg_class where oid='public.work_order_direct_purchases'::regclass) then raise exception 'Direct purchase FORCE RLS missing'; end if;
  if has_table_privilege('authenticated','public.work_order_direct_purchases','select') or has_function_privilege('anon','public.operational_record_work_order_direct_purchase(uuid,uuid,uuid,uuid,text,numeric,numeric,text,text,text,uuid)','execute') or has_function_privilege('service_role','public.operational_record_work_order_direct_purchase(uuid,uuid,uuid,uuid,text,numeric,numeric,text,text,text,uuid)','execute') then raise exception 'Direct purchase ACL is broad'; end if;
end;
$security$;

rollback;
