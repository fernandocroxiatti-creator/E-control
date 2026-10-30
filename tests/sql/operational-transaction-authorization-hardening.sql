-- Behavioral verification for 20261030120000.
-- Every mutation is contained in this transaction and rolled back.
begin;

-- Replace the deliberately permissive foundation stubs from the compact test
-- harness with the production authorization semantics before exercising the
-- hardening migration.
create or replace function app_private.is_active_company_member(p_tenant_id uuid)
returns boolean language sql stable security definer set search_path='' set row_security=off as $$
  select exists (
    select 1 from public.company_memberships membership
    join public.companies company on company.id=membership.tenant_id
    where membership.tenant_id=p_tenant_id and membership.user_id=auth.uid()
      and membership.status='active' and company.status='active'
  )
$$;
create or replace function app_private.can_access_branch(p_tenant_id uuid,p_branch_id uuid)
returns boolean language sql stable security definer set search_path='' set row_security=off as $$
  select exists (
    select 1 from public.company_memberships membership
    join public.companies company on company.id=membership.tenant_id
    join public.branches branch on branch.tenant_id=membership.tenant_id and branch.id=p_branch_id
    where membership.tenant_id=p_tenant_id and membership.user_id=auth.uid()
      and membership.status='active' and company.status='active'
      and (membership.branch_access_mode='all_branches' or exists (
        select 1 from public.branch_access access_link
        where access_link.tenant_id=membership.tenant_id and access_link.branch_id=branch.id
          and access_link.membership_id=membership.id and access_link.status='active'
      ))
  )
$$;
create or replace function app_private.has_tenant_permission(p_tenant_id uuid,p_permission_key text,p_branch_id uuid default null)
returns boolean language sql stable security definer set search_path='' set row_security=off as $$
  select exists (
    select 1 from public.company_memberships membership
    join public.companies company on company.id=membership.tenant_id and company.status='active'
    join public.membership_role_assignments assignment on assignment.tenant_id=membership.tenant_id and assignment.membership_id=membership.id
    join public.access_role_definitions role_definition on role_definition.role_key=assignment.role_key and role_definition.approval_state='approved'
    join public.role_permission_grants role_grant on role_grant.role_key=role_definition.role_key
    join public.permission_definitions permission on permission.permission_key=role_grant.permission_key and permission.approval_state='approved'
    where membership.tenant_id=p_tenant_id and membership.user_id=auth.uid() and membership.status='active'
      and role_grant.permission_key=p_permission_key
      and ((role_definition.scope='company' and assignment.branch_id is null)
        or (role_definition.scope='branch' and p_branch_id is not null and assignment.branch_id=p_branch_id))
      and (p_branch_id is null or app_private.can_access_branch(p_tenant_id,p_branch_id))
  )
$$;

do $setup$
declare
  tenant_a constant uuid := '81000000-0000-4000-8000-000000000001';
  tenant_b constant uuid := '81000000-0000-4000-8000-000000000002';
  branch_a constant uuid := '82000000-0000-4000-8000-000000000001';
  branch_b constant uuid := '82000000-0000-4000-8000-000000000002';
  actor constant uuid := '83000000-0000-4000-8000-000000000001';
  outsider constant uuid := '83000000-0000-4000-8000-000000000002';
  membership_a uuid := '84000000-0000-4000-8000-000000000001';
