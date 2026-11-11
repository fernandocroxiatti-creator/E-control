-- EC-ONB-01: Auth-confirmed onboarding acceptance.
--
-- This additive migration deliberately reuses the existing administrator and
-- employee invitation ledgers.  It does not create users, memberships, roles,
-- grants, company availability, or catalogue approvals.  Its only purpose is
-- to let a recipient who arrived through Supabase Auth accept exactly one
-- existing pending invitation that is bound to that recipient's confirmed
-- e-mail address.
begin;

do $preflight$
begin
  if current_user <> 'postgres' then
    raise exception 'Apply this migration as postgres';
  end if;
  if pg_catalog.to_regclass('app_private.company_admin_invitations') is null
    or pg_catalog.to_regclass('app_private.company_employee_invitations') is null
    or pg_catalog.to_regclass('public.company_memberships') is null
    or pg_catalog.to_regclass('public.membership_role_assignments') is null
    or pg_catalog.to_regclass('public.branch_access') is null
    or pg_catalog.to_regprocedure('public.accept_company_admin_invitation(text)') is null
    or pg_catalog.to_regprocedure('public.accept_company_employee_invitation(text)') is null
    or pg_catalog.to_regprocedure('public.company_set_membership_status(uuid,uuid,text)') is null
    or pg_catalog.to_regprocedure('app_private.write_provisioning_audit(text,uuid,uuid,uuid,jsonb)') is null
    or pg_catalog.to_regprocedure('auth.uid()') is null
    or pg_catalog.to_regprocedure('auth.role()') is null then
    raise exception 'Onboarding acceptance prerequisites are missing';
  end if;
  if pg_catalog.to_regprocedure('app_private.current_confirmed_email()') is not null
    or pg_catalog.to_regprocedure('public.accept_current_company_admin_invitation()') is not null
    or pg_catalog.to_regprocedure('public.accept_current_company_employee_invitation()') is not null
    or pg_catalog.to_regprocedure('public.company_reactivate_employee_membership(uuid,uuid)') is not null then
    raise exception 'Onboarding activation objects already exist; inspect before applying';
  end if;
end;
$preflight$;

-- The browser never supplies a user identifier or an e-mail as authority.
-- The database resolves both from the authenticated Supabase Auth session.
create function app_private.current_confirmed_email()
returns text
language plpgsql stable security definer
set search_path = '' set row_security = off
as $function$
declare
  email_value text;
begin
  if coalesce(auth.role(), '') <> 'authenticated' or auth.uid() is null then
    raise exception 'Authenticated session required' using errcode = '42501';
  end if;
  select pg_catalog.lower(auth_user.email)
    into email_value
  from auth.users as auth_user
  where auth_user.id = auth.uid()
    and auth_user.email_confirmed_at is not null;
  if email_value is null then
    raise exception 'Confirmed email required' using errcode = '42501';
  end if;
  return email_value;
end;
$function$;

-- A bare Auth activation link has no application bearer token.  Rejecting an
-- ambiguous mailbox is intentional: one activation may never choose between
-- invitations for distinct companies.
create function public.accept_current_company_admin_invitation()
returns table(outcome text, tenant_id uuid)
language plpgsql volatile security definer
set search_path = '' set row_security = off
as $function$
declare
  email_value text;
  invitation app_private.company_admin_invitations%rowtype;
  invitation_count integer;
  membership_id uuid;
