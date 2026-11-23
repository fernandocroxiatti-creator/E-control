-- T18 behavior in the current schema. There is no trusted billing contract, so
-- R01's success path must fail closed rather than be simulated with a mock.
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
declare tenant_a constant uuid := 'f3000000-0000-4000-8000-000000000001'; tenant_b constant uuid := 'f3000000-0000-4000-8000-000000000002'; branch_a constant uuid := 'f3100000-0000-4000-8000-000000000001'; branch_b constant uuid := 'f3100000-0000-4000-8000-000000000002'; actor constant uuid := 'f3200000-0000-4000-8000-000000000001'; actor_branch_only constant uuid := 'f3200000-0000-4000-8000-000000000002'; membership constant uuid := 'f3300000-0000-4000-8000-000000000001'; branch_only_membership constant uuid := 'f3300000-0000-4000-8000-000000000002';
begin
  insert into auth.users(id,email,email_confirmed_at) values
    (actor,'phase02-reversal@example.test',clock_timestamp()),
    (actor_branch_only,'phase02-reversal-branch-only@example.test',clock_timestamp());
  insert into public.companies(id,legal_name,status) values(tenant_a,'Phase 02 reversal A','active'),(tenant_b,'Phase 02 reversal B','active');
  insert into public.branches(id,tenant_id,code,name,status) values
    (branch_a,tenant_a,'P02R','Phase 02 reversal branch','active'),
    (branch_b,tenant_a,'P02RB','Phase 02 reversal other branch','active');
  insert into public.company_memberships(id,tenant_id,user_id,status,branch_access_mode,created_by_user_id) values
    (membership,tenant_a,actor,'active','all_branches',actor),
    (branch_only_membership,tenant_a,actor_branch_only,'active','assigned_only',actor);
  insert into public.branch_access(tenant_id,branch_id,membership_id,status,granted_by_user_id)
  values(tenant_a,branch_b,branch_only_membership,'active',actor);
  insert into public.access_role_definitions(role_key,display_name,scope,approval_state) values('phase02_reversal_owner','Phase 02 reversal owner','company','approved');
  insert into public.membership_role_assignments(tenant_id,membership_id,role_key,branch_id,assigned_by_user_id) values
    (tenant_a,membership,'phase02_reversal_owner',null,actor),
    (tenant_a,branch_only_membership,'phase02_reversal_owner',null,actor);
  update public.permission_definitions set approval_state='approved' where permission_key in ('transaction.service_order.create','transaction.service_order.update','transaction.service_order.read');
  insert into public.role_permission_grants(role_key,permission_key) values('phase02_reversal_owner','transaction.service_order.create'),('phase02_reversal_owner','transaction.service_order.update'),('phase02_reversal_owner','transaction.service_order.read');
  update public.erp_transaction_authorization_catalog set approval_state='approved' where transaction_code in ('ZOS01','ZOS02','ZOS03');
  insert into public.company_module_availability(tenant_id,module_code,enabled,changed_by_user_id) values(tenant_a,'SVC',true,actor);
  insert into public.company_transaction_availability(tenant_id,transaction_code,enabled,changed_by_user_id) values(tenant_a,'ZOS01',true,actor),(tenant_a,'ZOS02',true,actor),(tenant_a,'ZOS03',true,actor);
  insert into public.business_parties(id,tenant_id,party_type,legal_name,request_id,created_by_user_id) values
    ('f3400000-0000-4000-8000-000000000001',tenant_a,'customer','Phase 02 reversal customer','f3500000-0000-4000-8000-000000000001',actor),
    ('f3400000-0000-4000-8000-000000000002',tenant_a,'supplier','Phase 02 reversal supplier','f3500000-0000-4000-8000-000000000002',actor);
end;
$setup$;

select set_config('request.jwt.claim.role','authenticated',false);
select set_config('request.jwt.claim.sub','f3200000-0000-4000-8000-000000000001',false);