begin
  insert into auth.users(id,email,email_confirmed_at) values
    (actor,'hardening-actor@example.test',clock_timestamp()),
    (outsider,'hardening-outsider@example.test',clock_timestamp());
  insert into public.companies(id,legal_name,status) values
    (tenant_a,'Hardening Company A','active'),
    (tenant_b,'Hardening Company B','active');
  insert into public.branches(id,tenant_id,code,name,status) values
    (branch_a,tenant_a,'001','Hardening A','active'),
    (branch_b,tenant_b,'001','Hardening B','active');
  insert into public.company_memberships(id,tenant_id,user_id,status,branch_access_mode,created_by_user_id)
    values(membership_a,tenant_a,actor,'active','assigned_only',actor);
  insert into public.branch_access(tenant_id,branch_id,membership_id,status,granted_by_user_id)
    values(tenant_a,branch_a,membership_a,'active',actor);
  insert into public.access_role_definitions(role_key,display_name,scope,approval_state)
    values('hardening_company_role','Hardening company role','company','approved');
  insert into public.membership_role_assignments(tenant_id,membership_id,role_key,branch_id,assigned_by_user_id)
    values(tenant_a,membership_a,'hardening_company_role',null,actor);
  update public.permission_definitions set approval_state='approved'
    where permission_key in (
      'transaction.masterdata.party.read','transaction.masterdata.party.manage',
      'transaction.masterdata.catalog.read','transaction.masterdata.catalog.product.manage',
      'transaction.masterdata.catalog.service.manage','transaction.inventory.stock.read',
      'transaction.inventory.stock.move','transaction.purchasing.purchase_order.read',
      'transaction.purchasing.purchase_order.create'
    );
  insert into public.role_permission_grants(role_key,permission_key)
    select 'hardening_company_role',permission_key from public.permission_definitions
    where permission_key in (
      'transaction.masterdata.party.read','transaction.masterdata.party.manage',
      'transaction.masterdata.catalog.read','transaction.masterdata.catalog.product.manage',
      'transaction.masterdata.catalog.service.manage','transaction.inventory.stock.read',
      'transaction.inventory.stock.move','transaction.purchasing.purchase_order.read',
      'transaction.purchasing.purchase_order.create'
    );
  update public.erp_transaction_authorization_catalog set approval_state='approved'
    where transaction_code in ('BP01','MM01','SV01','MIGO','ME21N','ME23N');
  insert into public.company_module_availability(tenant_id,module_code,enabled,changed_by_user_id)
    select tenant_a,module_code,true,actor from (
      select distinct module_code from public.erp_transaction_authorization_catalog
      where transaction_code in ('BP01','MM01','SV01','MIGO','ME21N','ME23N')
    ) catalog_modules
    on conflict(tenant_id,module_code) do update
      set enabled=excluded.enabled,changed_by_user_id=excluded.changed_by_user_id,changed_at=clock_timestamp();
  insert into public.company_transaction_availability(tenant_id,transaction_code,enabled,changed_by_user_id)
    select tenant_a,transaction_code,true,actor from public.erp_transaction_authorization_catalog
    where transaction_code in ('BP01','MM01','SV01','MIGO','ME21N','ME23N');
end;
$setup$;

select set_config('request.jwt.claim.role','authenticated',false);
select set_config('request.jwt.claim.sub','83000000-0000-4000-8000-000000000001',false);

-- Test each of the 15 public operational RPCs with all authorization layers satisfied.
do $allowed$
declare
  tenant_a constant uuid := '81000000-0000-4000-8000-000000000001';
  branch_a constant uuid := '82000000-0000-4000-8000-000000000001';
  customer_id uuid;
  supplier_id uuid;
  product_id uuid;
  service_id uuid;
  order_id uuid;
  counted integer;
  transaction_approved boolean;
  permission_approved boolean;
  module_enabled boolean;
  transaction_enabled boolean;
begin
  if not public.authorize_company_transaction(tenant_a,branch_a,'ME21N') then
    select c.approval_state='approved',p.approval_state='approved',m.enabled,t.enabled
      into transaction_approved,permission_approved,module_enabled,transaction_enabled
      from public.erp_transaction_authorization_catalog c
      join public.permission_definitions p on p.permission_key=c.permission_key
      left join public.company_module_availability m on m.tenant_id=tenant_a and m.module_code=c.module_code
      left join public.company_transaction_availability t on t.tenant_id=tenant_a and t.transaction_code=c.transaction_code
      where c.transaction_code='ME21N';
    raise exception 'authorized ME21N baseline is unavailable (transaction %, permission %, module %, availability %)', transaction_approved,permission_approved,module_enabled,transaction_enabled;
  end if;
  select count(*) into counted from public.operational_list_business_parties(tenant_a,null,null,null,25,0);
  if counted <> 0 then raise exception 'unexpected starting parties'; end if;
  select public.operational_create_business_party(tenant_a,'customer','Hardening Customer','90000000000191',null,null,'{}'::jsonb,'85000000-0000-4000-8000-000000000001') into customer_id;
  select public.operational_create_business_party(tenant_a,'supplier','Hardening Supplier','90000000000272',null,null,'{}'::jsonb,'85000000-0000-4000-8000-000000000002') into supplier_id;
  perform public.operational_update_business_party(tenant_a,customer_id,'Hardening Customer Updated',null,null,'{}'::jsonb,'85000000-0000-4000-8000-000000000003');
  perform public.operational_set_business_party_status(tenant_a,customer_id,'inactive','85000000-0000-4000-8000-000000000004');
  select public.operational_create_catalog_item(tenant_a,'product','HARD-PRODUCT','Hardening Product',null,null,null,null,'UN',null,null,10,15,null,null,0,0,null,null,'86000000-0000-4000-8000-000000000001') into product_id;
  select public.operational_create_catalog_item(tenant_a,'service','HARD-SERVICE','Hardening Service',null,null,null,null,'UN',null,null,null,20,null,null,null,null,30,5,'86000000-0000-4000-8000-000000000002') into service_id;
  perform public.operational_update_catalog_item(tenant_a,product_id,'Hardening Product Updated',null,null,16,0,0,'active','86000000-0000-4000-8000-000000000003');
  perform public.operational_update_catalog_item_cost(tenant_a,product_id,11,'86000000-0000-4000-8000-000000000004');
  perform public.operational_record_inventory_movement(tenant_a,branch_a,product_id,'initial',5,'87000000-0000-4000-8000-000000000001','hardening initial');
  select count(*) into counted from public.operational_list_catalog_items(tenant_a,null,null,null,25,0);
  if counted <> 2 then raise exception 'catalog list was not authorized'; end if;
  select count(*) into counted from public.operational_list_inventory_balances(tenant_a,branch_a,null,25,0);
  if counted <> 1 then raise exception 'inventory balance list was not authorized'; end if;
  select count(*) into counted from public.operational_list_inventory_movements(tenant_a,branch_a,null,null,null,null,25,0);
  if counted <> 1 then raise exception 'inventory movement list was not authorized'; end if;
  select public.operational_create_purchase_order(tenant_a,branch_a,supplier_id,jsonb_build_array(jsonb_build_object('item_id',product_id,'quantity',2,'unit_price',11)),'hardening purchase','88000000-0000-4000-8000-000000000001') into order_id;
  perform public.operational_update_purchase_order(tenant_a,order_id,supplier_id,jsonb_build_array(jsonb_build_object('item_id',product_id,'quantity',3,'unit_price',11)),'hardening purchase updated','88000000-0000-4000-8000-000000000002');
  select count(*) into counted from public.operational_list_purchase_orders(tenant_a,branch_a,null,null,25,0);
  if counted <> 1 then raise exception 'purchase order list was not authorized'; end if;
  perform public.operational_set_catalog_item_status(tenant_a,service_id,'inactive','86000000-0000-4000-8000-000000000005');
