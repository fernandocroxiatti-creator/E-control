-- Tenant-owned employee invitation lifecycle and membership activation.
-- This migration seeds no memberships, roles, grants, company availability or transactions.

begin;

do $preflight$
begin
  if current_user <> 'postgres' then
    raise exception 'Apply this migration as postgres';
  end if;
  if pg_catalog.to_regclass('app_private.company_employee_invitations') is null
    or pg_catalog.to_regclass('public.company_memberships') is null
    or pg_catalog.to_regclass('public.branch_access') is null
    or pg_catalog.to_regclass('public.membership_role_assignments') is null
    or pg_catalog.to_regclass('public.role_permission_grants') is null
    or pg_catalog.to_regprocedure('app_private.assert_company_membership_permission(uuid,text)') is null
    or pg_catalog.to_regprocedure('app_private.write_provisioning_audit(text,uuid,uuid,uuid,jsonb)') is null
    or pg_catalog.to_regprocedure('auth.uid()') is null then
    raise exception 'Company membership foundations are required';
  end if;
  if pg_catalog.to_regprocedure('public.company_list_employee_invitations(uuid)') is not null
    or pg_catalog.to_regprocedure('public.company_revoke_employee_invitation(uuid,uuid)') is not null
    or pg_catalog.to_regprocedure('public.company_activate_employee_membership(uuid,uuid)') is not null
    or pg_catalog.to_regprocedure('public.company_list_membership_authorizations(uuid)') is not null then
    raise exception 'Employee management functions already exist; inspect before proceeding';
  end if;
  if exists (
    select 1
    from (values
      ('public.company_memberships'::pg_catalog.regclass),
      ('public.branch_access'::pg_catalog.regclass),
      ('public.membership_role_assignments'::pg_catalog.regclass),
      ('public.role_permission_grants'::pg_catalog.regclass)
    ) as protected(relation_oid)
    join pg_catalog.pg_class as relation_row on relation_row.oid = protected.relation_oid
    where not relation_row.relrowsecurity or not relation_row.relforcerowsecurity
  ) then
    raise exception 'Tenant authorization tables must retain enabled and forced RLS';
  end if;
end;
$preflight$;

-- The original private-table CHECK contains the same escaped expression. The
-- replacement validates every existing row, so it fails rather than accepting
-- legacy content that is incompatible with the intended e-mail contract.
alter table app_private.company_employee_invitations
  drop constraint company_employee_invitations_recipient_email_check;
alter table app_private.company_employee_invitations
  add constraint company_employee_invitations_recipient_email_check check (
    recipient_email = pg_catalog.lower(pg_catalog.btrim(recipient_email))
    and recipient_email ~ '^[^[:space:]@]+@[^[:space:]@]+\.[^[:space:]@]+$'
  );

-- Correct the historical employee-invitation e-mail expression without
-- changing the already-applied migration. The prior SQL literal used two
-- backslashes and rejected normal e-mail addresses such as user@example.com.
create or replace function public.company_create_employee_invitation(
  p_tenant_id uuid,
  p_recipient_email text,
  p_branch_ids uuid[],
  p_request_id uuid
)
returns table (invitation_id uuid, invitation_token text, expires_at timestamptz)
language plpgsql volatile security definer
set search_path = '' set row_security = off
as $function$
declare
  actor_id uuid;
  normalized_email text;
  invite_token text;
  invitation_row app_private.company_employee_invitations%rowtype;
  assigned_branch_id uuid;
begin
  actor_id := app_private.assert_company_membership_permission(p_tenant_id, 'membership.invite');
  normalized_email := pg_catalog.lower(pg_catalog.btrim(p_recipient_email));
  if p_request_id is null or normalized_email is null
    or normalized_email !~ '^[^[:space:]@]+@[^[:space:]@]+\.[^[:space:]@]+$'
    or pg_catalog.cardinality(p_branch_ids) = 0
    or pg_catalog.cardinality(p_branch_ids) <> pg_catalog.cardinality(array(select distinct value from pg_catalog.unnest(p_branch_ids) as value)) then
    raise exception 'Invalid employee invitation request' using errcode = '22023';
  end if;
  foreach assigned_branch_id in array p_branch_ids loop
    if not app_private.can_access_branch(p_tenant_id, assigned_branch_id) then
      raise exception 'Cannot invite for an unauthorized branch' using errcode = '42501';
    end if;
  end loop;
  perform pg_catalog.pg_advisory_xact_lock(pg_catalog.hashtextextended(
    'employee-invite:' || p_tenant_id::text || ':' || normalized_email, 0
  ));
  if exists (
    select 1
    from public.company_memberships as membership
    join auth.users as auth_user on auth_user.id = membership.user_id
    where membership.tenant_id = p_tenant_id
      and pg_catalog.lower(auth_user.email) = normalized_email
      and membership.status in ('pending', 'active', 'suspended')
  ) then
    raise exception 'This identity already has a company membership' using errcode = '23505';
  end if;
  update app_private.company_employee_invitations as existing_invitation
  set status = 'expired'
  where existing_invitation.tenant_id = p_tenant_id
    and existing_invitation.recipient_email = normalized_email
    and existing_invitation.status = 'pending'
    and existing_invitation.expires_at <= pg_catalog.clock_timestamp();
  invite_token := pg_catalog.replace(
    pg_catalog.gen_random_uuid()::text || pg_catalog.gen_random_uuid()::text, '-', ''
  );
  insert into app_private.company_employee_invitations(
    tenant_id, recipient_email, branch_ids, token_digest, created_by_user_id, request_id, expires_at
  ) values (
    p_tenant_id, normalized_email, p_branch_ids,
    pg_catalog.sha256(pg_catalog.convert_to(invite_token, 'UTF8')),
    actor_id, p_request_id, pg_catalog.clock_timestamp() + interval '7 days'
  ) returning * into invitation_row;
  perform app_private.write_provisioning_audit(
    'company_employee_invitation.issued', p_tenant_id, null, actor_id,
    pg_catalog.jsonb_build_object('invitation_id', invitation_row.id, 'branch_count', pg_catalog.cardinality(p_branch_ids))
  );
  return query select invitation_row.id, invite_token, invitation_row.expires_at;
