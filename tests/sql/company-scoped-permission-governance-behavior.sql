-- Isolated verification of the company-and-branch-scoped governance layer.
-- This fixture creates no Phase 1 receipt, financial entry or cross-tenant grant.
begin;

insert into auth.users (id, email, email_confirmed_at) values
  ('e1000000-0000-4000-8000-000000000001', 'scoped-master@example.test', clock_timestamp()),
  ('e1000000-0000-4000-8000-000000000002', 'scoped-owner-a@example.test', clock_timestamp()),
  ('e1000000-0000-4000-8000-000000000003', 'scoped-owner-b@example.test', clock_timestamp()),
  ('e1000000-0000-4000-8000-000000000004', 'scoped-unprivileged@example.test', clock_timestamp());
insert into app_private.master_admins(user_id, status, authorized_by_user_id, authorization_reason, approval_reference)
values ('e1000000-0000-4000-8000-000000000001', 'active', 'e1000000-0000-4000-8000-000000000001', 'Isolated scoped-governance test', 'TEST-SCOPED-GOV-01');
insert into public.companies(id, legal_name, status) values
  ('e2000000-0000-4000-8000-000000000001', 'Scoped Pilot A', 'active'),
  ('e2000000-0000-4000-8000-000000000002', 'Scoped Pilot B', 'active');
insert into public.branches(id, tenant_id, code, name, status) values
  ('e3000000-0000-4000-8000-000000000001', 'e2000000-0000-4000-8000-000000000001', 'A01', 'Pilot A one', 'active'),
  ('e3000000-0000-4000-8000-000000000002', 'e2000000-0000-4000-8000-000000000001', 'A02', 'Pilot A two', 'active'),
  ('e3000000-0000-4000-8000-000000000003', 'e2000000-0000-4000-8000-000000000002', 'B01', 'Pilot B one', 'active');
insert into public.access_role_definitions(role_key, display_name, scope, approval_state)
values ('company_owner', 'Proprietário empresarial', 'company', 'approved')
on conflict (role_key) do update set approval_state = 'approved';
insert into public.company_memberships(id, tenant_id, user_id, status, branch_access_mode, created_by_user_id) values
  ('e4000000-0000-4000-8000-000000000001', 'e2000000-0000-4000-8000-000000000001', 'e1000000-0000-4000-8000-000000000002', 'active', 'all_branches', 'e1000000-0000-4000-8000-000000000001'),
  ('e4000000-0000-4000-8000-000000000002', 'e2000000-0000-4000-8000-000000000002', 'e1000000-0000-4000-8000-000000000003', 'active', 'all_branches', 'e1000000-0000-4000-8000-000000000001');
insert into public.membership_role_assignments(tenant_id, membership_id, role_key, branch_id, assigned_by_user_id) values
  ('e2000000-0000-4000-8000-000000000001', 'e4000000-0000-4000-8000-000000000001', 'company_owner', null, 'e1000000-0000-4000-8000-000000000001'),
  ('e2000000-0000-4000-8000-000000000002', 'e4000000-0000-4000-8000-000000000002', 'company_owner', null, 'e1000000-0000-4000-8000-000000000001');

do $test$
declare
  audit_reason text;
  revoke_outcome text;
