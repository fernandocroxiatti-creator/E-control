begin;

do $setup$
declare tenant_id constant uuid := 'f9100000-0000-4000-8000-000000000001'; branch_id constant uuid := 'f9200000-0000-4000-8000-000000000001'; actor_id constant uuid := 'f9300000-0000-4000-8000-000000000001'; membership_id constant uuid := 'f9400000-0000-4000-8000-000000000001';
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
select set_config('request.jwt.claim.role','authenticated',false); select set_config('request.jwt.claim.sub','f9300000-0000-4000-8000-000000000001',false);

do $fixtures$
declare t uuid:='f9100000-0000-4000-8000-000000000001'; b uuid:='f9200000-0000-4000-8000-000000000001'; cancelled uuid; active uuid;
begin
 cancelled:=public.operational_create_financial_obligation(t,b,'receivable',null,'Cancelled billing fixture',current_date,'[{"due_date":"2026-12-05","amount":25},{"due_date":"2026-12-20","amount":25}]',gen_random_uuid());
 active:=public.operational_create_financial_obligation(t,b,'payable',null,'Active balance fixture',current_date,'[{"due_date":"2026-12-05","amount":20}]',gen_random_uuid());
 update public.financial_obligations set status='cancelled' where id=cancelled;
 update public.financial_installments set status='cancelled' where obligation_id=cancelled;
 perform set_config('test.cancelled_obligation',cancelled::text,true);
 perform set_config('test.cancelled_installment',(select id::text from public.financial_installments where obligation_id=cancelled and installment_number=1),true);
end;$fixtures$;
set local role authenticated;
do $test$
declare r record; t uuid:='f9100000-0000-4000-8000-000000000001'; b uuid:='f9200000-0000-4000-8000-000000000001';
begin
 if current_user<>'authenticated' then raise exception 'Must exercise authenticated database role'; end if;
 select * into r from public.operational_list_financial_obligations(t,b,'receivable','cancelled',100,0);
 if r.obligation_id is null or r.gross_amount<>50 or r.settled_amount<>0 or r.open_amount<>0 or jsonb_array_length(r.installments)<>2 then raise exception 'Cancelled obligation balance/history incorrect'; end if;
 if exists(select 1 from jsonb_array_elements(r.installments) i where (i->>'open_amount')::numeric<>0 or (i->>'amount')::numeric<>25 or i->>'status'<>'cancelled') then raise exception 'Cancelled installment balance/history incorrect'; end if;
 select * into r from public.operational_list_financial_obligations(t,b,'payable','open',100,0);
 if r.obligation_id is null or r.open_amount<>20 or (r.installments->0->>'open_amount')::numeric<>20 then raise exception 'Active balance changed'; end if;
 begin
  perform public.operational_settle_financial_installment(t,current_setting('test.cancelled_installment')::uuid,1,current_date,'Fictitious test',null,gen_random_uuid());
  raise exception 'Cancelled installment could be settled';
 exception when object_not_in_prerequisite_state then null; end;
end;$test$;
reset role;
do $verify$
begin
 if exists(select 1 from public.financial_settlements where obligation_id=current_setting('test.cancelled_obligation')::uuid)
 or (select gross_amount from public.financial_obligations where id=current_setting('test.cancelled_obligation')::uuid)<>50
 then raise exception 'Cancelled facts changed'; end if;
end;$verify$;
rollback;
