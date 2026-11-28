begin;
select set_config('request.jwt.claim.role','authenticated',false);
select set_config('request.jwt.claim.sub','e1300000-0000-4000-8000-000000000001',false);
-- Isolated fixture from the earlier bank concurrency test. No real grants.
do $setup$
declare t uuid:='e1100000-0000-4000-8000-000000000001'; b uuid:='e1200000-0000-4000-8000-000000000001'; u uuid:='e1300000-0000-4000-8000-000000000001';
begin
 if exists(select 1 from public.erp_transaction_authorization_catalog where transaction_code in ('ZFB04','ZTR06','ZRP01','ZRP02','ZRP03','ZRP04','ZRP05','ZRP06') and approval_state<>'pending_approval') then raise exception 'new capabilities were auto-approved'; end if;
 update public.permission_definitions set approval_state='approved' where permission_key like 'transaction.reports.%' or permission_key like 'transaction.billing.%' or permission_key='transaction.treasury.statement.import' or permission_key in ('transaction.purchasing.purchase_order.read','transaction.sales.order.read','transaction.inventory.history.read','transaction.service_order.read');
 update public.erp_transaction_authorization_catalog set approval_state='approved' where transaction_code in ('ZFB01','ZFB02','ZFB03','ZFB04','ZTR06','ZRP01','ZRP02','ZRP03','ZRP04','ZRP05','ZRP06','ME23N','ZVE03','MB51','ZOS03');
 insert into public.company_module_availability(tenant_id,module_code,enabled,changed_by_user_id) select t,x,true,u from unnest(array['PUR','SAL','INV','SVC']) x on conflict do nothing;
 insert into public.company_transaction_availability(tenant_id,transaction_code,enabled,changed_by_user_id) select t,transaction_code,true,u from public.erp_transaction_authorization_catalog where transaction_code in ('ZFB01','ZFB02','ZFB03','ZFB04','ZTR06','ZRP01','ZRP02','ZRP03','ZRP04','ZRP05','ZRP06','ME23N','ZVE03','MB51','ZOS03') on conflict do nothing;
 insert into public.company_role_permission_grants(tenant_id,branch_id,grant_scope,role_key,permission_key,reason,created_by_user_id) select t,b,'branch','completion_test',permission_key,'Final isolated validation',u from public.permission_definitions where permission_key like 'transaction.reports.%' or permission_key like 'transaction.billing.%' or permission_key='transaction.treasury.statement.import' or permission_key in ('transaction.purchasing.purchase_order.read','transaction.sales.order.read','transaction.inventory.history.read','transaction.service_order.read') on conflict do nothing;
end;$setup$;

do $saas$
declare t uuid:='e1100000-0000-4000-8000-000000000001'; b uuid:='e1200000-0000-4000-8000-000000000001'; u uuid:='e1300000-0000-4000-8000-000000000001'; plan uuid; newuser uuid:=gen_random_uuid(); today date:=(statement_timestamp() at time zone 'America/Sao_Paulo')::date; before_grants integer;
begin
 insert into app_private.master_admins(user_id,status,authorized_by_user_id,authorization_reason,approval_reference) values(u,'active',u,'Final isolated fixture only','LOCAL-FINAL');
 select count(*) into before_grants from public.company_role_permission_grants where tenant_id=t;
 plan:=public.master_save_saas_plan('FINAL','Final plan','active',2,1);
 perform public.master_manage_saas_subscription(t,plan,'pending','Create final test subscription');
 if app_private.has_tenant_permission(t,'transaction.treasury.read',b) then raise exception 'pending subscription allowed operations'; end if;
 perform public.master_manage_saas_subscription(t,plan,'active','Activate final subscription');
 perform public.master_set_saas_company_policy(t,true,true,today-4,3,'Enable overdue blocking test');
 if app_private.has_tenant_permission(t,'transaction.treasury.read',b) then raise exception 'overdue beyond grace allowed'; end if;
 begin perform public.operational_get_bank_treasury(t,b,today-5,today); raise exception 'bank RPC bypassed SaaS'; exception when insufficient_privilege then null; end;
 if (public.company_get_saas_subscription(t)->>'plan')<>'Final plan' then raise exception 'regularization access unavailable'; end if;
 perform public.master_set_saas_company_policy(t,true,true,today-3,3,'Inclusive grace boundary test');
 if not app_private.has_tenant_permission(t,'transaction.treasury.read',b) then raise exception 'grace boundary denied'; end if;
 perform public.master_manage_saas_subscription(t,plan,'suspended','Suspend final subscription');
 if app_private.saas_operational_allowed(t) then raise exception 'suspended company allowed'; end if;
 perform public.master_reactivate_saas_company(t,today+30,'Master manual reactivation');
 if not app_private.saas_operational_allowed(t) then raise exception 'manual reactivation failed'; end if;
 begin insert into public.branches(tenant_id,code,name,status) values(t,'OVER','Over limit','active'); raise exception 'branch limit bypass'; exception when check_violation then null; end;
 insert into auth.users(id,email,email_confirmed_at) values(newuser,'capacity@example.test',clock_timestamp());
 begin insert into public.company_memberships(tenant_id,user_id,status,branch_access_mode,created_by_user_id) values(t,newuser,'pending','all_branches',u); raise exception 'pending user capacity bypass'; exception when check_violation then null; end;
 insert into public.company_memberships(tenant_id,user_id,status,branch_access_mode,created_by_user_id) values(t,newuser,'suspended','all_branches',u);
 begin update public.company_memberships set status='active' where tenant_id=t and user_id=newuser; raise exception 'activation capacity bypass'; exception when check_violation then null; end;
 begin perform public.master_save_saas_plan('FINAL','Downgrade','active',1,1); raise exception 'plan downgrade below usage'; exception when check_violation then null; end;
 if before_grants<>(select count(*) from public.company_role_permission_grants where tenant_id=t) then raise exception 'SaaS changed permissions'; end if;
