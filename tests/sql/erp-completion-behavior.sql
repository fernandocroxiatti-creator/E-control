begin;
-- All grants below are synthetic fixtures inside the disposable local database.
do $setup$
declare t uuid:='e1100000-0000-4000-8000-000000000001'; b uuid:='e1200000-0000-4000-8000-000000000001'; u uuid:='e1300000-0000-4000-8000-000000000001'; m uuid:='e1400000-0000-4000-8000-000000000001';
begin
 insert into auth.users(id,email,email_confirmed_at) values(u,'completion@example.test',clock_timestamp());
 insert into public.companies(id,legal_name,status) values(t,'Completion local test','active'),('e1100000-0000-4000-8000-000000000002','Other local tenant','active');
 insert into public.branches(id,tenant_id,code,name,status) values(b,t,'TEST','Local branch','active'),('e1200000-0000-4000-8000-000000000002',t,'OTHER','Other branch','active');
 insert into public.company_memberships(id,tenant_id,user_id,status,branch_access_mode,created_by_user_id) values(m,t,u,'active','all_branches',u);
 insert into public.access_role_definitions(role_key,display_name,scope,approval_state) values('completion_test','Local completion','company','approved');
 insert into public.membership_role_assignments(tenant_id,membership_id,role_key,assigned_by_user_id) values(t,m,'completion_test',u);
 if exists(select 1 from public.erp_transaction_authorization_catalog where transaction_code in ('ZTR02','ZTR03','ZTR04','ZTR05','ZGE01','ZGE02') and approval_state<>'pending_approval') then raise exception 'new transactions must start pending'; end if;
 update public.permission_definitions set approval_state='approved' where permission_key like 'transaction.treasury.%' or permission_key like 'transaction.management.%' or permission_key like 'transaction.finance.%';
 update public.erp_transaction_authorization_catalog set approval_state='approved' where transaction_code in ('ZTR02','ZTR03','ZTR04','ZTR05','ZGE01','ZGE02','ZFI01','ZFI02','ZFI03','ZFI04');
 insert into public.company_module_availability(tenant_id,module_code,enabled,changed_by_user_id) select t,x,true,u from unnest(array['TSY','MGT','FIN']) x;
 insert into public.company_transaction_availability(tenant_id,transaction_code,enabled,changed_by_user_id) select t,transaction_code,true,u from public.erp_transaction_authorization_catalog where transaction_code in ('ZTR02','ZTR03','ZTR04','ZTR05','ZGE01','ZGE02','ZFI01','ZFI02','ZFI03','ZFI04');
 insert into public.company_role_permission_grants(tenant_id,branch_id,grant_scope,role_key,permission_key,reason,created_by_user_id) select t,b,'branch','completion_test',permission_key,'Local isolated test only',u from public.permission_definitions where permission_key like 'transaction.treasury.%' or permission_key like 'transaction.management.%' or permission_key like 'transaction.finance.%';
end;$setup$;
select set_config('request.jwt.claim.role','authenticated',false);
select set_config('request.jwt.claim.sub','e1300000-0000-4000-8000-000000000001',false);

