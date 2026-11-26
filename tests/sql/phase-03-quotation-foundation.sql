begin;

do $setup$
declare tenant_id constant uuid := '81000000-0000-4000-8000-000000000001'; branch_id constant uuid := '82000000-0000-4000-8000-000000000001'; actor_id constant uuid := '83000000-0000-4000-8000-000000000001'; membership_id constant uuid := '84000000-0000-4000-8000-000000000001';
begin
  insert into auth.users(id,email,email_confirmed_at) values(actor_id,'phase03@example.test',clock_timestamp());
  insert into public.companies(id,legal_name,status) values(tenant_id,'Phase 03 quotations','active');
  insert into public.branches(id,tenant_id,code,name,status) values(branch_id,tenant_id,'P03','Phase 03 branch','active');
  insert into public.company_memberships(id,tenant_id,user_id,status,branch_access_mode,created_by_user_id) values(membership_id,tenant_id,actor_id,'active','all_branches',actor_id);
  insert into public.access_role_definitions(role_key,display_name,scope,approval_state) values('phase03_owner','Phase 03 owner','company','approved');
  insert into public.membership_role_assignments(tenant_id,membership_id,role_key,branch_id,assigned_by_user_id) values(tenant_id,membership_id,'phase03_owner',null,actor_id);
  update public.permission_definitions set approval_state='approved' where permission_key in ('transaction.quotation.create','transaction.quotation.manage','transaction.quotation.read','transaction.quotation.approve','transaction.service_order.create','transaction.service_order.update');
  update public.erp_transaction_authorization_catalog set approval_state='approved' where transaction_code in ('ZQT01','ZQT02','ZQT03','ZQT04','ZOS01','ZOS02');
  insert into public.company_module_availability(tenant_id,module_code,enabled,changed_by_user_id) values(tenant_id,'BUD',true,actor_id),(tenant_id,'SVC',true,actor_id);
  insert into public.company_transaction_availability(tenant_id,transaction_code,enabled,changed_by_user_id) values
    (tenant_id,'ZQT01',true,actor_id),(tenant_id,'ZQT02',true,actor_id),(tenant_id,'ZQT03',true,actor_id),(tenant_id,'ZQT04',true,actor_id),(tenant_id,'ZOS01',true,actor_id),(tenant_id,'ZOS02',true,actor_id);
  insert into public.company_role_permission_grants(tenant_id,branch_id,grant_scope,role_key,permission_key,reason,created_by_user_id) values
    (tenant_id,branch_id,'branch','phase03_owner','transaction.quotation.create','Phase 03 isolated test',actor_id),
    (tenant_id,branch_id,'branch','phase03_owner','transaction.quotation.manage','Phase 03 isolated test',actor_id),
    (tenant_id,branch_id,'branch','phase03_owner','transaction.quotation.read','Phase 03 isolated test',actor_id),
    (tenant_id,branch_id,'branch','phase03_owner','transaction.quotation.approve','Phase 03 isolated test',actor_id),
    (tenant_id,branch_id,'branch','phase03_owner','transaction.service_order.create','Phase 03 isolated test',actor_id),
    (tenant_id,branch_id,'branch','phase03_owner','transaction.service_order.update','Phase 03 isolated test',actor_id);
  insert into public.business_parties(id,tenant_id,party_type,legal_name,request_id,created_by_user_id) values('85000000-0000-4000-8000-000000000001',tenant_id,'customer','Phase 03 customer','86000000-0000-4000-8000-000000000001',actor_id);
  insert into public.catalog_items(id,tenant_id,item_type,code,name,unit_of_measure,current_cost,selling_price,minimum_stock,reorder_point,request_id,created_by_user_id) values
    ('85000000-0000-4000-8000-000000000002',tenant_id,'product','P03-PART','Phase 03 part','UN',10,20,0,0,'86000000-0000-4000-8000-000000000002',actor_id),
    ('85000000-0000-4000-8000-000000000003',tenant_id,'service','P03-SERVICE','Phase 03 service','HR',30,50,0,0,'86000000-0000-4000-8000-000000000003',actor_id);
end;
$setup$;

select set_config('request.jwt.claim.role','authenticated',false);
select set_config('request.jwt.claim.sub','83000000-0000-4000-8000-000000000001',false);

