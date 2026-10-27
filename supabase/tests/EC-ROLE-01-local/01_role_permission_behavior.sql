begin;

insert into auth.users (id, email, email_confirmed_at) values
  ('41000000-0000-4000-8000-000000000001', 'role-owner@example.invalid', pg_catalog.now()),
  ('41000000-0000-4000-8000-000000000002', 'role-manager@example.invalid', pg_catalog.now()),
  ('41000000-0000-4000-8000-000000000003', 'role-operator@example.invalid', pg_catalog.now()),
  ('41000000-0000-4000-8000-000000000004', 'role-unlinked@example.invalid', pg_catalog.now()),
  ('41000000-0000-4000-8000-000000000005', 'role-other-company@example.invalid', pg_catalog.now());

insert into public.companies (id, legal_name, status) values
  ('42000000-0000-4000-8000-000000000001', 'Role Test Company A', 'active'),
  ('42000000-0000-4000-8000-000000000002', 'Role Test Company B', 'active');
insert into public.branches (id, tenant_id, code, name, status) values
  ('43000000-0000-4000-8000-000000000001', '42000000-0000-4000-8000-000000000001', 'A1', 'A Branch 1', 'active'),
  ('43000000-0000-4000-8000-000000000002', '42000000-0000-4000-8000-000000000001', 'A2', 'A Branch 2', 'active'),
  ('43000000-0000-4000-8000-000000000003', '42000000-0000-4000-8000-000000000002', 'B1', 'B Branch 1', 'active');
insert into public.company_memberships
  (id, tenant_id, user_id, status, branch_access_mode, created_by_user_id) values
  ('44000000-0000-4000-8000-000000000001', '42000000-0000-4000-8000-000000000001', '41000000-0000-4000-8000-000000000001', 'active', 'all_branches', '41000000-0000-4000-8000-000000000001'),
  ('44000000-0000-4000-8000-000000000002', '42000000-0000-4000-8000-000000000001', '41000000-0000-4000-8000-000000000002', 'active', 'assigned_only', '41000000-0000-4000-8000-000000000001'),
  ('44000000-0000-4000-8000-000000000003', '42000000-0000-4000-8000-000000000001', '41000000-0000-4000-8000-000000000003', 'active', 'assigned_only', '41000000-0000-4000-8000-000000000001'),
  ('44000000-0000-4000-8000-000000000004', '42000000-0000-4000-8000-000000000002', '41000000-0000-4000-8000-000000000005', 'active', 'all_branches', '41000000-0000-4000-8000-000000000005');

update public.access_role_definitions set approval_state = 'approved'
where role_key in ('company_owner', 'company_manager', 'branch_operator');
update public.permission_definitions set approval_state = 'approved'
where permission_key in (
  'membership.role.assign', 'branch_access.manage',
  'transaction.purchasing.purchase_order.create',
  'transaction.purchasing.purchase_order.approve'
);
update public.erp_transaction_authorization_catalog set approval_state = 'approved'
where transaction_code = 'ME21N';
insert into public.role_permission_grants (role_key, permission_key) values
  ('company_owner', 'membership.role.assign'),
  ('company_owner', 'branch_access.manage'),
  ('company_owner', 'transaction.purchasing.purchase_order.create'),
  ('company_owner', 'transaction.purchasing.purchase_order.approve'),
  ('company_manager', 'membership.role.assign'),
  ('company_manager', 'transaction.purchasing.purchase_order.create'),
  ('branch_operator', 'transaction.purchasing.purchase_order.create');
insert into public.membership_role_assignments
  (tenant_id, membership_id, role_key, branch_id, assigned_by_user_id) values
  ('42000000-0000-4000-8000-000000000001', '44000000-0000-4000-8000-000000000001', 'company_owner', null, '41000000-0000-4000-8000-000000000001'),
  ('42000000-0000-4000-8000-000000000002', '44000000-0000-4000-8000-000000000004', 'company_owner', null, '41000000-0000-4000-8000-000000000005');

do $test$
declare
  error_code text;
  role_insert_events integer;
  role_delete_events integer;
  branch_insert_events integer;
  branch_update_events integer;