begin
  email_value := app_private.current_confirmed_email();
  select pg_catalog.count(*)::integer into invitation_count
  from app_private.company_admin_invitations
  where recipient_email = email_value and status = 'pending';
  if invitation_count <> 1 then
    return query select case when invitation_count > 1 then 'ambiguous' else 'rejected' end, null::uuid;
    return;
  end if;
  select * into invitation
  from app_private.company_admin_invitations
  where recipient_email = email_value and status = 'pending'
  for update;
  if invitation.expires_at <= pg_catalog.clock_timestamp() then
    update app_private.company_admin_invitations set status = 'expired' where id = invitation.id;
    perform app_private.write_provisioning_audit('company_admin_invitation.expired', invitation.tenant_id, null, auth.uid(), pg_catalog.jsonb_build_object('invitation_id', invitation.id));
    return query select 'expired'::text, null::uuid;
    return;
  end if;
  perform pg_catalog.pg_advisory_xact_lock(pg_catalog.hashtextextended('company-admin-accept:' || invitation.tenant_id::text, 0));
  perform 1 from public.companies where id = invitation.tenant_id and status = 'active' for share;
  if not found or exists (
    select 1 from public.company_memberships
    where company_memberships.tenant_id = invitation.tenant_id
      and company_memberships.user_id = auth.uid()
  ) then
    return query select 'rejected'::text, null::uuid;
    return;
  end if;
  perform 1 from public.access_role_definitions
  where role_key = 'company_owner' and scope = 'company' and approval_state = 'approved';
  if not found or exists (
    select 1
    from public.company_memberships as membership
    join public.membership_role_assignments as assignment
      on assignment.tenant_id = membership.tenant_id
      and assignment.membership_id = membership.id
      and assignment.role_key = 'company_owner'
      and assignment.branch_id is null
    where membership.tenant_id = invitation.tenant_id and membership.status = 'active'
  ) then
    return query select 'rejected'::text, null::uuid;
    return;
  end if;
  insert into public.company_memberships(tenant_id, user_id, status, branch_access_mode, created_by_user_id)
  values (invitation.tenant_id, auth.uid(), 'active', 'all_branches', auth.uid())
  returning id into membership_id;
  insert into public.membership_role_assignments(tenant_id, membership_id, role_key, branch_id, assigned_by_user_id)
  values (invitation.tenant_id, membership_id, 'company_owner', null, auth.uid());
  update app_private.company_admin_invitations
  set status = 'accepted', accepted_at = pg_catalog.clock_timestamp(), accepted_user_id = auth.uid()
  where id = invitation.id;
  perform app_private.write_provisioning_audit(
    'company_admin_invitation.accepted', invitation.tenant_id, auth.uid(), auth.uid(),
    pg_catalog.jsonb_build_object('invitation_id', invitation.id, 'membership_id', membership_id, 'auth_activation', true)
  );
  return query select 'accepted'::text, invitation.tenant_id;
end;
$function$;

-- The employee path preserves the existing pending-approval model.  A
-- company owner must still activate the new membership; acceptance alone
-- cannot grant operational authority.
create function public.accept_current_company_employee_invitation()
returns table(outcome text, tenant_id uuid, membership_id uuid)
language plpgsql volatile security definer
set search_path = '' set row_security = off
as $function$
declare
  email_value text;
  invitation app_private.company_employee_invitations%rowtype;
  invitation_count integer;
  new_membership_id uuid;
  assigned_branch_id uuid;
begin
  email_value := app_private.current_confirmed_email();
  select pg_catalog.count(*)::integer into invitation_count
  from app_private.company_employee_invitations
  where recipient_email = email_value and status = 'pending';
  if invitation_count <> 1 then
    return query select case when invitation_count > 1 then 'ambiguous' else 'rejected' end, null::uuid, null::uuid;
    return;
  end if;
  select * into invitation
  from app_private.company_employee_invitations
  where recipient_email = email_value and status = 'pending'
  for update;
  if invitation.expires_at <= pg_catalog.clock_timestamp() then
    update app_private.company_employee_invitations set status = 'expired' where id = invitation.id;
    perform app_private.write_provisioning_audit('company_employee_invitation.expired', invitation.tenant_id, null, auth.uid(), pg_catalog.jsonb_build_object('invitation_id', invitation.id));
    return query select 'expired'::text, null::uuid, null::uuid;
    return;
  end if;
  perform pg_catalog.pg_advisory_xact_lock(pg_catalog.hashtextextended('company-employee-accept:' || invitation.tenant_id::text || ':' || auth.uid()::text, 0));
  perform 1 from public.companies where id = invitation.tenant_id and status = 'active' for share;
  if not found or exists (
    select 1 from public.company_memberships
    where company_memberships.tenant_id = invitation.tenant_id
      and company_memberships.user_id = auth.uid()
  ) then
    return query select 'rejected'::text, null::uuid, null::uuid;
    return;
  end if;
  insert into public.company_memberships(tenant_id, user_id, status, branch_access_mode, created_by_user_id)
  values (invitation.tenant_id, auth.uid(), 'pending', 'assigned_only', invitation.created_by_user_id)
  returning id into new_membership_id;
  foreach assigned_branch_id in array invitation.branch_ids loop
    insert into public.branch_access(tenant_id, branch_id, membership_id, status, granted_by_user_id)
    values (invitation.tenant_id, assigned_branch_id, new_membership_id, 'active', invitation.created_by_user_id);
  end loop;
  update app_private.company_employee_invitations
  set status = 'accepted', accepted_at = pg_catalog.clock_timestamp(), accepted_user_id = auth.uid()
  where id = invitation.id;
  perform app_private.write_provisioning_audit(
    'company_employee_invitation.accepted', invitation.tenant_id, auth.uid(), auth.uid(),
    pg_catalog.jsonb_build_object('invitation_id', invitation.id, 'membership_id', new_membership_id, 'auth_activation', true)
  );
  return query select 'pending_approval'::text, invitation.tenant_id, new_membership_id;