end;
$allowed$;

-- Each public RPC must deny a foreign tenant before any state mutation. Some
-- update routines verify that their tenant-owned target exists before invoking
-- the shared assertion, and deliberately return P0002 rather than disclose it.
do $all_denied$
declare
  tenant_b constant uuid := '81000000-0000-4000-8000-000000000002';
  branch_b constant uuid := '82000000-0000-4000-8000-000000000002';
  item_id uuid := (select id from public.catalog_items where code='HARD-PRODUCT');
  supplier_id uuid := (select id from public.business_parties where legal_name='Hardening Supplier');
  order_id uuid := (select id from public.purchase_orders limit 1);
  routines text[] := array[
    'operational_list_business_parties','operational_create_business_party','operational_update_business_party','operational_set_business_party_status',
    'operational_create_catalog_item','operational_update_catalog_item','operational_set_catalog_item_status','operational_record_inventory_movement',
    'operational_list_catalog_items','operational_update_catalog_item_cost','operational_list_inventory_balances','operational_list_inventory_movements',
    'operational_list_purchase_orders','operational_create_purchase_order','operational_update_purchase_order'
  ];
  routine text;
begin
  foreach routine in array routines loop
    begin
      case routine
        when 'operational_list_business_parties' then perform * from public.operational_list_business_parties(tenant_b,null,null,null,1,0);
        when 'operational_create_business_party' then perform public.operational_create_business_party(tenant_b,'customer','Denied Party','90000000000353',null,null,'{}','89000000-0000-4000-8000-000000000001');
        when 'operational_update_business_party' then perform public.operational_update_business_party(tenant_b,supplier_id,'Denied',null,null,'{}','89000000-0000-4000-8000-000000000002');
        when 'operational_set_business_party_status' then perform public.operational_set_business_party_status(tenant_b,supplier_id,'inactive','89000000-0000-4000-8000-000000000003');
        when 'operational_create_catalog_item' then perform public.operational_create_catalog_item(tenant_b,'product','DENIED','Denied',null,null,null,null,'UN',null,null,null,null,null,null,null,null,null,null,'89000000-0000-4000-8000-000000000004');
        when 'operational_update_catalog_item' then perform public.operational_update_catalog_item(tenant_b,item_id,'Denied',null,null,null,null,null,'active','89000000-0000-4000-8000-000000000005');
        when 'operational_set_catalog_item_status' then perform public.operational_set_catalog_item_status(tenant_b,item_id,'inactive','89000000-0000-4000-8000-000000000006');
        when 'operational_record_inventory_movement' then perform public.operational_record_inventory_movement(tenant_b,branch_b,item_id,'initial',1,'89000000-0000-4000-8000-000000000007','denied');
        when 'operational_list_catalog_items' then perform * from public.operational_list_catalog_items(tenant_b,null,null,null,1,0);
        when 'operational_update_catalog_item_cost' then perform public.operational_update_catalog_item_cost(tenant_b,item_id,1,'89000000-0000-4000-8000-000000000008');
        when 'operational_list_inventory_balances' then perform * from public.operational_list_inventory_balances(tenant_b,branch_b,null,1,0);
        when 'operational_list_inventory_movements' then perform * from public.operational_list_inventory_movements(tenant_b,branch_b,null,null,null,null,1,0);
        when 'operational_list_purchase_orders' then perform * from public.operational_list_purchase_orders(tenant_b,branch_b,null,null,1,0);
        when 'operational_create_purchase_order' then perform public.operational_create_purchase_order(tenant_b,branch_b,supplier_id,jsonb_build_array(jsonb_build_object('item_id',item_id,'quantity',1,'unit_price',1)),'denied','89000000-0000-4000-8000-000000000009');
        when 'operational_update_purchase_order' then perform public.operational_update_purchase_order(tenant_b,order_id,supplier_id,jsonb_build_array(jsonb_build_object('item_id',item_id,'quantity',1,'unit_price',1)),'denied','89000000-0000-4000-8000-000000000010');
      end case;
      raise exception '% accepted a foreign tenant', routine;
    exception when insufficient_privilege or no_data_found then null;
    end;
  end loop;