begin
  perform pg_catalog.set_config('request.jwt.claim.role', 'authenticated', true);
  perform pg_catalog.set_config('request.jwt.claim.sub', '41000000-0000-4000-8000-000000000001', true);
  if public.is_current_user_master() is distinct from false then
    raise exception 'company owner unexpectedly has Admin Master access';
  end if;
  if public.authorize_company_transaction(
    '42000000-0000-4000-8000-000000000001', '43000000-0000-4000-8000-000000000001', 'ME21N'
  ) is distinct from true then raise exception 'company owner transaction permission failed'; end if;
  if public.authorize_company_transaction(
    '42000000-0000-4000-8000-000000000002', '43000000-0000-4000-8000-000000000003', 'ME21N'
  ) is distinct from false then raise exception 'company A identity crossed into company B'; end if;

  -- Owner may delegate only a role whose effective approved grants are a subset.
  if public.assign_company_membership_role(
    '42000000-0000-4000-8000-000000000001', '44000000-0000-4000-8000-000000000002', 'company_manager', null
  ) <> 'assigned' then raise exception 'bounded manager role assignment failed'; end if;
  if public.set_company_member_branch_access(
    '42000000-0000-4000-8000-000000000001', '44000000-0000-4000-8000-000000000002', '43000000-0000-4000-8000-000000000002', 'active'
  ) <> 'created' then raise exception 'manager branch scope setup failed'; end if;
  perform pg_catalog.set_config('request.jwt.claim.sub', '41000000-0000-4000-8000-000000000002', true);
  if public.authorize_company_transaction(
    '42000000-0000-4000-8000-000000000001', '43000000-0000-4000-8000-000000000002', 'ME21N'
  ) is distinct from true then raise exception 'company manager transaction authorization failed'; end if;
  perform pg_catalog.set_config('request.jwt.claim.sub', '41000000-0000-4000-8000-000000000001', true);
  if public.revoke_company_membership_role(
    '42000000-0000-4000-8000-000000000001', '44000000-0000-4000-8000-000000000002', 'company_manager', null
  ) <> 'revoked' then raise exception 'company manager role revocation failed'; end if;
  perform pg_catalog.set_config('request.jwt.claim.sub', '41000000-0000-4000-8000-000000000002', true);
  if public.authorize_company_transaction(
    '42000000-0000-4000-8000-000000000001', '43000000-0000-4000-8000-000000000002', 'ME21N'
  ) is distinct from false then raise exception 'revoked company role still authorizes transaction'; end if;
  perform pg_catalog.set_config('request.jwt.claim.sub', '41000000-0000-4000-8000-000000000001', true);
  begin
    perform public.assign_company_membership_role(
      '42000000-0000-4000-8000-000000000001', '44000000-0000-4000-8000-000000000002', 'company_owner', null
    );
    raise exception 'company_owner was assignable outside its one-time invitation flow';
  exception when insufficient_privilege then null;
  end;

  -- User without role cannot assign roles; no client-supplied tenant can bypass auth.uid().
  perform pg_catalog.set_config('request.jwt.claim.sub', '41000000-0000-4000-8000-000000000004', true);
  begin
    perform public.assign_company_membership_role(
      '42000000-0000-4000-8000-000000000001', '44000000-0000-4000-8000-000000000003', 'branch_operator', '43000000-0000-4000-8000-000000000001'
    );
    raise exception 'unlinked user assigned a company role';
  exception when insufficient_privilege then null;
  end;
  if public.authorize_company_transaction(
    '42000000-0000-4000-8000-000000000001', '43000000-0000-4000-8000-000000000001', 'ME21N'
  ) is distinct from false then raise exception 'unlinked user received transaction access'; end if;

  perform pg_catalog.set_config('request.jwt.claim.sub', '41000000-0000-4000-8000-000000000001', true);
  if public.set_company_member_branch_access(
    '42000000-0000-4000-8000-000000000001', '44000000-0000-4000-8000-000000000003', '43000000-0000-4000-8000-000000000001', 'active'
  ) <> 'created' then raise exception 'company owner could not scope branch access'; end if;
  if public.assign_company_membership_role(
    '42000000-0000-4000-8000-000000000001', '44000000-0000-4000-8000-000000000003', 'branch_operator', '43000000-0000-4000-8000-000000000001'
  ) <> 'assigned' then raise exception 'branch role assignment failed'; end if;
  perform pg_catalog.set_config('request.jwt.claim.sub', '41000000-0000-4000-8000-000000000003', true);
  if public.authorize_company_transaction(
    '42000000-0000-4000-8000-000000000001', '43000000-0000-4000-8000-000000000001', 'ME21N'
  ) is distinct from true then raise exception 'assigned branch transaction denied'; end if;
  if public.authorize_company_transaction(
    '42000000-0000-4000-8000-000000000001', '43000000-0000-4000-8000-000000000002', 'ME21N'
  ) is distinct from false then raise exception 'operator accessed an unassigned branch'; end if;
  if public.authorize_company_transaction(
    '42000000-0000-4000-8000-000000000002', '43000000-0000-4000-8000-000000000003', 'ME21N'
  ) is distinct from false then raise exception 'operator accessed another company'; end if;
  if public.authorize_company_transaction(
    '42000000-0000-4000-8000-000000000001', '43000000-0000-4000-8000-000000000001', 'UNKNOWN'
  ) is distinct from false then raise exception 'unknown transaction was permitted'; end if;

  perform pg_catalog.set_config('request.jwt.claim.sub', '41000000-0000-4000-8000-000000000001', true);
  if public.set_company_member_branch_access(
    '42000000-0000-4000-8000-000000000001', '44000000-0000-4000-8000-000000000003', '43000000-0000-4000-8000-000000000001', 'revoked'
  ) <> 'updated' then raise exception 'branch access revocation failed'; end if;
  perform pg_catalog.set_config('request.jwt.claim.sub', '41000000-0000-4000-8000-000000000003', true);
  if public.authorize_company_transaction(
    '42000000-0000-4000-8000-000000000001', '43000000-0000-4000-8000-000000000001', 'ME21N'
  ) is distinct from false then raise exception 'revoked branch access still authorizes transaction'; end if;

  select count(*) into role_insert_events from app_private.provisioning_audit_events
  where tenant_id = '42000000-0000-4000-8000-000000000001'
    and actor_user_id = '41000000-0000-4000-8000-000000000001'
    and event_key = 'authorization.membership_role_assignments.insert';
  select count(*) into role_delete_events from app_private.provisioning_audit_events
  where tenant_id = '42000000-0000-4000-8000-000000000001'
    and actor_user_id = '41000000-0000-4000-8000-000000000001'
    and event_key = 'authorization.membership_role_assignments.delete';
  select count(*) into branch_insert_events from app_private.provisioning_audit_events
  where tenant_id = '42000000-0000-4000-8000-000000000001'
    and actor_user_id = '41000000-0000-4000-8000-000000000001'
    and event_key = 'authorization.branch_access.insert';
  select count(*) into branch_update_events from app_private.provisioning_audit_events
  where tenant_id = '42000000-0000-4000-8000-000000000001'
    and actor_user_id = '41000000-0000-4000-8000-000000000001'
    and event_key = 'authorization.branch_access.update';
  if role_insert_events < 2 or role_delete_events < 1
    or branch_insert_events < 2 or branch_update_events < 1 then
    raise exception 'audit event counts mismatch (role insert %, role delete %, branch insert %, branch update %)',
      role_insert_events, role_delete_events, branch_insert_events, branch_update_events;
  end if;

  perform pg_catalog.set_config('request.jwt.claim.role', '', true);
  if public.authorize_company_transaction(
    '42000000-0000-4000-8000-000000000001', '43000000-0000-4000-8000-000000000001', 'ME21N'
  ) is distinct from false then raise exception 'anonymous session passed transaction authorization'; end if;
  begin
    perform public.assign_company_membership_role(
      '42000000-0000-4000-8000-000000000001', '44000000-0000-4000-8000-000000000002', 'company_manager', null
    );
    raise exception 'anonymous session assigned a role';
  exception when insufficient_privilege then null;
  end;
end;
$test$;

rollback;