do $bank$
declare t uuid:='e1100000-0000-4000-8000-000000000001'; b uuid:='e1200000-0000-4000-8000-000000000001'; a uuid; z uuid; transfer uuid; movement uuid; req uuid:=gen_random_uuid(); report jsonb; count_before integer;
begin
 a:=public.operational_create_bank_account(t,b,'BB01','Banco um','checking',100,req);
 if public.operational_create_bank_account(t,b,'BB01','Banco um','checking',100,req)<>a then raise exception 'account replay failed'; end if;
 begin perform public.operational_create_bank_account(t,b,'BB01','Banco outro','checking',100,req); raise exception 'divergent replay allowed'; exception when unique_violation then null; end;
 begin perform public.operational_create_bank_account(t,b,'BAD','Invalid bank','checking','NaN',gen_random_uuid()); raise exception 'NaN allowed'; exception when invalid_parameter_value then null; end;
 begin perform public.operational_create_bank_account(t,'e1200000-0000-4000-8000-000000000002','BAD','Wrong branch','checking',0,gen_random_uuid()); raise exception 'cross branch allowed'; exception when insufficient_privilege then null; end;
 z:=public.operational_create_bank_account(t,b,'BB02','Banco dois','checking',0,gen_random_uuid());
 req:=gen_random_uuid();
 transfer:=public.operational_transfer_bank_funds(t,a,z,30,'2026-11-27','Transfer test',req);
 if public.operational_transfer_bank_funds(t,a,z,30,'2026-11-27','Transfer test',req)<>transfer then raise exception 'transfer replay failed'; end if;
 if (select count(*) from public.treasury_bank_movements where tenant_id=t)<>2 or (select sum(case direction when 'in' then amount else -amount end) from public.treasury_bank_movements where tenant_id=t)<>0 then raise exception 'unbalanced transfer'; end if;
 begin perform public.operational_transfer_bank_funds(t,a,a,30,'2026-11-27','Same account',gen_random_uuid()); raise exception 'same account allowed'; exception when invalid_parameter_value then null; end;
 begin perform public.operational_reconcile_bank_movement(t,transfer,'STMT-001',30,'2026-11-27'); raise exception 'wrong sign reconciled'; exception when check_violation then null; end;
 perform public.operational_reconcile_bank_movement(t,transfer,'STMT-001',-30,'2026-11-27');
 perform public.operational_reconcile_bank_movement(t,transfer,'STMT-001',-30,'2026-11-27');
 begin perform public.operational_reconcile_bank_movement(t,transfer,'STMT-002',-30,'2026-11-27'); raise exception 'reconciliation overwritten'; exception when unique_violation then null; end;
 begin perform public.operational_update_bank_account(t,a,'Renamed account','inactive','Local deactivate account'); raise exception 'nonzero account deactivated'; exception when object_not_in_prerequisite_state then null; end;
 perform public.operational_update_bank_account(t,a,'Renamed account','active','Local rename account');
 perform public.operational_unreconcile_bank_movement(t,transfer,'STMT-001','Local reconciliation correction');
 if (select reconciled_at from public.treasury_bank_movements where id=transfer) is not null then raise exception 'unreconcile failed'; end if;
 perform public.operational_reconcile_bank_movement(t,transfer,'STMT-001',-30,'2026-11-27');
 req:=gen_random_uuid(); movement:=public.operational_record_bank_movement(t,a,'in',15,'2026-11-27','External deposit',req);
 if public.operational_record_bank_movement(t,a,'in',15,'2026-11-27','External deposit',req)<>movement then raise exception 'deposit replay failed'; end if;
 begin perform public.operational_reconcile_bank_movement(t,movement,'STMT-001',15,'2026-11-27'); raise exception 'statement reused'; exception when unique_violation then null; end;
 report:=public.operational_get_bank_treasury(t,b,'2026-11-01','2026-11-30');
 if (report->'accounts'->0->>'balance')::numeric<>85 or (report->'accounts'->1->>'balance')::numeric<>30 or jsonb_array_length(report->'movements')<>3 then raise exception 'bank read totals incorrect: %',report; end if;
 begin perform public.operational_get_bank_treasury('e1100000-0000-4000-8000-000000000002',b,'2026-11-01','2026-11-30'); raise exception 'cross tenant read allowed'; exception when insufficient_privilege then null; end;
 update public.company_module_availability set enabled=false where tenant_id=t and module_code='TSY';
 begin perform public.operational_get_bank_treasury(t,b,'2026-11-01','2026-11-30'); raise exception 'disabled module read allowed'; exception when insufficient_privilege then null; end;
 update public.company_module_availability set enabled=true where tenant_id=t and module_code='TSY';
 select count(*) into count_before from public.financial_settlements where tenant_id=t;
 if count_before<>0 then raise exception 'bank unexpectedly settled obligation'; end if;
end;$bank$;

do $management$
declare t uuid:='e1100000-0000-4000-8000-000000000001'; b uuid:='e1200000-0000-4000-8000-000000000001'; o uuid; installment uuid; settlement uuid; report jsonb; summary record;
begin
 o:=public.operational_create_financial_obligation(t,b,'receivable',null,'Reporting revenue','2026-11-27','[{"due_date":"2026-11-28","amount":100}]'::jsonb,gen_random_uuid());
 report:=public.operational_get_management_report(t,b,'2026-11-01','2026-11-30');
 if (report->>'unclassified')::integer<>1 or jsonb_array_length(report->'dre')<>0 then raise exception 'unclassified obligation hidden'; end if;
 perform public.operational_classify_financial_result(t,o,'revenue','2026-11-27','Local classification reason');
 select id into installment from public.financial_installments where obligation_id=o;
 settlement:=public.operational_settle_financial_installment(t,installment,40,'2026-11-27','bank',null,gen_random_uuid());
 report:=public.operational_get_management_report(t,b,'2026-11-01','2026-11-30',true);
 if (report->'dre'->0->>'amount')::numeric<>100 or (report->>'receivable_open')::numeric<>60 or (report->'cash_flow'->0->>'receipts')::numeric<>40 then raise exception 'management totals wrong %',report; end if;
 perform public.operational_reverse_financial_settlement(t,settlement,'Reverse local settlement',gen_random_uuid());
 report:=public.operational_get_management_report(t,b,'2026-11-01','2026-11-30');
 if (report->>'receivable_open')::numeric<>100 or exists(select 1 from jsonb_array_elements(report->'cash_flow') r where (r->>'receipts')::numeric<>0) then raise exception 'reversed settlement counted'; end if;
 select * into summary from public.operational_get_management_summary(t,b,'2026-11-01','2026-11-30');
 if summary.settled_receivable<>0 then raise exception 'summary includes reversal'; end if;
 update public.company_transaction_availability set enabled=false where tenant_id=t and transaction_code='ZGE02';
 begin perform public.operational_get_management_report(t,b,'2026-11-01','2026-11-30',true); raise exception 'export permission bypass'; exception when insufficient_privilege then null; end;
 begin perform public.operational_get_management_report(t,'e1200000-0000-4000-8000-000000000002','2026-11-01','2026-11-30'); raise exception 'branch report bypass'; exception when insufficient_privilege then null; end;
