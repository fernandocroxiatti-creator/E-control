-- EC-ADM-03: single-use invitations for the first company administrator.
-- The invite role is fixed to company_owner and is usable only after an
-- operator has separately approved that company-scoped role in the catalog.
-- No Auth user is created, and this migration never grants Admin Master.

begin;

do $preflight$
begin
  if current_user <> 'postgres' then
    raise exception 'Apply this migration as postgres';
  end if;
  if pg_catalog.to_regclass('public.companies') is null
    or pg_catalog.to_regclass('public.company_memberships') is null
    or pg_catalog.to_regclass('public.access_role_definitions') is null
    or pg_catalog.to_regclass('public.membership_role_assignments') is null
    or pg_catalog.to_regclass('app_private.provisioning_audit_events') is null
    or pg_catalog.to_regprocedure('app_private.assert_current_master()') is null
    or pg_catalog.to_regprocedure('app_private.write_provisioning_audit(text,uuid,uuid,uuid,jsonb)') is null
    or pg_catalog.to_regprocedure('public.is_current_user_master()') is null
    or pg_catalog.to_regprocedure('auth.uid()') is null
    or pg_catalog.to_regprocedure('auth.role()') is null then
    raise exception 'Company, Master, Auth and audit foundations are required';
  end if;
  if pg_catalog.to_regclass('app_private.company_admin_invitations') is not null
    or pg_catalog.to_regprocedure('public.master_create_company_admin_invitation(uuid,text,uuid)') is not null
    or pg_catalog.to_regprocedure('public.accept_company_admin_invitation(text)') is not null
    or pg_catalog.to_regprocedure('public.master_revoke_company_admin_invitation(uuid)') is not null
    or pg_catalog.to_regprocedure('public.master_list_company_admin_invitations(uuid)') is not null then
    raise exception 'Company invitation objects already exist; inspect before proceeding';
  end if;
  if not exists (
    select 1 from pg_catalog.pg_class as relation_row
    where relation_row.oid = 'public.companies'::pg_catalog.regclass
      and relation_row.relrowsecurity and relation_row.relforcerowsecurity
  ) or not exists (
    select 1 from pg_catalog.pg_class as relation_row
    where relation_row.oid = 'public.company_memberships'::pg_catalog.regclass
      and relation_row.relrowsecurity and relation_row.relforcerowsecurity
  ) or not exists (
    select 1 from pg_catalog.pg_class as relation_row
    where relation_row.oid = 'public.membership_role_assignments'::pg_catalog.regclass
      and relation_row.relrowsecurity and relation_row.relforcerowsecurity
  ) then
    raise exception 'Tenant RLS must remain enabled and forced';
  end if;
  if not exists (
    select 1 from pg_catalog.pg_proc as procedure_row
    join pg_catalog.pg_roles as role_row on role_row.oid = procedure_row.proowner
    where procedure_row.oid = pg_catalog.to_regprocedure('app_private.assert_current_master()')
      and role_row.rolname = 'postgres' and procedure_row.prosecdef
      and 'search_path=""' = any(procedure_row.proconfig)
      and 'row_security=off' = any(procedure_row.proconfig)
  ) then
    raise exception 'Master assertion helper has an unsafe contract';
  end if;
end;
$preflight$;

create table app_private.company_admin_invitations (
  id uuid primary key default pg_catalog.gen_random_uuid(),
  tenant_id uuid not null references public.companies(id) on delete restrict,
  recipient_email text not null check (
    recipient_email = pg_catalog.lower(pg_catalog.btrim(recipient_email))
    and pg_catalog.length(recipient_email) between 3 and 254
    and recipient_email ~ '^[^[:space:]@]+@[^[:space:]@]+\.[^[:space:]@]+$'
  ),
  role_key text not null default 'company_owner'
    check (role_key = 'company_owner')
    references public.access_role_definitions(role_key) on delete restrict,
  token_digest bytea not null unique check (pg_catalog.octet_length(token_digest) = 32),
  status text not null default 'pending'
    check (status in ('pending', 'accepted', 'expired', 'revoked')),
  created_by_user_id uuid not null references auth.users(id) on delete restrict,
  request_id uuid not null,
  created_at timestamptz not null default pg_catalog.clock_timestamp(),
  expires_at timestamptz not null,
  accepted_at timestamptz,
  accepted_user_id uuid references auth.users(id) on delete restrict,
  revoked_at timestamptz,
  revoked_by_user_id uuid references auth.users(id) on delete restrict,
  constraint company_admin_invitation_expiry check (expires_at > created_at),
  constraint company_admin_invitation_state_fields check (
    (status = 'accepted' and accepted_at is not null and accepted_user_id is not null
      and revoked_at is null and revoked_by_user_id is null)
    or (status = 'revoked' and revoked_at is not null and revoked_by_user_id is not null
      and accepted_at is null and accepted_user_id is null)
    or (status in ('pending', 'expired') and accepted_at is null and accepted_user_id is null
      and revoked_at is null and revoked_by_user_id is null)
  ),
  constraint company_admin_invitation_actor_request_unique unique (created_by_user_id, request_id)
);