end;
$function$;

-- Suspension is reversible only by another tenant actor with membership.manage.
-- Revocation remains terminal; it is deliberately not a reactivation path.
create function public.company_reactivate_employee_membership(p_tenant_id uuid, p_membership_id uuid)
returns text
language plpgsql volatile security definer
set search_path = '' set row_security = off
as $function$
declare actor_id uuid; target_user_id uuid; access_mode text;
begin
  actor_id := app_private.assert_company_membership_permission(p_tenant_id, 'membership.manage');
  if p_membership_id is null then raise exception 'Membership is required' using errcode = '22023'; end if;
  perform pg_catalog.pg_advisory_xact_lock(pg_catalog.hashtextextended('company-membership-reactivation:' || p_tenant_id::text, 0));
  select membership.user_id, membership.branch_access_mode into target_user_id, access_mode
  from public.company_memberships as membership
  where membership.id = p_membership_id and membership.tenant_id = p_tenant_id and membership.status = 'suspended'
  for update;
  if not found then return 'not_suspended'; end if;
  if target_user_id = actor_id then raise exception 'Users cannot reactivate their own membership' using errcode = '42501'; end if;
  if access_mode = 'assigned_only' and not exists (
    select 1 from public.branch_access as access_row
    join public.branches as branch on branch.id = access_row.branch_id and branch.tenant_id = access_row.tenant_id and branch.status = 'active'
    where access_row.tenant_id = p_tenant_id and access_row.membership_id = p_membership_id and access_row.status = 'active'
  ) then raise exception 'An active assigned branch is required before reactivation' using errcode = '55000'; end if;
  update public.company_memberships set status = 'active' where id = p_membership_id and tenant_id = p_tenant_id;
  perform app_private.write_provisioning_audit('company_membership.reactivated', p_tenant_id, target_user_id, actor_id, pg_catalog.jsonb_build_object('membership_id', p_membership_id));
  return 'active';
end;
$function$;

alter function app_private.current_confirmed_email() owner to postgres;
alter function public.accept_current_company_admin_invitation() owner to postgres;
alter function public.accept_current_company_employee_invitation() owner to postgres;
alter function public.company_reactivate_employee_membership(uuid,uuid) owner to postgres;
revoke all on function app_private.current_confirmed_email() from public, anon, authenticated, service_role;
revoke all on function public.accept_current_company_admin_invitation() from public, anon, authenticated, service_role;
revoke all on function public.accept_current_company_employee_invitation() from public, anon, authenticated, service_role;
revoke all on function public.company_reactivate_employee_membership(uuid,uuid) from public, anon, authenticated, service_role;
grant execute on function public.accept_current_company_admin_invitation() to authenticated;
grant execute on function public.accept_current_company_employee_invitation() to authenticated;
grant execute on function public.company_reactivate_employee_membership(uuid,uuid) to authenticated;

do $verify$
declare routine_oid oid;
begin
  foreach routine_oid in array array[
    pg_catalog.to_regprocedure('public.accept_current_company_admin_invitation()'),
    pg_catalog.to_regprocedure('public.accept_current_company_employee_invitation()'),
    pg_catalog.to_regprocedure('public.company_reactivate_employee_membership(uuid,uuid)')
  ] loop
    if routine_oid is null or not exists (
      select 1 from pg_catalog.pg_proc as proc
      join pg_catalog.pg_roles as role_row on role_row.oid = proc.proowner
      where proc.oid = routine_oid and role_row.rolname = 'postgres'
        and proc.prosecdef and 'search_path=""' = any(proc.proconfig)
        and 'row_security=off' = any(proc.proconfig)
        and pg_catalog.has_function_privilege('authenticated', routine_oid, 'EXECUTE')
        and not pg_catalog.has_function_privilege('anon', routine_oid, 'EXECUTE')
        and not pg_catalog.has_function_privilege('service_role', routine_oid, 'EXECUTE')
    ) then
      raise exception 'Onboarding acceptance RPC security contract failed';
    end if;
  end loop;
end;
$verify$;

commit;