end;
$function$;

create function public.company_list_employee_invitations(p_tenant_id uuid)
returns table (
  invitation_id uuid,
  recipient_email text,
  status text,
  created_at timestamptz,
  expires_at timestamptz,
  accepted_at timestamptz,
  revoked_at timestamptz,
  branch_count integer
)
language plpgsql stable security definer
set search_path = '' set row_security = off
as $function$
begin
  perform app_private.assert_company_membership_permission(p_tenant_id, 'membership.invite');
  return query
  select invitation.id,
    invitation.recipient_email,
    case when invitation.status = 'pending' and invitation.expires_at <= pg_catalog.statement_timestamp()
      then 'expired' else invitation.status end,
    invitation.created_at,
    invitation.expires_at,
    invitation.accepted_at,
    invitation.revoked_at,
    pg_catalog.cardinality(invitation.branch_ids)::integer
  from app_private.company_employee_invitations as invitation
  where invitation.tenant_id = p_tenant_id
  order by invitation.created_at desc, invitation.id;
end;
$function$;

create function public.company_revoke_employee_invitation(
  p_tenant_id uuid,
  p_invitation_id uuid
)
returns text
language plpgsql volatile security definer
set search_path = '' set row_security = off
as $function$
declare
  actor_id uuid;
  invitation_row app_private.company_employee_invitations%rowtype;
begin
  actor_id := app_private.assert_company_membership_permission(p_tenant_id, 'membership.invite');
  if p_invitation_id is null then
    raise exception 'Invitation is required' using errcode = '22023';
  end if;
  select invitation.* into invitation_row
  from app_private.company_employee_invitations as invitation
  where invitation.id = p_invitation_id
    and invitation.tenant_id = p_tenant_id
  for update;
  if not found or invitation_row.status <> 'pending' then
    return 'not_pending';
  end if;
  if invitation_row.expires_at <= pg_catalog.clock_timestamp() then
    update app_private.company_employee_invitations
    set status = 'expired'
    where id = invitation_row.id;
    perform app_private.write_provisioning_audit(
      'company_employee_invitation.expired', p_tenant_id, null, actor_id,
      pg_catalog.jsonb_build_object('invitation_id', invitation_row.id)
    );
    return 'expired';
  end if;
  update app_private.company_employee_invitations
  set status = 'revoked', revoked_at = pg_catalog.clock_timestamp(), revoked_by_user_id = actor_id
  where id = invitation_row.id;
  perform app_private.write_provisioning_audit(
    'company_employee_invitation.revoked', p_tenant_id, null, actor_id,
    pg_catalog.jsonb_build_object('invitation_id', invitation_row.id)
  );
  return 'revoked';
end;
$function$;

create function public.company_activate_employee_membership(
  p_tenant_id uuid,
  p_membership_id uuid
)
returns text
language plpgsql volatile security definer
set search_path = '' set row_security = off
as $function$
declare
  actor_id uuid;
  target_user_id uuid;
begin
  actor_id := app_private.assert_company_membership_permission(p_tenant_id, 'membership.manage');
  if p_membership_id is null then
    raise exception 'Membership is required' using errcode = '22023';
  end if;
  perform pg_catalog.pg_advisory_xact_lock(pg_catalog.hashtextextended(
    'company-membership-activation:' || p_tenant_id::text, 0
  ));
  select membership.user_id into target_user_id
  from public.company_memberships as membership
  where membership.id = p_membership_id
    and membership.tenant_id = p_tenant_id
    and membership.status = 'pending'
    and membership.branch_access_mode = 'assigned_only'
  for update;
  if not found then
    return 'not_pending';
  end if;
  if target_user_id = actor_id then
    raise exception 'Users cannot activate their own membership' using errcode = '42501';
  end if;
  if not exists (
    select 1
    from public.branch_access as access_row
    join public.branches as branch on branch.id = access_row.branch_id
      and branch.tenant_id = access_row.tenant_id
      and branch.status = 'active'
    where access_row.tenant_id = p_tenant_id
      and access_row.membership_id = p_membership_id
      and access_row.status = 'active'
  ) then
    raise exception 'An active assigned branch is required before activation' using errcode = '55000';
  end if;
  update public.company_memberships
  set status = 'active'
  where id = p_membership_id and tenant_id = p_tenant_id;
  perform app_private.write_provisioning_audit(
    'company_membership.activated', p_tenant_id, target_user_id, actor_id,
    pg_catalog.jsonb_build_object('membership_id', p_membership_id)
  );
  return 'active';