end;$saas$;

do $billing$
declare t uuid:='e1100000-0000-4000-8000-000000000001'; b uuid:='e1200000-0000-4000-8000-000000000001'; u uuid:='e1300000-0000-4000-8000-000000000001'; customer uuid:=gen_random_uuid(); bill uuid:=gen_random_uuid(); second_bill uuid:=gen_random_uuid(); request uuid:=gen_random_uuid(); obligation uuid; manual_obligation uuid; settlement uuid; installment uuid; count_before integer;
begin
 insert into public.business_parties(id,tenant_id,party_type,legal_name,request_id,created_by_user_id) values(customer,t,'customer','Final customer',gen_random_uuid(),u);
 insert into public.commercial_billing_documents(id,tenant_id,branch_id,source_type,source_id,customer_id,source_number,total_amount,request_payload,request_id,issued_by_user_id) values(bill,t,b,'sales_order',gen_random_uuid(),customer,9001,100,'{}',gen_random_uuid(),u),(second_bill,t,b,'sales_order',gen_random_uuid(),customer,9002,80,'{}',gen_random_uuid(),u);
 select count(*) into count_before from public.treasury_bank_movements where tenant_id=t;
 obligation:=public.operational_integrate_billing_receivable(t,bill,'2026-11-28','30 e 60 dias','[{"due_date":"2026-12-28","amount":"40"},{"due_date":"2027-01-28","amount":"60"}]',request);
 if public.operational_integrate_billing_receivable(t,bill,'2026-11-28','30 e 60 dias','[{"due_date":"2026-12-28","amount":"40"},{"due_date":"2027-01-28","amount":"60"}]',request)<>obligation then raise exception 'billing replay failed'; end if;
 begin perform public.operational_integrate_billing_receivable(t,bill,'2026-11-28','Outra condição','[{"due_date":"2026-12-28","amount":"100"}]',gen_random_uuid()); raise exception 'billing duplicated'; exception when unique_violation then null; end;
 if (select count(*) from public.financial_installments where obligation_id=obligation)<>2 or not exists(select 1 from public.management_obligation_classifications where obligation_id=obligation and category='revenue') then raise exception 'installments/DRE classification missing'; end if;
 if count_before<>(select count(*) from public.treasury_bank_movements where tenant_id=t) then raise exception 'integration created bank facts'; end if;
 select id into installment from public.financial_installments where obligation_id=obligation and installment_number=1;
 settlement:=public.operational_settle_financial_installment(t,installment,20,'2026-11-28','bank',null,gen_random_uuid());
 begin perform public.operational_cancel_commercial_billing(t,bill,'Cancel with receipt',gen_random_uuid()); raise exception 'settled billing cancelled'; exception when object_not_in_prerequisite_state then null; end;
 perform public.operational_reverse_financial_settlement(t,settlement,'Explicit test reversal',gen_random_uuid());
 perform public.operational_cancel_commercial_billing(t,bill,'Cancel after reversal',gen_random_uuid());
 if (select status from public.financial_obligations where id=obligation)<>'cancelled' or exists(select 1 from public.financial_installments where obligation_id=obligation and status<>'cancelled') then raise exception 'linked cancellation not atomic'; end if;
 if exists(select 1 from jsonb_array_elements(public.operational_get_management_report(t,b,'2026-11-01','2026-11-30')->'dre') r where (r->>'amount')::numeric<>0) then raise exception 'cancelled revenue still in DRE'; end if;
 manual_obligation:=public.operational_create_financial_obligation(t,b,'receivable',customer,'Existing manual obligation','2026-11-28','[{"due_date":"2026-12-28","amount":80}]',gen_random_uuid());
 begin perform public.operational_integrate_billing_receivable(t,second_bill,'2026-11-28','30 dias','[{"due_date":"2026-12-28","amount":"80"}]',gen_random_uuid()); raise exception 'manual obligation duplicate'; exception when unique_violation then null; end;
 perform public.operational_integrate_billing_receivable(t,second_bill,'2026-11-28','Existing agreed terms','[]',gen_random_uuid(),manual_obligation);
 if exists(select 1 from public.management_obligation_classifications where obligation_id=manual_obligation) then raise exception 'historical classification changed'; end if;
