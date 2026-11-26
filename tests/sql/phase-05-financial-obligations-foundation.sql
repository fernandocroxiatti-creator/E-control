begin;

do $setup$
declare tenant_id constant uuid := '91000000-0000-4000-8000-000000000001'; branch_id constant uuid := '92000000-0000-4000-8000-000000000001'; actor_id constant uuid := '93000000-0000-4000-8000-000000000001'; membership_id constant uuid := '94000000-0000-4000-8000-000000000001';
begin
  insert into auth.users(id,email,email_confirmed_at) values(actor_id,'phase05@example.test',clock_timestamp());
  insert into public.companies(id,legal_name,status) values(tenant_id,'Phase 05 finance','active');
  insert into public.branches(id,tenant_id,code,name,status) values(branch_id,tenant_id,'P05','Phase 05 branch','active');
  insert into public.company_memberships(id,tenant_id,user_id,status,branch_access_mode,created_by_user_id) values(membership_id,tenant_id,actor_id,'active','all_branches',actor_id);
  insert into public.access_role_definitions(role_key,display_name,scope,approval_state) values('phase05_owner','Phase 05 owner','company','approved');
  insert into public.membership_role_assignments(tenant_id,membership_id,role_key,branch_id,assigned_by_user_id) values(tenant_id,membership_id,'phase05_owner',null,actor_id);
  update public.permission_definitions set approval_state='approved' where permission_key like 'transaction.finance.%';
  update public.erp_transaction_authorization_catalog set approval_state='approved' where transaction_code in ('ZFI01','ZFI02','ZFI03','ZFI04');
  insert into public.company_module_availability(tenant_id,module_code,enabled,changed_by_user_id) values(tenant_id,'FIN',true,actor_id);
  insert into public.company_transaction_availability(tenant_id,transaction_code,enabled,changed_by_user_id) values (tenant_id,'ZFI01',true,actor_id),(tenant_id,'ZFI02',true,actor_id),(tenant_id,'ZFI03',true,actor_id),(tenant_id,'ZFI04',true,actor_id);
  insert into public.company_role_permission_grants(tenant_id,branch_id,grant_scope,role_key,permission_key,reason,created_by_user_id) values
    (tenant_id,branch_id,'branch','phase05_owner','transaction.finance.payable.manage','Phase 05 isolated test',actor_id),(tenant_id,branch_id,'branch','phase05_owner','transaction.finance.receivable.manage','Phase 05 isolated test',actor_id),(tenant_id,branch_id,'branch','phase05_owner','transaction.finance.settlement.manage','Phase 05 isolated test',actor_id),(tenant_id,branch_id,'branch','phase05_owner','transaction.finance.read','Phase 05 isolated test',actor_id);
end;
$setup$;
select set_config('request.jwt.claim.role','authenticated',false); select set_config('request.jwt.claim.sub','93000000-0000-4000-8000-000000000001',false);

do $test$
declare v_tenant_id constant uuid := '91000000-0000-4000-8000-000000000001'; v_branch_id constant uuid := '92000000-0000-4000-8000-000000000001'; payable_id uuid; receivable_id uuid; installment_id uuid; settlement_id uuid; reversal_id uuid; stock_before integer;
begin
  select count(*) into stock_before from public.inventory_movements m where m.tenant_id=v_tenant_id;
  select public.operational_create_financial_obligation(v_tenant_id,v_branch_id,'payable',null,'Phase 05 payable','2026-11-26',jsonb_build_array(jsonb_build_object('due_date','2026-12-01','amount',60),jsonb_build_object('due_date','2027-01-01','amount',40)),'95000000-0000-4000-8000-000000000001') into payable_id;
  if public.operational_create_financial_obligation(v_tenant_id,v_branch_id,'payable',null,'Phase 05 payable','2026-11-26',jsonb_build_array(jsonb_build_object('due_date','2026-12-01','amount',60),jsonb_build_object('due_date','2027-01-01','amount',40)),'95000000-0000-4000-8000-000000000001')<>payable_id then raise exception 'obligation replay failed'; end if;
  begin perform public.operational_create_financial_obligation(v_tenant_id,v_branch_id,'payable',null,'different',current_date,jsonb_build_array(jsonb_build_object('due_date','2026-12-01','amount',1)),'95000000-0000-4000-8000-000000000001'); raise exception 'divergent obligation replay accepted'; exception when unique_violation then null; end;
  select id into installment_id from public.financial_installments i where i.tenant_id=v_tenant_id and i.obligation_id=payable_id and i.installment_number=1;
  select public.operational_settle_financial_installment(v_tenant_id,installment_id,30,'2026-11-27','transfer','P05-A','95000000-0000-4000-8000-000000000002') into settlement_id;
  if public.operational_settle_financial_installment(v_tenant_id,installment_id,30,'2026-11-27','transfer','P05-A','95000000-0000-4000-8000-000000000002')<>settlement_id then raise exception 'settlement replay failed'; end if;
  if (select settled_amount from public.financial_obligations where id=payable_id)<>30 then raise exception 'partial settlement wrong'; end if;
  begin perform public.operational_settle_financial_installment(v_tenant_id,installment_id,31,'2026-11-27','transfer','P05-over','95000000-0000-4000-8000-000000000003'); raise exception 'over-settlement accepted'; exception when check_violation then null; end;
  select public.operational_reverse_financial_settlement(v_tenant_id,settlement_id,'Erro de conciliação','95000000-0000-4000-8000-000000000004') into reversal_id;
  if public.operational_reverse_financial_settlement(v_tenant_id,settlement_id,'Erro de conciliação','95000000-0000-4000-8000-000000000004')<>reversal_id then raise exception 'reversal replay failed'; end if;
  if (select settled_amount from public.financial_obligations where id=payable_id)<>0 then raise exception 'reversal did not restore balance'; end if;
  begin perform public.operational_reverse_financial_settlement(v_tenant_id,settlement_id,'Outra tentativa','95000000-0000-4000-8000-000000000005'); raise exception 'duplicate reversal accepted'; exception when object_not_in_prerequisite_state then null; end;
  select public.operational_create_financial_obligation(v_tenant_id,v_branch_id,'receivable',null,'Phase 05 receivable','2026-11-26',jsonb_build_array(jsonb_build_object('due_date','2026-12-01','amount',50)),'95000000-0000-4000-8000-000000000006') into receivable_id;
  if not exists(select 1 from public.financial_events e where e.tenant_id=v_tenant_id and e.obligation_id=receivable_id and e.event_key='financial_obligation.created') then raise exception 'obligation audit missing'; end if;
  if (select count(*) from public.inventory_movements m where m.tenant_id=v_tenant_id)<>stock_before then raise exception 'finance changed inventory'; end if;
end;
$test$;

do $security$
begin
  if not (select relrowsecurity and relforcerowsecurity from pg_class where oid='public.financial_obligations'::regclass) or has_table_privilege('authenticated','public.financial_obligations','select') or has_function_privilege('anon','public.operational_settle_financial_installment(uuid,uuid,numeric,date,text,text,uuid)','execute') then raise exception 'finance RLS or ACL hardening failed'; end if;
end;
$security$;
rollback;