end;
$all_denied$;

-- Exercise every independent authorization gate against the same central assertion.
do $gates$
declare
  tenant_a constant uuid := '81000000-0000-4000-8000-000000000001';
  tenant_b constant uuid := '81000000-0000-4000-8000-000000000002';
  branch_a constant uuid := '82000000-0000-4000-8000-000000000001';
  membership_a constant uuid := '84000000-0000-4000-8000-000000000001';
  actor constant uuid := '83000000-0000-4000-8000-000000000001';
  outsider constant uuid := '83000000-0000-4000-8000-000000000002';
  assert_denied boolean;
begin
  -- no membership
  perform set_config('request.jwt.claim.sub',outsider::text,false);
  begin perform app_private.assert_operational_permission(tenant_a,'transaction.inventory.stock.move',branch_a); raise exception 'no membership accepted'; exception when insufficient_privilege then null; end;
  perform set_config('request.jwt.claim.sub',actor::text,false);
  -- inactive membership
  update public.company_memberships set status='suspended' where id=membership_a;
  begin perform app_private.assert_operational_permission(tenant_a,'transaction.inventory.stock.move',branch_a); raise exception 'inactive membership accepted'; exception when insufficient_privilege then null; end;
  update public.company_memberships set status='active' where id=membership_a;
  -- branch access revoked
  update public.branch_access set status='revoked' where membership_id=membership_a and branch_id=branch_a;
  begin perform app_private.assert_operational_permission(tenant_a,'transaction.inventory.stock.move',branch_a); raise exception 'revoked branch accepted'; exception when insufficient_privilege then null; end;
  update public.branch_access set status='active' where membership_id=membership_a and branch_id=branch_a;
  -- role pending
  update public.access_role_definitions set approval_state='pending_approval' where role_key='hardening_company_role';
  begin perform app_private.assert_operational_permission(tenant_a,'transaction.inventory.stock.move',branch_a); raise exception 'pending role accepted'; exception when insufficient_privilege then null; end;
  update public.access_role_definitions set approval_state='approved' where role_key='hardening_company_role';
  -- permission pending
  update public.permission_definitions set approval_state='pending_approval' where permission_key='transaction.inventory.stock.move';
  begin perform app_private.assert_operational_permission(tenant_a,'transaction.inventory.stock.move',branch_a); raise exception 'pending permission accepted'; exception when insufficient_privilege then null; end;
  update public.permission_definitions set approval_state='approved' where permission_key='transaction.inventory.stock.move';
  -- missing grant / explicit revocation
  delete from public.role_permission_grants where role_key='hardening_company_role' and permission_key='transaction.inventory.stock.move';
  begin perform app_private.assert_operational_permission(tenant_a,'transaction.inventory.stock.move',branch_a); raise exception 'missing grant accepted'; exception when insufficient_privilege then null; end;
  insert into public.role_permission_grants(role_key,permission_key) values('hardening_company_role','transaction.inventory.stock.move');
  -- global transaction pending
  update public.erp_transaction_authorization_catalog set approval_state='pending_approval' where transaction_code='MIGO';
  begin perform app_private.assert_operational_permission(tenant_a,'transaction.inventory.stock.move',branch_a); raise exception 'pending transaction accepted'; exception when insufficient_privilege then null; end;
  update public.erp_transaction_authorization_catalog set approval_state='approved' where transaction_code='MIGO';
  -- module disabled
  update public.company_module_availability set enabled=false where tenant_id=tenant_a and module_code='INV';
  begin perform app_private.assert_operational_permission(tenant_a,'transaction.inventory.stock.move',branch_a); raise exception 'disabled module accepted'; exception when insufficient_privilege then null; end;
  update public.company_module_availability set enabled=true where tenant_id=tenant_a and module_code='INV';
  -- transaction disabled
  update public.company_transaction_availability set enabled=false where tenant_id=tenant_a and transaction_code='MIGO';
  begin perform app_private.assert_operational_permission(tenant_a,'transaction.inventory.stock.move',branch_a); raise exception 'disabled transaction accepted'; exception when insufficient_privilege then null; end;
  update public.company_transaction_availability set enabled=true where tenant_id=tenant_a and transaction_code='MIGO';
  -- company isolation and the final authorized case
  begin perform app_private.assert_operational_permission(tenant_b,'transaction.inventory.stock.move',branch_a); raise exception 'cross-company access accepted'; exception when insufficient_privilege then null; end;
  perform app_private.assert_operational_permission(tenant_a,'transaction.inventory.stock.move',branch_a);
