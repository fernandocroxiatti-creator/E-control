-- Behavioral verification for 20261109100000.
-- All synthetic identities and data are rolled back after the assertions.
begin;

create or replace function app_private.is_active_company_member(p_tenant_id uuid)
returns boolean language sql stable security definer set search_path='' set row_security=off as $$
  select exists (
    select 1 from public.company_memberships membership
    join public.companies company on company.id=membership.tenant_id
    where membership.tenant_id=p_tenant_id and membership.user_id=auth.uid()
      and membership.status='active' and company.status='active'
  )
$$;
create or replace function app_private.can_access_branch(p_tenant_id uuid,p_branch_id uuid)
returns boolean language sql stable security definer set search_path='' set row_security=off as $$
  select exists (
    select 1 from public.company_memberships membership
    join public.companies company on company.id=membership.tenant_id and company.status='active'
    join public.branches branch on branch.id=p_branch_id and branch.tenant_id=membership.tenant_id and branch.status='active'
    where membership.tenant_id=p_tenant_id and membership.user_id=auth.uid() and membership.status='active'
      and (membership.branch_access_mode='all_branches' or exists (
        select 1 from public.branch_access access_row
        where access_row.tenant_id=membership.tenant_id and access_row.membership_id=membership.id
          and access_row.branch_id=branch.id and access_row.status='active'
      ))
  )
$$;
create or replace function app_private.has_tenant_permission(p_tenant_id uuid,p_permission_key text,p_branch_id uuid default null)
returns boolean language sql stable security definer set search_path='' set row_security=off as $$
  select exists (
    select 1 from public.company_memberships membership
    join public.access_role_definitions role_definition on true
    join public.membership_role_assignments assignment on assignment.tenant_id=membership.tenant_id and assignment.membership_id=membership.id and assignment.role_key=role_definition.role_key
    join public.role_permission_grants grant_row on grant_row.role_key=role_definition.role_key
    join public.permission_definitions permission on permission.permission_key=grant_row.permission_key
    where membership.tenant_id=p_tenant_id and membership.user_id=auth.uid() and membership.status='active'
      and role_definition.approval_state='approved' and permission.approval_state='approved'
      and grant_row.permission_key=p_permission_key
      and ((role_definition.scope='company' and assignment.branch_id is null) or (role_definition.scope='branch' and p_branch_id is not null and assignment.branch_id=p_branch_id))
      and (p_branch_id is null or app_private.can_access_branch(p_tenant_id,p_branch_id))
  )
$$;

do $test$
declare
  tenant_a constant uuid := '91000000-0000-4000-8000-000000000001';
  tenant_b constant uuid := '91000000-0000-4000-8000-000000000002';
  branch_a constant uuid := '92000000-0000-4000-8000-000000000001';
  owner constant uuid := '93000000-0000-4000-8000-000000000001';
  employee constant uuid := '93000000-0000-4000-8000-000000000002';
  outsider constant uuid := '93000000-0000-4000-8000-000000000003';
  expired_recipient constant uuid := '93000000-0000-4000-8000-000000000004';
  owner_membership constant uuid := '94000000-0000-4000-8000-000000000001';
  employee_membership uuid;
  invite_id uuid;
  token text;
  expired_invite_id uuid;
  expired_token text;
  result text;
  visible_invites integer;
  visible_roles integer;