begin
  perform set_config('request.jwt.claim.role', 'authenticated', true);
  perform set_config('request.jwt.claim.sub', 'e1000000-0000-4000-8000-000000000004', true);
  if pg_catalog.to_regprocedure('public.master_set_access_catalog_approval(text,text,text)') is not null
    or pg_catalog.to_regprocedure('public.master_set_role_permission_grant(text,text,text)') is not null
    or pg_catalog.to_regprocedure('public.master_set_company_transaction_availability(uuid,text[])') is not null then
    raise exception 'legacy governance RPC signatures remained executable without a justification';
  end if;
  begin
    perform public.master_set_access_catalog_approval('transaction', 'ZGR01', 'approved', 'Unauthorized test');
    raise exception 'unprivileged user approved catalog access';
  exception when insufficient_privilege then null;
  end;

  perform set_config('request.jwt.claim.sub', 'e1000000-0000-4000-8000-000000000001', true);
  begin
    perform public.master_set_access_catalog_approval('transaction', 'ZGR01', 'approved', 'short');
    raise exception 'catalog approval accepted missing justification';
  exception when invalid_parameter_value then null;
  end;
  if public.master_set_access_catalog_approval('permission', 'transaction.purchasing.receipt.manage', 'approved', 'Pilot receipt permission review') <> 'approved'
    or public.master_set_access_catalog_approval('transaction', 'ZGR01', 'approved', 'Pilot receipt transaction review') <> 'approved' then
    raise exception 'Master did not approve the scoped pilot catalog items';
  end if;
  begin
    perform public.master_set_company_transaction_availability('e2000000-0000-4000-8000-000000000001', array['ZGR01'], 'short');
    raise exception 'company availability accepted missing justification';
  exception when invalid_parameter_value then null;
  end;
  if public.master_set_company_transaction_availability('e2000000-0000-4000-8000-000000000001', array['ZGR01'], 'Pilot company receipt availability') <> 'updated' then
    raise exception 'Master did not enable scoped pilot availability';
  end if;
  begin
    perform public.master_set_company_role_permission_grant('e2000000-0000-4000-8000-000000000001', 'e3000000-0000-4000-8000-000000000001', 'company_owner', 'transaction.inventory.valuation.initial', 'grant', 'Attempt to grant an out-of-scope permission');
    raise exception 'scoped governance accepted a non-ZGR01 permission';
  exception when invalid_parameter_value then null;
  end;
  begin
    perform public.master_set_company_role_permission_grant('e2000000-0000-4000-8000-000000000001', 'e3000000-0000-4000-8000-000000000001', 'company_owner', 'transaction.purchasing.receipt.manage', 'grant', 'short');
    raise exception 'scoped grant accepted missing justification';
  exception when invalid_parameter_value then null;
  end;
  if public.master_set_company_role_permission_grant('e2000000-0000-4000-8000-000000000001', 'e3000000-0000-4000-8000-000000000001', 'company_owner', 'transaction.purchasing.receipt.manage', 'grant', 'Pilot branch receipt authorization') <> 'grant'
    or public.master_set_company_role_permission_grant('e2000000-0000-4000-8000-000000000001', 'e3000000-0000-4000-8000-000000000001', 'company_owner', 'transaction.purchasing.receipt.manage', 'grant', 'Pilot branch receipt authorization') <> 'unchanged' then
    raise exception 'scoped grant was not idempotent';
  end if;
  if exists (select 1 from public.role_permission_grants where role_key = 'company_owner' and permission_key = 'transaction.purchasing.receipt.manage') then
    raise exception 'scoped grant accidentally became global';
  end if;
  select details->>'reason' into audit_reason from app_private.provisioning_audit_events
    where event_key = 'master_company_role_permission.grant'
      and tenant_id = 'e2000000-0000-4000-8000-000000000001'
    order by created_at desc limit 1;
  if audit_reason <> 'Pilot branch receipt authorization' then
    raise exception 'scoped grant justification was not audited';
  end if;

  perform set_config('request.jwt.claim.sub', 'e1000000-0000-4000-8000-000000000002', true);
  if not app_private.has_tenant_permission('e2000000-0000-4000-8000-000000000001', 'transaction.purchasing.receipt.manage', 'e3000000-0000-4000-8000-000000000001')
    or not public.authorize_company_transaction('e2000000-0000-4000-8000-000000000001', 'e3000000-0000-4000-8000-000000000001', 'ZGR01') then
    raise exception 'pilot company owner did not receive the exact scoped authorization';
  end if;
  if app_private.has_tenant_permission('e2000000-0000-4000-8000-000000000001', 'transaction.purchasing.receipt.manage', 'e3000000-0000-4000-8000-000000000002')
    or public.authorize_company_transaction('e2000000-0000-4000-8000-000000000001', 'e3000000-0000-4000-8000-000000000002', 'ZGR01')
    or public.authorize_company_transaction('e2000000-0000-4000-8000-000000000001', 'e3000000-0000-4000-8000-000000000001', 'ZIV01') then
    raise exception 'branch isolation or ZIV01 default denial failed';
  end if;

  perform set_config('request.jwt.claim.sub', 'e1000000-0000-4000-8000-000000000003', true);
  if app_private.has_tenant_permission('e2000000-0000-4000-8000-000000000002', 'transaction.purchasing.receipt.manage', 'e3000000-0000-4000-8000-000000000003')
    or public.authorize_company_transaction('e2000000-0000-4000-8000-000000000002', 'e3000000-0000-4000-8000-000000000003', 'ZGR01') then
    raise exception 'company scoped grant leaked to another tenant';
  end if;

  perform set_config('request.jwt.claim.sub', 'e1000000-0000-4000-8000-000000000001', true);
  revoke_outcome := public.master_set_company_role_permission_grant(
    'e2000000-0000-4000-8000-000000000001',
    'e3000000-0000-4000-8000-000000000001',
    'company_owner',
    'transaction.purchasing.receipt.manage',
    'revoke',
    'Pilot grant revoked after isolated verification'
  );
  if revoke_outcome <> 'revoke' then
    raise exception 'scoped grant revocation did not report a persisted change';
  end if;
  if exists (
      select 1 from public.company_role_permission_grants
      where tenant_id = 'e2000000-0000-4000-8000-000000000001'
        and branch_id = 'e3000000-0000-4000-8000-000000000001'
        and role_key = 'company_owner'
        and permission_key = 'transaction.purchasing.receipt.manage'
    ) then
    raise exception 'scoped grant revocation was not persisted';
  end if;
  select details->>'reason' into audit_reason from app_private.provisioning_audit_events
    where event_key = 'master_company_role_permission.revoke'
      and tenant_id = 'e2000000-0000-4000-8000-000000000001'
    order by created_at desc limit 1;
  if audit_reason <> 'Pilot grant revoked after isolated verification' then
    raise exception 'scoped grant revocation justification was not audited';
  end if;
end;
$test$;

commit;