end;
$gates$;

do $security_contract$
declare
  routine oid := 'app_private.assert_operational_permission(uuid,text,uuid)'::regprocedure;
  missing_assertions integer;
begin
  if not exists (select 1 from pg_proc where oid=routine and prosecdef and 'search_path=""'=any(proconfig) and 'row_security=off'=any(proconfig))
    or has_function_privilege('authenticated',routine,'execute')
    or has_function_privilege('service_role',routine,'execute')
    or has_function_privilege('anon',routine,'execute') then
    raise exception 'central assertion SECURITY DEFINER or ACL contract is unsafe';
  end if;
  select count(*) into missing_assertions
  from (values
    ('public.operational_list_business_parties(uuid,text,text,text,integer,integer)'::regprocedure),
    ('public.operational_create_business_party(uuid,text,text,text,text,text,jsonb,uuid)'::regprocedure),
    ('public.operational_update_business_party(uuid,uuid,text,text,text,jsonb,uuid)'::regprocedure),
    ('public.operational_set_business_party_status(uuid,uuid,text,uuid)'::regprocedure),
    ('public.operational_create_catalog_item(uuid,text,text,text,text,text,text,text,text,text,uuid,numeric,numeric,numeric,numeric,numeric,numeric,integer,numeric,uuid)'::regprocedure),
    ('public.operational_update_catalog_item(uuid,uuid,text,text,text,numeric,numeric,numeric,text,uuid)'::regprocedure),
    ('public.operational_set_catalog_item_status(uuid,uuid,text,uuid)'::regprocedure),
    ('public.operational_record_inventory_movement(uuid,uuid,uuid,text,numeric,uuid,text)'::regprocedure),
    ('public.operational_list_catalog_items(uuid,text,text,text,integer,integer)'::regprocedure),
    ('public.operational_update_catalog_item_cost(uuid,uuid,numeric,uuid)'::regprocedure),
    ('public.operational_list_inventory_balances(uuid,uuid,text,integer,integer)'::regprocedure),
    ('public.operational_list_inventory_movements(uuid,uuid,uuid,text,timestamptz,timestamptz,integer,integer)'::regprocedure),
    ('public.operational_list_purchase_orders(uuid,uuid,text,text,integer,integer)'::regprocedure),
    ('public.operational_create_purchase_order(uuid,uuid,uuid,jsonb,text,uuid)'::regprocedure),
    ('public.operational_update_purchase_order(uuid,uuid,uuid,jsonb,text,uuid)'::regprocedure)
  ) checked(routine_oid)
  join pg_proc p on p.oid=checked.routine_oid
  where p.prosrc not like '%assert_operational_permission%';
  if missing_assertions <> 0 then raise exception '% operational RPCs bypass central authorization',missing_assertions; end if;
  if exists (
    select 1 from pg_class
    where oid in ('public.business_parties'::regclass,'public.catalog_items'::regclass,'public.inventory_balances'::regclass,'public.inventory_movements'::regclass,'public.purchase_orders'::regclass,'public.purchase_order_items'::regclass)
      and (not relrowsecurity or not relforcerowsecurity)
  ) then raise exception 'operational table lost FORCE RLS'; end if;
end;
$security_contract$;

rollback;
