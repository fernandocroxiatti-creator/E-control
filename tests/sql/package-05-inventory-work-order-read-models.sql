begin;

-- The fixtures deliberately use a branch-scoped membership.  This exercises
-- the read models through the same tenant, branch, role, grant, approval and
-- company-availability gates used in Production.
-- The compact PostgreSQL harness starts with permissive placeholders for
-- these canonical helpers, so replace them only inside this transaction.
create or replace function app_private.is_active_company_member(p_tenant_id uuid)
returns boolean language sql stable security definer set search_path='' set row_security=off as $$
  select exists(select 1 from public.company_memberships m join public.companies c on c.id=m.tenant_id where m.tenant_id=p_tenant_id and m.user_id=auth.uid() and m.status='active' and c.status='active')
$$;
create or replace function app_private.can_access_branch(p_tenant_id uuid,p_branch_id uuid)
returns boolean language sql stable security definer set search_path='' set row_security=off as $$
  select exists(select 1 from public.company_memberships m join public.branches b on b.tenant_id=m.tenant_id and b.id=p_branch_id where m.tenant_id=p_tenant_id and m.user_id=auth.uid() and m.status='active' and (m.branch_access_mode='all_branches' or exists(select 1 from public.branch_access a where a.tenant_id=m.tenant_id and a.membership_id=m.id and a.branch_id=b.id and a.status='active')))
$$;
create or replace function app_private.has_tenant_permission(p_tenant_id uuid,p_permission_key text,p_branch_id uuid default null)
returns boolean language sql stable security definer set search_path='' set row_security=off as $$
  select exists(select 1 from public.company_memberships m join public.membership_role_assignments a on a.tenant_id=m.tenant_id and a.membership_id=m.id join public.access_role_definitions r on r.role_key=a.role_key and r.approval_state='approved' join public.role_permission_grants g on g.role_key=r.role_key join public.permission_definitions p on p.permission_key=g.permission_key and p.approval_state='approved' where m.tenant_id=p_tenant_id and m.user_id=auth.uid() and m.status='active' and g.permission_key=p_permission_key and ((r.scope='company' and a.branch_id is null) or (r.scope='branch' and p_branch_id is not null and a.branch_id=p_branch_id)) and (p_branch_id is null or app_private.can_access_branch(p_tenant_id,p_branch_id)))
$$;

do $setup$
declare
  tenant_a constant uuid := 'a1000000-0000-4000-8000-000000000001';
  tenant_b constant uuid := 'a1000000-0000-4000-8000-000000000002';
  branch_a constant uuid := 'a2000000-0000-4000-8000-000000000001';
  branch_b constant uuid := 'a2000000-0000-4000-8000-000000000002';
  actor constant uuid := 'a3000000-0000-4000-8000-000000000001';
  membership constant uuid := 'a4000000-0000-4000-8000-000000000001';
  product constant uuid := 'a5000000-0000-4000-8000-000000000001';
  customer constant uuid := 'a6000000-0000-4000-8000-000000000001';
  session_id constant uuid := 'a7000000-0000-4000-8000-000000000001';
  transfer_id constant uuid := 'a7000000-0000-4000-8000-000000000002';
  order_id constant uuid := 'a7000000-0000-4000-8000-000000000003';
begin
  insert into auth.users(id,email,email_confirmed_at)
  values(actor,'package05@example.test',clock_timestamp());
  insert into public.companies(id,legal_name,status)
  values(tenant_a,'Package 05 Tenant A','active'),(tenant_b,'Package 05 Tenant B','active');
  insert into public.branches(id,tenant_id,code,name,status)
  values(branch_a,tenant_a,'001','Package 05 Branch A','active'),
        (branch_b,tenant_a,'002','Package 05 Branch B','active');
  insert into public.company_memberships(id,tenant_id,user_id,status,branch_access_mode,created_by_user_id)
  values(membership,tenant_a,actor,'active','assigned_only',actor);
  insert into public.branch_access(tenant_id,branch_id,membership_id,status,granted_by_user_id)
  values(tenant_a,branch_a,membership,'active',actor);
  insert into public.access_role_definitions(role_key,display_name,scope,approval_state)
  values('package05_role','Package 05 role','company','approved');
  insert into public.membership_role_assignments(tenant_id,membership_id,role_key,branch_id,assigned_by_user_id)
  values(tenant_a,membership,'package05_role',null,actor);
  update public.permission_definitions set approval_state='approved'
  where permission_key in (
    'transaction.inventory.physical.create','transaction.inventory.physical.count','transaction.inventory.physical.adjust',
    'transaction.inventory.transfer','transaction.service_order.read'
  );
  insert into public.role_permission_grants(role_key,permission_key)
  select 'package05_role',permission_key from public.permission_definitions
  where permission_key in (
    'transaction.inventory.physical.create','transaction.inventory.physical.count','transaction.inventory.physical.adjust',
    'transaction.inventory.transfer','transaction.service_order.read'
  );
  update public.erp_transaction_authorization_catalog set approval_state='approved'
  where transaction_code in ('MI01','MI04','MI07','ZTR01','ZOS03');
  insert into public.company_module_availability(tenant_id,module_code,enabled,changed_by_user_id)
  values(tenant_a,'INV',true,actor),(tenant_a,'SVC',true,actor);
  insert into public.company_transaction_availability(tenant_id,transaction_code,enabled,changed_by_user_id)
  select tenant_a,transaction_code,true,actor from public.erp_transaction_authorization_catalog
  where transaction_code in ('MI01','MI04','MI07','ZTR01','ZOS03');
  insert into public.catalog_items(id,tenant_id,item_type,code,name,unit_of_measure,request_id,created_by_user_id)
  values(product,tenant_a,'product','P05-PART','Package 05 Part','UN','a8000000-0000-4000-8000-000000000001',actor);
  insert into public.business_parties(id,tenant_id,party_type,legal_name,request_id,created_by_user_id)
  values(customer,tenant_a,'customer','Package 05 Customer','a8000000-0000-4000-8000-000000000002',actor);
  insert into public.inventory_count_sessions(id,tenant_id,branch_id,status,request_id,notes,created_by_user_id)
  values(session_id,tenant_a,branch_a,'open','a8000000-0000-4000-8000-000000000003','Package 05 count',actor);
  insert into public.inventory_count_lines(tenant_id,session_id,item_id,counted_quantity,recorded_quantity,counted_by_user_id)
  values(tenant_a,session_id,product,5,4,actor);
  insert into public.inventory_transfers(id,tenant_id,source_branch_id,destination_branch_id,item_id,quantity,request_id,reference_note,created_by_user_id)
  values(transfer_id,tenant_a,branch_a,branch_b,product,1,'a8000000-0000-4000-8000-000000000004','Package 05 transfer',actor);
  insert into public.work_orders(id,tenant_id,branch_id,order_number,customer_id,problem_description,request_id,created_by_user_id)
  values(order_id,tenant_a,branch_a,1,customer,'Package 05 work order','a8000000-0000-4000-8000-000000000005',actor);
  insert into public.work_order_lines(tenant_id,work_order_id,line_number,line_type,item_id,description,quantity,unit_price,discount_amount,line_total)
  values(tenant_a,order_id,1,'part',product,'Package 05 Part',1,10,0,10);
  insert into public.work_order_part_reservations(tenant_id,work_order_id,item_id,quantity,status,reserved_by_user_id)
  values(tenant_a,order_id,product,1,'reserved',actor);
  insert into public.work_order_events(tenant_id,work_order_id,event_key,actor_user_id,details)
  values(tenant_a,order_id,'work_order.created',actor,jsonb_build_object('source','package05'));