do $test$
declare v_tenant_id constant uuid := '81000000-0000-4000-8000-000000000001'; v_branch_id constant uuid := '82000000-0000-4000-8000-000000000001'; quote_id uuid; v_work_order_id uuid; before_movements integer; after_movements integer;
begin
  select public.operational_create_quotation(v_tenant_id,v_branch_id,'85000000-0000-4000-8000-000000000001',null,'Phase 03 test',jsonb_build_array(jsonb_build_object('item_id','85000000-0000-4000-8000-000000000002','quantity',2,'unit_price',25,'discount_percent',10),jsonb_build_object('item_id','85000000-0000-4000-8000-000000000003','quantity',1,'unit_price',50,'discount_percent',0)),'87000000-0000-4000-8000-000000000001') into quote_id;
  if public.operational_create_quotation(v_tenant_id,v_branch_id,'85000000-0000-4000-8000-000000000001',null,'Phase 03 test',jsonb_build_array(jsonb_build_object('item_id','85000000-0000-4000-8000-000000000002','quantity',2,'unit_price',25,'discount_percent',10),jsonb_build_object('item_id','85000000-0000-4000-8000-000000000003','quantity',1,'unit_price',50,'discount_percent',0)),'87000000-0000-4000-8000-000000000001') <> quote_id then raise exception 'quotation replay did not return original id'; end if;
  begin perform public.operational_create_quotation(v_tenant_id,v_branch_id,'85000000-0000-4000-8000-000000000001',null,'Different',jsonb_build_array(jsonb_build_object('item_id','85000000-0000-4000-8000-000000000002','quantity',1,'unit_price',25,'discount_percent',0)),'87000000-0000-4000-8000-000000000001'); raise exception 'divergent quotation replay accepted'; exception when unique_violation then null; end;
  if (select total_amount from public.quotations where id=quote_id) <> 95 then raise exception 'quotation total was not calculated from price and discount'; end if;
  perform public.operational_update_quotation(v_tenant_id,quote_id,'85000000-0000-4000-8000-000000000001',null,'Updated',jsonb_build_array(jsonb_build_object('item_id','85000000-0000-4000-8000-000000000002','quantity',2,'unit_price',30,'discount_percent',0)),'87000000-0000-4000-8000-000000000002');
  if (select total_amount from public.quotations where id=quote_id) <> 60 then raise exception 'quotation update total is incorrect'; end if;
  if public.operational_decide_quotation(v_tenant_id,quote_id,'approved','Commercially approved','87000000-0000-4000-8000-000000000003') <> 'approved' then raise exception 'quotation approval failed'; end if;
  if public.operational_decide_quotation(v_tenant_id,quote_id,'approved','Commercially approved','87000000-0000-4000-8000-000000000003') <> 'approved' then raise exception 'quotation decision replay failed'; end if;
  select count(*) into before_movements from public.inventory_movements m where m.tenant_id=v_tenant_id;
  select public.operational_convert_quotation_to_work_order(v_tenant_id,quote_id,'Test asset','Approved quotation conversion','87000000-0000-4000-8000-000000000004') into v_work_order_id;
  if public.operational_convert_quotation_to_work_order(v_tenant_id,quote_id,'Test asset','Approved quotation conversion','87000000-0000-4000-8000-000000000004') <> v_work_order_id then raise exception 'quotation conversion replay failed'; end if;
  if (select count(*) from public.work_order_lines l where l.tenant_id=v_tenant_id and l.work_order_id=v_work_order_id) <> 1 then raise exception 'quotation conversion did not copy snapshot lines'; end if;
  select count(*) into after_movements from public.inventory_movements m where m.tenant_id=v_tenant_id;
  if after_movements <> before_movements then raise exception 'quotation conversion changed inventory'; end if;
  if not exists(select 1 from app_private.operational_audit_events e where e.tenant_id=v_tenant_id and e.event_key='quotation.converted_to_work_order') then raise exception 'quotation audit event is missing'; end if;
end;
$test$;

do $security$
begin
  if not (select relrowsecurity and relforcerowsecurity from pg_class where oid='public.quotations'::regclass) or has_table_privilege('authenticated','public.quotations','select') or has_function_privilege('anon','public.operational_create_quotation(uuid,uuid,uuid,date,text,jsonb,uuid)','execute') or has_function_privilege('service_role','public.operational_create_quotation(uuid,uuid,uuid,date,text,jsonb,uuid)','execute') then raise exception 'quotation RLS or ACL hardening failed'; end if;
end;
$security$;

rollback;
