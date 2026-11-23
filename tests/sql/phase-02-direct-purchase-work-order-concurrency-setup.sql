-- Persistent only inside the disposable PostgreSQL container created by the
-- package runner.  It exercises the production authorization path; unlike the
-- behavioral fixture, it does not replace any authorization helper.
insert into auth.users(id,email,email_confirmed_at) values
  ('d2200000-0000-4000-8000-000000000001','phase02-concurrency@example.test',clock_timestamp());
insert into public.companies(id,legal_name,status)
values ('d2000000-0000-4000-8000-000000000001','Phase 02 concurrency','active');
insert into public.branches(id,tenant_id,code,name,status)
values ('d2100000-0000-4000-8000-000000000001','d2000000-0000-4000-8000-000000000001','P02C','Phase 02 concurrency branch','active');
insert into public.company_memberships(id,tenant_id,user_id,status,branch_access_mode,created_by_user_id)
values ('d2300000-0000-4000-8000-000000000001','d2000000-0000-4000-8000-000000000001','d2200000-0000-4000-8000-000000000001','active','all_branches','d2200000-0000-4000-8000-000000000001');
insert into public.access_role_definitions(role_key,display_name,scope,approval_state)
values ('phase02_concurrency_owner','Phase 02 concurrency owner','company','approved');
insert into public.membership_role_assignments(tenant_id,membership_id,role_key,branch_id,assigned_by_user_id)
values ('d2000000-0000-4000-8000-000000000001','d2300000-0000-4000-8000-000000000001','phase02_concurrency_owner',null,'d2200000-0000-4000-8000-000000000001');
update public.permission_definitions set approval_state='approved'
where permission_key in ('transaction.service_order.create','transaction.service_order.update','transaction.service_order.read');
insert into public.role_permission_grants(role_key,permission_key) values
  ('phase02_concurrency_owner','transaction.service_order.create'),
  ('phase02_concurrency_owner','transaction.service_order.update'),
  ('phase02_concurrency_owner','transaction.service_order.read');
update public.erp_transaction_authorization_catalog set approval_state='approved'
where transaction_code in ('ZOS01','ZOS02','ZOS03');
insert into public.company_module_availability(tenant_id,module_code,enabled,changed_by_user_id)
values ('d2000000-0000-4000-8000-000000000001','SVC',true,'d2200000-0000-4000-8000-000000000001');
insert into public.company_transaction_availability(tenant_id,transaction_code,enabled,changed_by_user_id) values
  ('d2000000-0000-4000-8000-000000000001','ZOS01',true,'d2200000-0000-4000-8000-000000000001'),
  ('d2000000-0000-4000-8000-000000000001','ZOS02',true,'d2200000-0000-4000-8000-000000000001'),
  ('d2000000-0000-4000-8000-000000000001','ZOS03',true,'d2200000-0000-4000-8000-000000000001');
insert into public.business_parties(id,tenant_id,party_type,legal_name,request_id,created_by_user_id) values
  ('d2400000-0000-4000-8000-000000000001','d2000000-0000-4000-8000-000000000001','customer','Phase 02 concurrency customer','d2500000-0000-4000-8000-000000000001','d2200000-0000-4000-8000-000000000001'),
  ('d2400000-0000-4000-8000-000000000002','d2000000-0000-4000-8000-000000000001','supplier','Phase 02 concurrency supplier','d2500000-0000-4000-8000-000000000002','d2200000-0000-4000-8000-000000000001');
select set_config('request.jwt.claim.role','authenticated',false);
select set_config('request.jwt.claim.sub','d2200000-0000-4000-8000-000000000001',false);
select public.operational_create_work_order(
  'd2000000-0000-4000-8000-000000000001',
  'd2100000-0000-4000-8000-000000000001',
  'd2400000-0000-4000-8000-000000000001',
  null,
  'Phase 02 direct-purchase concurrency',
  'd2700000-0000-4000-8000-000000000001'
);
