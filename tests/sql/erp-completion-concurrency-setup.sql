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

select public.operational_create_bank_account('e1100000-0000-4000-8000-000000000001','e1200000-0000-4000-8000-000000000001','CONC01','Concurrency one','checking',100,gen_random_uuid());
select public.operational_create_bank_account('e1100000-0000-4000-8000-000000000001','e1200000-0000-4000-8000-000000000001','CONC02','Concurrency two','checking',100,gen_random_uuid());
commit;