end;$management$;

do $saas$
declare t uuid:='e1100000-0000-4000-8000-000000000001'; actor uuid:='e1300000-0000-4000-8000-000000000001'; plan uuid; subscription uuid; events integer; grants_before integer; started timestamptz;
begin
 begin perform public.master_save_saas_plan('TEST','Test Plan','active',10,10); raise exception 'non master allowed'; exception when insufficient_privilege then null; end;
 insert into app_private.master_admins(user_id,status,authorized_by_user_id,authorization_reason,approval_reference) values(actor,'active',actor,'Isolated local fixture only','LOCAL-COMPLETION');
 plan:=public.master_save_saas_plan('TEST','Test Plan','active',10,10);
 begin perform public.master_manage_saas_subscription(t,plan,'active','Local invalid transition'); raise exception 'subscription skipped pending'; exception when object_not_in_prerequisite_state then null; end;
 subscription:=public.master_manage_saas_subscription(t,plan,'pending','Local create subscription');
 begin perform public.master_manage_saas_subscription(t,plan,'active',null); raise exception 'null reason allowed'; exception when invalid_parameter_value then null; end;
 select count(*) into grants_before from public.company_role_permission_grants where tenant_id=t;
 perform public.master_manage_saas_subscription(t,plan,'active','Local activate subscription');
 select starts_at into started from public.saas_subscriptions where id=subscription;
 perform public.master_manage_saas_subscription(t,plan,'active','Local retry subscription');
 if (select count(*) from public.saas_subscription_events where subscription_id=subscription)<>2 then raise exception 'duplicate subscription event'; end if;
 perform public.master_manage_saas_subscription(t,plan,'suspended','Local suspend subscription');
 perform public.master_manage_saas_subscription(t,plan,'active','Local reactivate subscription');
 if (select starts_at from public.saas_subscriptions where id=subscription) is distinct from started or not exists(select 1 from public.saas_subscription_events where subscription_id=subscription and event_key='reactivated') then raise exception 'subscription lifecycle incorrect'; end if;
 perform public.master_manage_saas_subscription(t,plan,'cancelled','Local cancel subscription');
 if (select ends_at from public.saas_subscriptions where id=subscription) is null then raise exception 'cancel timestamp missing'; end if;
 begin perform public.master_manage_saas_subscription(t,plan,'active','Local illegal resurrection'); raise exception 'cancelled resurrected'; exception when object_not_in_prerequisite_state then null; end;
 if (select count(*) from public.company_role_permission_grants where tenant_id=t)<>grants_before then raise exception 'SaaS changed permissions'; end if;
 if jsonb_array_length(public.master_get_saas_control_plane()->'plans')<>1 then raise exception 'SaaS read failed'; end if;
end;$saas$;

do $acl$
declare name text;
begin
 foreach name in array array['treasury_bank_accounts','treasury_bank_movements','management_obligation_classifications','saas_plans','saas_subscriptions','saas_subscription_events'] loop
 if not (select relrowsecurity and relforcerowsecurity from pg_class where oid=('public.'||name)::regclass) or has_table_privilege('authenticated','public.'||name,'select,insert,update,delete') then raise exception 'table ACL failure %',name; end if;
 end loop;
 if has_function_privilege('anon','public.operational_get_bank_treasury(uuid,uuid,date,date,integer)','execute') or has_function_privilege('service_role','public.master_manage_saas_subscription(uuid,uuid,text,text)','execute') then raise exception 'broad function grant'; end if;
end;$acl$;
rollback;