end;
$setup$;

select set_config('request.jwt.claim.role','authenticated',false);
select set_config('request.jwt.claim.sub','a3000000-0000-4000-8000-000000000001',false);

do $behavior$
declare
  tenant_a constant uuid := 'a1000000-0000-4000-8000-000000000001';
  tenant_b constant uuid := 'a1000000-0000-4000-8000-000000000002';
  branch_a constant uuid := 'a2000000-0000-4000-8000-000000000001';
  branch_b constant uuid := 'a2000000-0000-4000-8000-000000000002';
  session_id constant uuid := 'a7000000-0000-4000-8000-000000000001';
  order_id constant uuid := 'a7000000-0000-4000-8000-000000000003';
  session_rows integer; transfer_rows integer; detail jsonb;
begin
  select count(*) into session_rows from public.operational_list_inventory_count_sessions(tenant_a,branch_a,null,25,0);
  if session_rows<>1 then raise exception 'Inventory count session listing is not branch scoped'; end if;
  select count(*) into transfer_rows from public.operational_list_inventory_transfers(tenant_a,branch_a,25,0);
  if transfer_rows<>1 then raise exception 'Transfer listing did not include the source branch'; end if;
  select public.operational_get_work_order_detail(tenant_a,order_id) into detail;
  if detail->>'work_order_id'<>order_id::text
    or jsonb_array_length(detail->'lines')<>1
    or jsonb_array_length(detail->'reservations')<>1
    or jsonb_path_exists(detail,'$.events[*].actor_user_id') then
    raise exception 'Work-order detail is incomplete or leaked an actor identity';
  end if;
  begin
    perform public.operational_list_inventory_count_sessions(tenant_a,branch_b,null,25,0);
    raise exception 'Unauthorized branch inventory-count read was accepted';
  exception when insufficient_privilege then null;
  end;
  begin
    perform public.operational_list_inventory_count_sessions(tenant_b,branch_a,null,25,0);
    raise exception 'Cross-company inventory-count read was accepted';
  exception when insufficient_privilege then null;
  end;
  -- Any one of the three count permissions is sufficient; the other two are
  -- then removed to prove the canonical checks are evaluated independently.
  delete from public.role_permission_grants
  where role_key='package05_role' and permission_key in ('transaction.inventory.physical.create','transaction.inventory.physical.adjust');
  select count(*) into session_rows from public.operational_list_inventory_count_sessions(tenant_a,branch_a,null,25,0);
  if session_rows<>1 then raise exception 'Count permission alone cannot read its count session'; end if;
  delete from public.role_permission_grants where role_key='package05_role' and permission_key='transaction.inventory.physical.count';
  begin
    perform public.operational_list_inventory_count_sessions(tenant_a,branch_a,null,25,0);
    raise exception 'Count read succeeded without an inventory physical permission';
  exception when insufficient_privilege then null;
  end;
end;
$behavior$;

do $security$
begin
  if has_table_privilege('authenticated','public.inventory_count_sessions','select')
    or has_table_privilege('authenticated','public.inventory_transfers','select')
    or has_table_privilege('authenticated','public.work_orders','select')
    or has_function_privilege('anon','public.operational_list_inventory_count_sessions(uuid,uuid,text,integer,integer)','execute')
    or has_function_privilege('service_role','public.operational_get_work_order_detail(uuid,uuid)','execute') then
    raise exception 'Package 05 direct access or broad RPC grant detected';
  end if;
end;
$security$;

rollback;
