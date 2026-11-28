-- Disposable PostgreSQL fixture only; not a deployment migration.
select set_config('request.jwt.claim.role','authenticated',false);
select set_config('request.jwt.claim.sub','e1300000-0000-4000-8000-000000000001',false);
insert into app_private.master_admins(user_id,status,authorized_by_user_id,authorization_reason,approval_reference) values('e1300000-0000-4000-8000-000000000001','active','e1300000-0000-4000-8000-000000000001','Capacity isolated fixture','LOCAL-CAPACITY');
select public.master_save_saas_plan('CAPACITY','Concurrency plan','active',3,2);
select public.master_manage_saas_subscription('e1100000-0000-4000-8000-000000000001',(select id from public.saas_plans where code='CAPACITY'),'pending','Local concurrency setup');
select public.master_manage_saas_subscription('e1100000-0000-4000-8000-000000000001',(select id from public.saas_plans where code='CAPACITY'),'active','Local concurrency setup');
insert into auth.users(id,email,email_confirmed_at) values('e1500000-0000-4000-8000-000000000001','capacity-first@example.test',clock_timestamp()),('e1500000-0000-4000-8000-000000000002','capacity-second@example.test',clock_timestamp());
create function app_private.test_final_capacity(p_kind text,p_second boolean) returns void language plpgsql as $test$
begin
 if p_kind='branch' then insert into public.branches(tenant_id,code,name,status) values('e1100000-0000-4000-8000-000000000001',case when p_second then 'CAP_B' else 'CAP_A' end,'Capacity fixture','active');
 else insert into public.company_memberships(tenant_id,user_id,status,branch_access_mode,created_by_user_id) values('e1100000-0000-4000-8000-000000000001',case when p_second then 'e1500000-0000-4000-8000-000000000002'::uuid else 'e1500000-0000-4000-8000-000000000001'::uuid end,'pending','all_branches','e1300000-0000-4000-8000-000000000001'); end if;
 if p_second then raise exception 'Concurrent contractual capacity exceeded'; end if;
exception when check_violation then if not p_second then raise; end if;
end;$test$;