end;
$function$;

create function public.company_list_membership_authorizations(p_tenant_id uuid)
returns table (
  membership_id uuid,
  role_key text,
  role_display_name text,
  scope text,
  branch_id uuid,
  branch_name text,
  granted_permission_count integer
)
language plpgsql stable security definer
set search_path = '' set row_security = off
as $function$
begin
  perform app_private.assert_company_membership_permission(p_tenant_id, 'membership.read');
  return query
  select assignment.membership_id,
    assignment.role_key,
    role_definition.display_name,
    role_definition.scope,
    assignment.branch_id,
    branch.name,
    pg_catalog.count(role_grant.permission_key)::integer
  from public.membership_role_assignments as assignment
  join public.access_role_definitions as role_definition on role_definition.role_key = assignment.role_key
  left join public.branches as branch on branch.id = assignment.branch_id
    and branch.tenant_id = assignment.tenant_id
  left join public.role_permission_grants as role_grant on role_grant.role_key = assignment.role_key
  where assignment.tenant_id = p_tenant_id
  group by assignment.membership_id, assignment.role_key, role_definition.display_name,
    role_definition.scope, assignment.branch_id, branch.name
  order by assignment.membership_id, assignment.role_key, assignment.branch_id;
end;
$function$;

alter function public.company_create_employee_invitation(uuid,text,uuid[],uuid) owner to postgres;
alter function public.company_list_employee_invitations(uuid) owner to postgres;
alter function public.company_revoke_employee_invitation(uuid,uuid) owner to postgres;
alter function public.company_activate_employee_membership(uuid,uuid) owner to postgres;
alter function public.company_list_membership_authorizations(uuid) owner to postgres;

revoke all on function public.company_create_employee_invitation(uuid,text,uuid[],uuid),
  public.company_list_employee_invitations(uuid),
  public.company_revoke_employee_invitation(uuid,uuid),
  public.company_activate_employee_membership(uuid,uuid),
  public.company_list_membership_authorizations(uuid)
from public, anon, authenticated, service_role;
grant execute on function public.company_create_employee_invitation(uuid,text,uuid[],uuid),
  public.company_list_employee_invitations(uuid),
  public.company_revoke_employee_invitation(uuid,uuid),
  public.company_activate_employee_membership(uuid,uuid),
  public.company_list_membership_authorizations(uuid)
to authenticated;

do $verify$
declare
  procedure_name text;
  function_oid oid;
begin
  foreach procedure_name in array array[
    'public.company_create_employee_invitation(uuid,text,uuid[],uuid)',
    'public.company_list_employee_invitations(uuid)',
    'public.company_revoke_employee_invitation(uuid,uuid)',
    'public.company_activate_employee_membership(uuid,uuid)',
    'public.company_list_membership_authorizations(uuid)'
  ] loop
    function_oid := pg_catalog.to_regprocedure(procedure_name);
    if function_oid is null or not exists (
      select 1
      from pg_catalog.pg_proc as procedure_row
      join pg_catalog.pg_roles as role_row on role_row.oid = procedure_row.proowner
      where procedure_row.oid = function_oid
        and role_row.rolname = 'postgres'
        and procedure_row.prosecdef
        and 'search_path=""' = any(procedure_row.proconfig)
        and 'row_security=off' = any(procedure_row.proconfig)
        and pg_catalog.has_function_privilege('authenticated', function_oid, 'EXECUTE')
        and not pg_catalog.has_function_privilege('anon', function_oid, 'EXECUTE')
        and not pg_catalog.has_function_privilege('service_role', function_oid, 'EXECUTE')
        and not exists (
          select 1 from pg_catalog.aclexplode(
            coalesce(procedure_row.proacl, pg_catalog.acldefault('f', procedure_row.proowner))
          ) as function_acl
          where function_acl.grantee = 0 and function_acl.privilege_type = 'EXECUTE'
        )
    ) then
      raise exception 'Employee management RPC security contract failed: %', procedure_name;
    end if;
  end loop;
end;
$verify$;

comment on function public.company_list_employee_invitations(uuid) is
  'Lists no token material and only for a company actor with membership.invite.';
comment on function public.company_revoke_employee_invitation(uuid,uuid) is
  'Revokes one pending employee invitation in the actor company and audits the result.';
comment on function public.company_activate_employee_membership(uuid,uuid) is
  'Activates a pending assigned-branch membership only by another authorized company actor.';
comment on function public.company_list_membership_authorizations(uuid) is
  'Lists company membership role assignments and grant counts; does not grant authority.';

commit;
