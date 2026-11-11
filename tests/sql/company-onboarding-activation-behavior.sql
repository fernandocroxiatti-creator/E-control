-- Behavioral checks for 20261110120000.  All identities and rows are
-- synthetic and are rolled back; this script never contacts Supabase.
begin;

do $test$
<<onboarding_test>>
declare
  master_id constant uuid := 'c1000000-0000-4000-8000-000000000001';
  owner_id constant uuid := 'c1000000-0000-4000-8000-000000000002';
  employee_id constant uuid := 'c1000000-0000-4000-8000-000000000003';
  wrong_id constant uuid := 'c1000000-0000-4000-8000-000000000004';
  expired_id constant uuid := 'c1000000-0000-4000-8000-000000000005';
  tenant_id constant uuid := 'c2000000-0000-4000-8000-000000000001';
  branch_id constant uuid := 'c3000000-0000-4000-8000-000000000001';
  owner_invitation_id uuid;
  owner_token text;
  employee_invitation_id uuid;
  employee_token text;
  expired_invitation_id uuid;
  expired_token text;
  member_id uuid;
  result text;
  reactivation_result text;
  persisted_membership_status text;
begin
  insert into auth.users(id,email,email_confirmed_at) values
    (master_id,'onboarding-master@example.test',clock_timestamp()),
    (owner_id,'onboarding-owner@example.test',clock_timestamp()),
    (employee_id,'onboarding-employee@example.test',clock_timestamp()),
    (wrong_id,'onboarding-wrong@example.test',clock_timestamp()),
    (expired_id,'onboarding-expired@example.test',clock_timestamp());
  insert into public.companies(id,legal_name,status) values(tenant_id,'Onboarding Company','active');
  insert into public.branches(id,tenant_id,code,name,status) values(branch_id,tenant_id,'001','Onboarding Branch','active');
  insert into public.access_role_definitions(role_key,display_name,scope,approval_state)
  values ('company_owner','Proprietário empresarial','company','approved')
  on conflict (role_key) do update set approval_state='approved';
  insert into public.permission_definitions(permission_key,description,approval_state) values
    ('membership.invite','Gerenciar convites empresariais','approved'),
    ('membership.manage','Gerenciar vínculos empresariais','approved'),
    ('membership.read','Consultar vínculos empresariais','approved'),
    ('membership.role.assign','Atribuir papéis empresariais','approved')
  on conflict (permission_key) do update set approval_state='approved';
  insert into public.role_permission_grants(role_key,permission_key)
  select 'company_owner', permission_key from public.permission_definitions
  where permission_key in ('membership.invite','membership.manage','membership.read','membership.role.assign')
  on conflict do nothing;
  insert into app_private.master_admins(user_id,status,authorized_by_user_id,authorization_reason,approval_reference)
  values(master_id,'active',master_id,'Local onboarding test','EC-ONB-01-LOCAL');

  perform set_config('request.jwt.claim.role','authenticated',false);
  perform set_config('request.jwt.claim.sub',master_id::text,false);
  select invitation_id, invitation_token into owner_invitation_id, owner_token
  from public.master_create_company_admin_invitation(tenant_id,'onboarding-owner@example.test','c4000000-0000-4000-8000-000000000001');
  if owner_token !~ '^[0-9a-f]{64}$' then raise exception 'owner invitation did not issue a token'; end if;

  -- A confirmed but unrelated identity cannot use the e-mail-bound path.
  perform set_config('request.jwt.claim.sub',wrong_id::text,false);
  if (select outcome from public.accept_current_company_admin_invitation()) <> 'rejected' then
    raise exception 'wrong confirmed identity accepted owner invitation';
  end if;

  perform set_config('request.jwt.claim.sub',owner_id::text,false);
  if (select outcome from public.accept_current_company_admin_invitation()) <> 'accepted' then
    raise exception 'confirmed owner did not accept own invitation';
  end if;
  if (select outcome from public.accept_current_company_admin_invitation()) <> 'rejected' then
    raise exception 'owner invitation replay was accepted';
  end if;
  select membership.id into member_id from public.company_memberships as membership
  where membership.tenant_id=onboarding_test.tenant_id and membership.user_id=owner_id;
  if member_id is null or (select status from public.company_memberships where id=member_id) <> 'active'
    or not exists(select 1 from public.membership_role_assignments as assignment
      where assignment.tenant_id=onboarding_test.tenant_id and assignment.membership_id=member_id and assignment.role_key='company_owner' and assignment.branch_id is null) then
    raise exception 'owner onboarding did not create the exact active company_owner membership';
  end if;
  if public.is_current_user_master() then raise exception 'owner onboarding escalated Master privileges'; end if;

  -- The owner can issue a normal employee invitation but acceptance remains
  -- pending and does not assign a role or grant operational permissions.
  select invitation_id, invitation_token into employee_invitation_id, employee_token
  from public.company_create_employee_invitation(tenant_id,'onboarding-employee@example.test',array[branch_id],'c4000000-0000-4000-8000-000000000002');
  if employee_token !~ '^[0-9a-f]{64}$' then raise exception 'employee invitation did not issue a token'; end if;
  perform set_config('request.jwt.claim.sub',employee_id::text,false);
  if (select outcome from public.accept_current_company_employee_invitation()) <> 'pending_approval' then
    raise exception 'confirmed employee was not placed into pending approval';
  end if;
  if (select outcome from public.accept_current_company_employee_invitation()) <> 'rejected' then
    raise exception 'employee invitation replay was accepted';
  end if;
  select membership.id into member_id from public.company_memberships as membership
  where membership.tenant_id=onboarding_test.tenant_id and membership.user_id=employee_id;
  if member_id is null or (select status from public.company_memberships where id=member_id) <> 'pending'
    or exists(select 1 from public.membership_role_assignments as assignment where assignment.tenant_id=onboarding_test.tenant_id and assignment.membership_id=member_id) then
    raise exception 'employee acceptance granted a role or active access';
  end if;
  if not exists(select 1 from public.branch_access as access_row where access_row.tenant_id=onboarding_test.tenant_id and access_row.membership_id=member_id and access_row.branch_id=onboarding_test.branch_id and access_row.status='active') then
    raise exception 'employee branch scope was not preserved';
  end if;
  perform set_config('request.jwt.claim.sub',owner_id::text,false);
  if public.company_set_membership_status(tenant_id,member_id,'suspended') <> 'suspended' then
    raise exception 'employee membership was not suspended';
  end if;
  select public.company_reactivate_employee_membership(tenant_id,member_id) into reactivation_result;
  select status into persisted_membership_status from public.company_memberships where id=member_id;
  if reactivation_result <> 'active' or persisted_membership_status <> 'active' then
    raise exception 'suspended employee was not reactivated (result %, status %)', reactivation_result, persisted_membership_status;
  end if;
  perform set_config('request.jwt.claim.sub',employee_id::text,false);
  begin
    perform public.company_reactivate_employee_membership(tenant_id,member_id);
    raise exception 'employee reactivated own membership';
  exception when insufficient_privilege then null;
  end;

  perform set_config('request.jwt.claim.sub',owner_id::text,false);
  select invitation_id, invitation_token into expired_invitation_id, expired_token
  from public.company_create_employee_invitation(tenant_id,'onboarding-expired@example.test',array[branch_id],'c4000000-0000-4000-8000-000000000003');
  update app_private.company_employee_invitations set expires_at=clock_timestamp()-interval '1 second' where id=expired_invitation_id;
  perform set_config('request.jwt.claim.sub',expired_id::text,false);
  if (select outcome from public.accept_current_company_employee_invitation()) <> 'expired' then
    raise exception 'expired Auth-bound employee invitation was accepted';
  end if;

  if (select count(*) from app_private.provisioning_audit_events
      where event_key in ('company_admin_invitation.accepted','company_employee_invitation.accepted','company_employee_invitation.expired')) < 3 then
    raise exception 'onboarding acceptance audit trail is incomplete';
  end if;
end;
$test$;

rollback;