do $test$
declare tenant_a constant uuid := 'f3000000-0000-4000-8000-000000000001'; tenant_b constant uuid := 'f3000000-0000-4000-8000-000000000002'; branch_a constant uuid := 'f3100000-0000-4000-8000-000000000001'; order_id uuid; purchase_id uuid; original_total numeric; current_total numeric; reversal_count integer; stock_events integer; audit_count integer;
begin
  select public.operational_create_work_order(tenant_a,branch_a,'f3400000-0000-4000-8000-000000000001',null,'Phase 02 reversal test','f3700000-0000-4000-8000-000000000001') into order_id;
  select public.operational_record_work_order_direct_purchase(tenant_a,order_id,'f3400000-0000-4000-8000-000000000002',null,'Reversible direct material',2,12.5,'supplier receipt','P02R',null,'f3700000-0000-4000-8000-000000000002') into purchase_id;
  select total_cost into original_total from public.work_order_direct_purchases where id=purchase_id;

  -- T18.03/T18.04: the billing status is unavailable, therefore an open O.S.
  -- cannot be treated as not billed by inference and the operation fails closed.
  begin
    perform public.operational_reverse_work_order_direct_purchase(tenant_a,order_id,purchase_id,null,'f3700000-0000-4000-8000-000000000003');
    raise exception 'T18.03/T18.04 billing-unknown reversal was accepted';
  exception when object_not_in_prerequisite_state then
    if sqlerrm not like '%billing status contract%' then raise; end if;
  end;
  -- T18.05/T18.06/T18.12/T18.13: optional reasons and replay payloads are
  -- syntactically accepted, but cannot mutate until billing is verifiable.
  begin perform public.operational_reverse_work_order_direct_purchase(tenant_a,order_id,purchase_id,'','f3700000-0000-4000-8000-000000000004'); exception when object_not_in_prerequisite_state then null; end;
  begin perform public.operational_reverse_work_order_direct_purchase(tenant_a,order_id,purchase_id,'Audit reason','f3700000-0000-4000-8000-000000000005'); exception when object_not_in_prerequisite_state then null; end;
  begin perform public.operational_reverse_work_order_direct_purchase(tenant_a,order_id,purchase_id,'Other reason','f3700000-0000-4000-8000-000000000005'); exception when object_not_in_prerequisite_state then null; end;
  -- T18.02: closed O.S. is rejected before the billing guard.
  update public.work_orders set status='closed' where tenant_id=tenant_a and id=order_id;
  begin
    perform public.operational_reverse_work_order_direct_purchase(tenant_a,order_id,purchase_id,null,'f3700000-0000-4000-8000-000000000006');
    raise exception 'T18.02 closed work order reversal was accepted';
  exception when object_not_in_prerequisite_state then
    if sqlerrm not like '%only while the work order is open%' then raise; end if;
  end;
  update public.work_orders set status='open' where tenant_id=tenant_a and id=order_id;
  -- T18.16 tenant isolation; T18.17 is a real active member whose access is
  -- assigned exclusively to another branch; T18.18 has no membership at all.
  begin perform public.operational_reverse_work_order_direct_purchase(tenant_b,order_id,purchase_id,null,'f3700000-0000-4000-8000-000000000007'); raise exception 'T18.16 cross-tenant reversal was accepted'; exception when no_data_found then null; end;
  perform set_config('request.jwt.claim.sub','f3200000-0000-4000-8000-000000000002',false);
  begin perform public.operational_reverse_work_order_direct_purchase(tenant_a,order_id,purchase_id,null,'f3700000-0000-4000-8000-000000000008'); raise exception 'T18.17 other-branch reversal was accepted'; exception when insufficient_privilege then null; end;
  perform set_config('request.jwt.claim.sub','f3200000-0000-4000-8000-000000000099',false);
  begin perform public.operational_reverse_work_order_direct_purchase(tenant_a,order_id,purchase_id,null,'f3700000-0000-4000-8000-000000000009'); raise exception 'T18.18 unauthorised reversal was accepted'; exception when insufficient_privilege then null; end;
  perform set_config('request.jwt.claim.sub','f3200000-0000-4000-8000-000000000001',false);

  -- T18.07–T18.11, T18.15, T18.19 and T18.20: every blocked attempt rolls
  -- back fully; no compensating fact, audit, stock or financial fact appears.
  select count(*) into reversal_count from public.work_order_direct_purchase_reversals where tenant_id=tenant_a and direct_purchase_id=purchase_id;
  select direct_purchase_total into current_total from public.work_orders where tenant_id=tenant_a and id=order_id;
  select count(*) into stock_events from public.inventory_movements where tenant_id=tenant_a;
  select count(*) into audit_count from app_private.operational_audit_events where tenant_id=tenant_a and event_key='work_order.direct_purchase.reversed';
  if reversal_count<>0 or current_total<>original_total or stock_events<>0 or audit_count<>0 then
    raise exception 'T18 blocked reversal changed original cost, stock or audit (% / % / % / %)', reversal_count,current_total,stock_events,audit_count;
  end if;
  if (select total_cost from public.work_order_direct_purchases where id=purchase_id)<>original_total then raise exception 'T18.07 original direct purchase changed'; end if;
  if pg_catalog.to_regclass('public.accounts_payable') is not null or pg_catalog.to_regclass('public.accounts_receivable') is not null then raise exception 'T18.11 fixture cannot assume a financial model'; end if;
end;
$test$;

do $security$
begin
  if not (select relrowsecurity and relforcerowsecurity from pg_class where oid='public.work_order_direct_purchase_reversals'::regclass) then raise exception 'T18 reversal FORCE RLS missing'; end if;
  if has_table_privilege('authenticated','public.work_order_direct_purchase_reversals','select')
     or has_function_privilege('anon','public.operational_reverse_work_order_direct_purchase(uuid,uuid,uuid,text,uuid)','execute')
     or has_function_privilege('service_role','public.operational_reverse_work_order_direct_purchase(uuid,uuid,uuid,text,uuid)','execute') then raise exception 'T18 reversal ACL is broad'; end if;
end;
$security$;

rollback;