end;$billing$;

do $ofx$
declare t uuid:='e1100000-0000-4000-8000-000000000001'; b uuid:='e1200000-0000-4000-8000-000000000001'; account uuid; movement uuid; line_id uuid; result jsonb; lines jsonb:='[{"fit_id":"FIT-001","posted_on":"2026-11-28","amount":"35","description":"OFX receipt","reference":"R1"}]';
begin
 select id into account from public.treasury_bank_accounts where tenant_id=t and code='CONC01';
 perform public.operational_bind_ofx_bank_account(t,account,'001','123','456');
 movement:=public.operational_record_bank_movement(t,account,'in',35,'2026-11-28','Receipt R1',gen_random_uuid());
 result:=public.operational_import_ofx_statement(t,account,repeat('a',64),'001','123','456','BRL','2026-11-01','2026-11-30',lines);
 if (result->>'inserted_count')::int<>1 then raise exception 'OFX import failed'; end if;
 result:=public.operational_import_ofx_statement(t,account,repeat('a',64),'001','123','456','BRL','2026-11-01','2026-11-30',lines);
 if not (result->>'replayed')::boolean or (result->>'inserted_count')::int<>0 then raise exception 'OFX replay failed'; end if;
 result:=public.operational_import_ofx_statement(t,account,repeat('b',64),'001','123','456','BRL','2026-11-01','2026-11-30',lines);
 if (result->>'inserted_count')::int<>0 then raise exception 'FITID overlap duplicated'; end if;
 begin perform public.operational_import_ofx_statement(t,account,repeat('c',64),'001','123','999','BRL','2026-11-01','2026-11-30',lines); raise exception 'wrong account imported'; exception when check_violation then null; end;
 begin perform public.operational_import_ofx_statement(t,account,repeat('a',64),'001','123','456','BRL','2026-11-01','2026-11-30',jsonb_set(lines,'{0,amount}','"36"')); raise exception 'divergent same hash accepted'; exception when unique_violation then null; end;
 select id into line_id from public.treasury_ofx_lines where tenant_id=t and fit_id='FIT-001';
 if (select reconciled_at from public.treasury_bank_movements where id=movement) is not null then raise exception 'OFX auto-reconciled'; end if;
 result:=public.operational_get_ofx_reconciliation(t,b,'2026-11-01','2026-11-30');
 if jsonb_array_length(result->'lines'->0->'suggestions')<>1 then raise exception 'matching suggestion absent'; end if;
 perform public.operational_confirm_ofx_reconciliation(t,line_id,movement,false);
 perform public.operational_confirm_ofx_reconciliation(t,line_id,movement,false);
 perform public.operational_unreconcile_bank_movement(t,movement,'OFX:'||line_id,'Correct reconciliation locally');
 if (select matched_movement_id from public.treasury_ofx_lines where id=line_id) is not null then raise exception 'OFX unmatch stale'; end if;
end;$ofx$;

do $reports$
declare t uuid:='e1100000-0000-4000-8000-000000000001'; b uuid:='e1200000-0000-4000-8000-000000000001'; kind text; result jsonb;
begin
 foreach kind in array array['purchases','sales','inventory','finance','banks','work_orders'] loop
 result:=public.operational_get_report(t,b,kind,'2026-11-01','2026-11-30',null,null,5000,0,true);
 if jsonb_typeof(result->'rows')<>'array' then raise exception 'Invalid report %',kind; end if;
 end loop;
 result:=public.operational_get_report(t,b,'banks','2026-11-01','2026-11-30',null,'OFX',100,0,false);
 if (result->>'total_count')::int<>0 then raise exception 'report search did not filter persisted description'; end if;
 begin perform public.operational_get_report(t,'e1200000-0000-4000-8000-000000000002','banks','2026-11-01','2026-11-30'); raise exception 'report crossed branch'; exception when insufficient_privilege then null; end;
 update public.company_transaction_availability set enabled=false where tenant_id=t and transaction_code='ZGE02';
 begin perform public.operational_get_report(t,b,'banks','2026-11-01','2026-11-30',null,null,5000,0,true); raise exception 'export bypassed authorization'; exception when insufficient_privilege then null; end;
 if has_table_privilege('authenticated','public.treasury_ofx_lines','select,insert,update') or has_function_privilege('anon','public.operational_get_report(uuid,uuid,text,date,date,text,text,integer,integer,boolean)','execute') then raise exception 'Final ACL failure'; end if;
end;$reports$;
rollback;