begin
  insert into auth.users(id,email,email_confirmed_at) values
    (owner,'employee-owner@example.test',clock_timestamp()),
    (employee,'employee-target@example.test',clock_timestamp()),
    (outsider,'employee-outsider@example.test',clock_timestamp()),
    (expired_recipient,'employee-expired@example.test',clock_timestamp());
  insert into public.companies(id,legal_name,status) values
    (tenant_a,'Employee Management A','active'),
    (tenant_b,'Employee Management B','active');
  insert into public.branches(id,tenant_id,code,name,status) values
    (branch_a,tenant_a,'001','Employee Branch A','active');
  insert into public.access_role_definitions(role_key,display_name,scope,approval_state) values
    ('employee_management_owner','Employee Management Owner','company','approved'),
    ('employee_management_operator','Employee Management Operator','branch','approved');
  insert into public.permission_definitions(permission_key,description,approval_state) values
    ('membership.invite','invite test','approved'),
    ('membership.manage','manage test','approved'),
    ('membership.read','read test','approved'),
    ('membership.role.assign','assign test','approved')
  on conflict(permission_key) do update set approval_state='approved';
  insert into public.role_permission_grants(role_key,permission_key)
    select 'employee_management_owner',permission_key from public.permission_definitions
    where permission_key in ('membership.invite','membership.manage','membership.read','membership.role.assign');
  insert into public.role_permission_grants(role_key,permission_key)
    values ('employee_management_operator','membership.read');
  insert into public.company_memberships(id,tenant_id,user_id,status,branch_access_mode,created_by_user_id)
    values(owner_membership,tenant_a,owner,'active','all_branches',owner);
  insert into public.membership_role_assignments(tenant_id,membership_id,role_key,branch_id,assigned_by_user_id)
    values(tenant_a,owner_membership,'employee_management_owner',null,owner);
  perform set_config('request.jwt.claim.role','authenticated',false);
  perform set_config('request.jwt.claim.sub',owner::text,false);

  select invitation_id, invitation_token into invite_id, token
  from public.company_create_employee_invitation(tenant_a,'employee-target@example.test',array[branch_a], '95000000-0000-4000-8000-000000000001');
  select count(*) into visible_invites from public.company_list_employee_invitations(tenant_a);
  if visible_invites <> 1 then raise exception 'employee invitation was not visible to authorized owner'; end if;

  begin
    perform * from public.company_create_employee_invitation(tenant_a,'employee-target@example.test',array[branch_a], '95000000-0000-4000-8000-000000000009');
    raise exception 'duplicate employee invitation was accepted';
  exception when unique_violation then null;
  end;

  perform set_config('request.jwt.claim.sub',outsider::text,false);
  if (select outcome from public.accept_company_employee_invitation(token)) <> 'rejected' then
    raise exception 'email-mismatched identity accepted an employee invitation';
  end if;

  begin
    perform * from public.company_list_employee_invitations(tenant_a);
    raise exception 'outsider listed company invitations';
  exception when insufficient_privilege then null;
  end;

  perform set_config('request.jwt.claim.sub',employee::text,false);
  if (select outcome from public.accept_company_employee_invitation(token)) <> 'pending_approval' then
    raise exception 'employee invitation was not accepted into pending approval';
  end if;
  if (select outcome from public.accept_company_employee_invitation(token)) <> 'rejected' then
    raise exception 'employee invitation was accepted more than once';
  end if;
  select id into employee_membership from public.company_memberships where tenant_id=tenant_a and user_id=employee;
  if (select status from public.company_memberships where id=employee_membership) <> 'pending' then
    raise exception 'employee membership bypassed approval';
  end if;

  perform set_config('request.jwt.claim.sub',owner::text,false);
  result := public.company_activate_employee_membership(tenant_a,employee_membership);
  if result <> 'active' then raise exception 'authorized owner did not activate pending employee'; end if;
  if not exists(select 1 from public.branch_access where tenant_id=tenant_a and membership_id=employee_membership and branch_id=branch_a and status='active') then
    raise exception 'employee branch assignment was not preserved';
  end if;
  insert into public.membership_role_assignments(tenant_id,membership_id,role_key,branch_id,assigned_by_user_id)
    values(tenant_a,employee_membership,'employee_management_operator',branch_a,owner);
  select count(*) into visible_roles from public.company_list_membership_authorizations(tenant_a) where membership_id=employee_membership;
  if visible_roles <> 1 then raise exception 'membership role assignment was not visible'; end if;
  begin
    perform public.company_activate_employee_membership(tenant_b,employee_membership);
    raise exception 'cross-company membership activation was accepted';
  exception when insufficient_privilege then null;
  end;

  select invitation_id, invitation_token into expired_invite_id, expired_token
  from public.company_create_employee_invitation(tenant_a,'employee-expired@example.test',array[branch_a], '95000000-0000-4000-8000-000000000003');
  update app_private.company_employee_invitations set expires_at=clock_timestamp()-interval '1 second' where id=expired_invite_id;
  perform set_config('request.jwt.claim.sub',expired_recipient::text,false);
  if (select outcome from public.accept_company_employee_invitation(expired_token)) <> 'expired' then
    raise exception 'expired employee invitation was accepted';
  end if;
  perform set_config('request.jwt.claim.sub',owner::text,false);

  select invitation_id into invite_id from public.company_create_employee_invitation(tenant_a,'employee-outsider@example.test',array[branch_a], '95000000-0000-4000-8000-000000000002');
  if public.company_revoke_employee_invitation(tenant_a,invite_id) <> 'revoked' then raise exception 'pending employee invitation was not revoked'; end if;
  if exists(select 1 from app_private.company_employee_invitations where id=invite_id and status='pending') then raise exception 'revoked employee invitation remained pending'; end if;
  if (select count(distinct event_key) from app_private.provisioning_audit_events where event_key in ('company_employee_invitation.issued','company_employee_invitation.accepted','company_employee_invitation.expired','company_employee_invitation.revoked','company_membership.activated')) <> 5 then
    raise exception 'employee management audit is incomplete';
  end if;
end;
$test$;

rollback;