alter table app_private.company_admin_invitations owner to postgres;
alter table app_private.company_admin_invitations enable row level security;
alter table app_private.company_admin_invitations force row level security;
revoke all on table app_private.company_admin_invitations from public, anon, authenticated, service_role;
create index company_admin_invitations_tenant_created_idx
  on app_private.company_admin_invitations (tenant_id, created_at desc);
create unique index company_admin_invitations_one_pending_per_company
  on app_private.company_admin_invitations (tenant_id)
  where status = 'pending';

create function public.master_create_company_admin_invitation(
  p_tenant_id uuid,
  p_recipient_email text,
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
  invitation_row app_private.company_admin_invitations%rowtype;
begin
  actor_id := app_private.assert_current_master();
  normalized_email := pg_catalog.lower(pg_catalog.btrim(p_recipient_email));
  if p_tenant_id is null or p_request_id is null
    or normalized_email is null
    or pg_catalog.length(normalized_email) not between 3 and 254
    or normalized_email !~ '^[^[:space:]@]+@[^[:space:]@]+\.[^[:space:]@]+$' then
    raise exception 'Invalid company invitation request' using errcode = '22023';
  end if;

  perform pg_catalog.pg_advisory_xact_lock(pg_catalog.hashtextextended(
    'company-first-admin-invite:' || p_tenant_id::text, 0
  ));

  perform 1 from public.companies as company
  where company.id = p_tenant_id and company.status = 'active'
  for update;
  if not found then
    raise exception 'Active company not found' using errcode = 'P0002';
  end if;

  perform 1 from public.access_role_definitions as role_definition
  where role_definition.role_key = 'company_owner'
    and role_definition.scope = 'company'
    and role_definition.approval_state = 'approved'
  for share;
  if not found then
    raise exception 'The company administrator role is not approved' using errcode = '55000';
  end if;

  if exists (
    select 1
    from public.company_memberships as membership
    join public.membership_role_assignments as assignment
      on assignment.tenant_id = membership.tenant_id
     and assignment.membership_id = membership.id
     and assignment.role_key = 'company_owner'
     and assignment.branch_id is null
    where membership.tenant_id = p_tenant_id and membership.status = 'active'
  ) then
    raise exception 'This company already has an active first administrator' using errcode = '23505';
  end if;

  if exists (
    select 1 from auth.users as auth_user
    join public.company_memberships as membership on membership.user_id = auth_user.id
    where membership.tenant_id = p_tenant_id
      and pg_catalog.lower(auth_user.email) = normalized_email
      and membership.status in ('active', 'pending', 'suspended')
  ) then
    raise exception 'This identity already has a company membership' using errcode = '23505';
  end if;

  if exists (
    select 1 from app_private.company_admin_invitations as existing_invitation
    where existing_invitation.created_by_user_id = actor_id
      and existing_invitation.request_id = p_request_id
  ) then
    raise exception 'Invitation request key was already used; issue a new request' using errcode = '22023';
  end if;

  for invitation_row in
    update app_private.company_admin_invitations as old_invitation
    set status = 'expired'
    where old_invitation.tenant_id = p_tenant_id
      and old_invitation.status = 'pending'
      and old_invitation.expires_at <= pg_catalog.clock_timestamp()
    returning old_invitation.*
  loop
    perform app_private.write_provisioning_audit(
      'company_admin_invitation.expired', p_tenant_id, null, actor_id,
      pg_catalog.jsonb_build_object('invitation_id', invitation_row.id, 'role_key', invitation_row.role_key)
    );
  end loop;

  invite_token := pg_catalog.replace(
    pg_catalog.gen_random_uuid()::text || pg_catalog.gen_random_uuid()::text, '-', ''
  );
  insert into app_private.company_admin_invitations (
    tenant_id, recipient_email, role_key, token_digest, created_by_user_id,
    request_id, expires_at
  ) values (
    p_tenant_id, normalized_email, 'company_owner',
    pg_catalog.sha256(pg_catalog.convert_to(invite_token, 'UTF8')),
    actor_id, p_request_id, pg_catalog.clock_timestamp() + interval '7 days'
  ) returning * into invitation_row;

  perform app_private.write_provisioning_audit(
    'company_admin_invitation.issued', p_tenant_id, null, actor_id,
    pg_catalog.jsonb_build_object(
      'invitation_id', invitation_row.id, 'role_key', invitation_row.role_key,
      'expires_at', invitation_row.expires_at
    )
  );
  return query select invitation_row.id, invite_token, invitation_row.expires_at;
end;
$function$;

create function public.accept_company_admin_invitation(p_invitation_token text)
returns table (outcome text, tenant_id uuid)
language plpgsql volatile security definer
set search_path = '' set row_security = off
as $function$
declare
  actor_id uuid;
  actor_email text;
  invitation_tenant_id uuid;
  invitation_row app_private.company_admin_invitations%rowtype;
  new_membership_id uuid;
begin
  if coalesce(auth.role(), '') <> 'authenticated' then
    raise exception 'Authenticated session required' using errcode = '42501';
  end if;
  actor_id := auth.uid();
  if actor_id is null then
    raise exception 'Authenticated user identity required' using errcode = '42501';
  end if;
  if p_invitation_token is null or p_invitation_token !~ '^[0-9a-f]{64}$' then
    return query select 'rejected'::text, null::uuid;
    return;
  end if;

  select invitation.tenant_id into invitation_tenant_id
  from app_private.company_admin_invitations as invitation
  where invitation.token_digest = pg_catalog.sha256(pg_catalog.convert_to(p_invitation_token, 'UTF8'));
  if not found then
    return query select 'rejected'::text, null::uuid;
    return;
  end if;
  -- Keep the same lock order as issuance and expiry: company first, invitation second.
  perform 1 from public.companies as company
  where company.id = invitation_tenant_id and company.status = 'active'
  for update;
  if not found then
    return query select 'rejected'::text, null::uuid;
    return;
  end if;
  select invitation.* into invitation_row
  from app_private.company_admin_invitations as invitation
  where invitation.token_digest = pg_catalog.sha256(pg_catalog.convert_to(p_invitation_token, 'UTF8'))
  for update;
  if not found or invitation_row.tenant_id <> invitation_tenant_id then
    return query select 'rejected'::text, null::uuid;
    return;
  end if;
  if invitation_row.status <> 'pending' then
    return query select 'rejected'::text, null::uuid;
    return;
  end if;

  if invitation_row.expires_at <= pg_catalog.clock_timestamp() then
    update app_private.company_admin_invitations
    set status = 'expired' where id = invitation_row.id;
    perform app_private.write_provisioning_audit(
      'company_admin_invitation.expired', invitation_row.tenant_id, null, actor_id,
      pg_catalog.jsonb_build_object('invitation_id', invitation_row.id, 'role_key', invitation_row.role_key)
    );
    return query select 'expired'::text, null::uuid;
    return;
  end if;

  select pg_catalog.lower(auth_user.email) into actor_email
  from auth.users as auth_user
  where auth_user.id = actor_id and auth_user.email_confirmed_at is not null;
  if actor_email is null or actor_email <> invitation_row.recipient_email then
    return query select 'rejected'::text, null::uuid;
    return;
  end if;

  perform 1 from public.access_role_definitions as role_definition
  where role_definition.role_key = 'company_owner'
    and role_definition.scope = 'company'
    and role_definition.approval_state = 'approved'
  for share;
  if not found then
    return query select 'rejected'::text, null::uuid;
    return;
  end if;
  if exists (
    select 1
    from public.company_memberships as membership
    join public.membership_role_assignments as assignment
      on assignment.tenant_id = membership.tenant_id
     and assignment.membership_id = membership.id
     and assignment.role_key = 'company_owner'
     and assignment.branch_id is null
    where membership.tenant_id = invitation_row.tenant_id and membership.status = 'active'
  ) then
    return query select 'rejected'::text, null::uuid;
    return;
  end if;
  if exists (
    select 1 from public.company_memberships as membership
    where membership.tenant_id = invitation_row.tenant_id and membership.user_id = actor_id
  ) then
    return query select 'rejected'::text, null::uuid;
    return;
  end if;

  insert into public.company_memberships (
    tenant_id, user_id, status, branch_access_mode, created_by_user_id
  ) values (
    invitation_row.tenant_id, actor_id, 'active', 'all_branches', actor_id
  ) returning id into new_membership_id;

  insert into public.membership_role_assignments (
    tenant_id, membership_id, role_key, branch_id, assigned_by_user_id
  ) values (
    invitation_row.tenant_id, new_membership_id, 'company_owner', null, actor_id
  );

  update app_private.company_admin_invitations
  set status = 'accepted', accepted_at = pg_catalog.clock_timestamp(), accepted_user_id = actor_id
  where id = invitation_row.id;

  perform app_private.write_provisioning_audit(
    'company_admin_invitation.accepted', invitation_row.tenant_id, actor_id, actor_id,
    pg_catalog.jsonb_build_object(
      'invitation_id', invitation_row.id, 'role_key', invitation_row.role_key,
      'membership_id', new_membership_id
    )
  );
  return query select 'accepted'::text, invitation_row.tenant_id;
end;
$function$;

create function public.master_revoke_company_admin_invitation(p_invitation_id uuid)
returns text
language plpgsql volatile security definer
set search_path = '' set row_security = off
as $function$
declare
  actor_id uuid;
  invitation_row app_private.company_admin_invitations%rowtype;
begin
  actor_id := app_private.assert_current_master();
  if p_invitation_id is null then
    raise exception 'Invitation is required' using errcode = '22023';
  end if;
  select invitation.* into invitation_row
  from app_private.company_admin_invitations as invitation
  where invitation.id = p_invitation_id for update;
  if not found or invitation_row.status <> 'pending' then
    return 'not_pending';
  end if;
  if invitation_row.expires_at <= pg_catalog.clock_timestamp() then
    update app_private.company_admin_invitations set status = 'expired' where id = invitation_row.id;
    perform app_private.write_provisioning_audit(
      'company_admin_invitation.expired', invitation_row.tenant_id, null, actor_id,
      pg_catalog.jsonb_build_object('invitation_id', invitation_row.id, 'role_key', invitation_row.role_key)
    );
    return 'expired';
  end if;
  update app_private.company_admin_invitations
  set status = 'revoked', revoked_at = pg_catalog.clock_timestamp(), revoked_by_user_id = actor_id
  where id = invitation_row.id;
  perform app_private.write_provisioning_audit(
    'company_admin_invitation.revoked', invitation_row.tenant_id, null, actor_id,
    pg_catalog.jsonb_build_object('invitation_id', invitation_row.id, 'role_key', invitation_row.role_key)
  );
  return 'revoked';
end;
$function$;

create function public.master_list_company_admin_invitations(p_tenant_id uuid)
returns table (invitation_id uuid, recipient_email text, role_key text, status text,
  created_at timestamptz, expires_at timestamptz, accepted_at timestamptz, revoked_at timestamptz)
language plpgsql stable security definer
set search_path = '' set row_security = off
as $function$
begin
  perform app_private.assert_current_master();
  if p_tenant_id is null then
    raise exception 'Company is required' using errcode = '22023';
  end if;
  return query
  select invitation.id, invitation.recipient_email, invitation.role_key,
    case when invitation.status = 'pending' and invitation.expires_at <= pg_catalog.statement_timestamp()
      then 'expired' else invitation.status end,
    invitation.created_at, invitation.expires_at, invitation.accepted_at, invitation.revoked_at
  from app_private.company_admin_invitations as invitation
  where invitation.tenant_id = p_tenant_id
  order by invitation.created_at desc, invitation.id;
end;
$function$;

create function public.master_expire_company_admin_invitations(p_tenant_id uuid)
returns integer
language plpgsql volatile security definer
set search_path = '' set row_security = off
as $function$
declare
  actor_id uuid;
  invitation_row app_private.company_admin_invitations%rowtype;
  expired_count integer := 0;
begin
  actor_id := app_private.assert_current_master();
  if p_tenant_id is null then
    raise exception 'Company is required' using errcode = '22023';
  end if;
  perform 1 from public.companies as company where company.id = p_tenant_id for update;
  if not found then raise exception 'Company not found' using errcode = 'P0002'; end if;

  for invitation_row in
    update app_private.company_admin_invitations as invitation
    set status = 'expired'
    where invitation.tenant_id = p_tenant_id
      and invitation.status = 'pending'
      and invitation.expires_at <= pg_catalog.clock_timestamp()
    returning invitation.*
  loop
    perform app_private.write_provisioning_audit(
      'company_admin_invitation.expired', p_tenant_id, null, actor_id,
      pg_catalog.jsonb_build_object('invitation_id', invitation_row.id, 'role_key', invitation_row.role_key)
    );
    expired_count := expired_count + 1;
  end loop;
  return expired_count;
end;
$function$;

alter function public.master_create_company_admin_invitation(uuid,text,uuid) owner to postgres;
alter function public.accept_company_admin_invitation(text) owner to postgres;
alter function public.master_revoke_company_admin_invitation(uuid) owner to postgres;
alter function public.master_list_company_admin_invitations(uuid) owner to postgres;
alter function public.master_expire_company_admin_invitations(uuid) owner to postgres;

revoke all on function public.master_create_company_admin_invitation(uuid,text,uuid) from public, anon, authenticated, service_role;
revoke all on function public.accept_company_admin_invitation(text) from public, anon, authenticated, service_role;
revoke all on function public.master_revoke_company_admin_invitation(uuid) from public, anon, authenticated, service_role;
revoke all on function public.master_list_company_admin_invitations(uuid) from public, anon, authenticated, service_role;
revoke all on function public.master_expire_company_admin_invitations(uuid) from public, anon, authenticated, service_role;
grant execute on function public.master_create_company_admin_invitation(uuid,text,uuid) to authenticated;
grant execute on function public.accept_company_admin_invitation(text) to authenticated;
grant execute on function public.master_revoke_company_admin_invitation(uuid) to authenticated;
grant execute on function public.master_list_company_admin_invitations(uuid) to authenticated;
grant execute on function public.master_expire_company_admin_invitations(uuid) to authenticated;

do $verify$
declare
  function_oid oid;
  procedure_name text;
begin
  foreach procedure_name in array array[
    'public.master_create_company_admin_invitation(uuid,text,uuid)',
    'public.accept_company_admin_invitation(text)',
    'public.master_revoke_company_admin_invitation(uuid)',
    'public.master_list_company_admin_invitations(uuid)',
    'public.master_expire_company_admin_invitations(uuid)'
  ] loop
    function_oid := pg_catalog.to_regprocedure(procedure_name);
    if function_oid is null or not exists (
      select 1 from pg_catalog.pg_proc as procedure_row
      join pg_catalog.pg_roles as role_row on role_row.oid = procedure_row.proowner
      where procedure_row.oid = function_oid and role_row.rolname = 'postgres'
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
      raise exception 'Company invitation RPC security contract failed: %', procedure_name;
    end if;
  end loop;
  if not exists (
    select 1 from pg_catalog.pg_class as relation_row
    join pg_catalog.pg_roles as role_row on role_row.oid = relation_row.relowner
    where relation_row.oid = 'app_private.company_admin_invitations'::pg_catalog.regclass
      and role_row.rolname = 'postgres' and relation_row.relrowsecurity and relation_row.relforcerowsecurity
      and not pg_catalog.has_table_privilege('anon', relation_row.oid, 'SELECT')
      and not pg_catalog.has_table_privilege('authenticated', relation_row.oid, 'SELECT')
      and not pg_catalog.has_table_privilege('service_role', relation_row.oid, 'SELECT')
  ) then
    raise exception 'Private invitation storage security contract failed';
  end if;
end;
$verify$;

comment on table app_private.company_admin_invitations is
  'Private single-use company administrator invitations; token digest only, no direct API table access.';
comment on function public.master_create_company_admin_invitation(uuid,text,uuid) is
  'Issues a seven-day one-time invitation for the fixed company_owner role; requires authenticated Admin Master and a separately approved company-scoped role.';
comment on function public.accept_company_admin_invitation(text) is
  'Accepts a private invitation only for auth.uid() with a confirmed matching Auth email; grants no Admin Master privileges.';
comment on function public.master_revoke_company_admin_invitation(uuid) is
  'Revokes a pending company administrator invitation under authenticated Admin Master authorization.';
comment on function public.master_list_company_admin_invitations(uuid) is
  'Lists invitation metadata only for authenticated Admin Master; never returns token material.';
comment on function public.master_expire_company_admin_invitations(uuid) is
  'Persists and audits expired invitations when explicitly processed by an authenticated Admin Master.';

commit;
