-- Tenant-owned employee invitations and membership administration.
-- No role, permission grant, invitation, membership or branch access is seeded by this migration.

begin;

do $preflight$
begin
  if current_user <> 'postgres' then raise exception 'Apply this migration as postgres'; end if;
  if pg_catalog.to_regclass('public.company_memberships') is null
    or pg_catalog.to_regclass('public.branch_access') is null
    or pg_catalog.to_regclass('public.membership_role_assignments') is null
    or pg_catalog.to_regclass('public.permission_definitions') is null
    or pg_catalog.to_regclass('app_private.provisioning_audit_events') is null
    or pg_catalog.to_regprocedure('app_private.has_tenant_permission(uuid,text,uuid)') is null
    or pg_catalog.to_regprocedure('app_private.can_access_branch(uuid,uuid)') is null then
    raise exception 'Company authorization foundation is required';
  end if;
  if pg_catalog.to_regclass('app_private.company_employee_invitations') is not null
    or pg_catalog.to_regprocedure('public.company_create_employee_invitation(uuid,text,uuid[],uuid)') is not null then
    raise exception 'Employee invitation objects already exist; inspect before applying';
  end if;
end;
$preflight$;

create table app_private.company_employee_invitations (
  id uuid primary key default pg_catalog.gen_random_uuid(),
  tenant_id uuid not null references public.companies(id) on delete restrict,
  recipient_email text not null check (recipient_email = pg_catalog.lower(pg_catalog.btrim(recipient_email)) and recipient_email ~ '^[^[:space:]@]+@[^[:space:]@]+\\.[^[:space:]@]+$'),
  branch_ids uuid[] not null check (cardinality(branch_ids) > 0),
  token_digest bytea not null unique check (pg_catalog.octet_length(token_digest) = 32),
  status text not null default 'pending' check (status in ('pending','accepted','expired','revoked')),
  created_by_user_id uuid not null references auth.users(id) on delete restrict,
  request_id uuid not null,
  created_at timestamptz not null default pg_catalog.clock_timestamp(),
  expires_at timestamptz not null,
  accepted_at timestamptz,
  accepted_user_id uuid references auth.users(id) on delete restrict,
  revoked_at timestamptz,
  revoked_by_user_id uuid references auth.users(id) on delete restrict,
  constraint company_employee_invitation_tenant_request_unique unique (tenant_id, request_id),
  constraint company_employee_invitation_state_fields check (
    (status='accepted' and accepted_at is not null and accepted_user_id is not null and revoked_at is null and revoked_by_user_id is null)
    or (status='revoked' and revoked_at is not null and revoked_by_user_id is not null and accepted_at is null and accepted_user_id is null)
    or (status in ('pending','expired') and accepted_at is null and accepted_user_id is null and revoked_at is null and revoked_by_user_id is null)
  )
);
alter table app_private.company_employee_invitations enable row level security;
alter table app_private.company_employee_invitations force row level security;
revoke all on table app_private.company_employee_invitations from public,anon,authenticated,service_role;
create unique index company_employee_invitations_one_pending_recipient on app_private.company_employee_invitations(tenant_id,recipient_email) where status='pending';

create function app_private.assert_company_membership_permission(p_tenant_id uuid, p_permission_key text)
returns uuid language plpgsql stable security definer set search_path='' set row_security=off as $function$
declare actor_id uuid;
begin
  if coalesce(auth.role(),'') <> 'authenticated' or auth.uid() is null then raise exception 'Authenticated session required' using errcode='42501'; end if;
  actor_id:=auth.uid();
  if p_tenant_id is null or not app_private.is_active_company_member(p_tenant_id) or not app_private.has_tenant_permission(p_tenant_id,p_permission_key,null) then raise exception 'Company membership permission denied' using errcode='42501'; end if;
  return actor_id;
end;
$function$;

create function public.company_create_employee_invitation(p_tenant_id uuid,p_recipient_email text,p_branch_ids uuid[],p_request_id uuid)
returns table (invitation_id uuid, invitation_token text, expires_at timestamptz)
language plpgsql volatile security definer set search_path='' set row_security=off as $function$
declare actor_id uuid; normalized_email text; token text; invitation app_private.company_employee_invitations%rowtype; branch_id uuid;
begin
  actor_id:=app_private.assert_company_membership_permission(p_tenant_id,'membership.invite');
  normalized_email:=lower(btrim(p_recipient_email));
  if p_request_id is null or normalized_email is null or normalized_email !~ '^[^[:space:]@]+@[^[:space:]@]+\\.[^[:space:]@]+$' or cardinality(p_branch_ids)=0 or cardinality(p_branch_ids) <> cardinality(array(select distinct value from unnest(p_branch_ids) value)) then raise exception 'Invalid employee invitation request' using errcode='22023'; end if;
  foreach branch_id in array p_branch_ids loop
    if not app_private.can_access_branch(p_tenant_id,branch_id) then raise exception 'Cannot invite for an unauthorized branch' using errcode='42501'; end if;
  end loop;
  perform pg_advisory_xact_lock(hashtextextended('employee-invite:'||p_tenant_id::text||':'||normalized_email,0));
  if exists(select 1 from public.company_memberships m join auth.users u on u.id=m.user_id where m.tenant_id=p_tenant_id and lower(u.email)=normalized_email and m.status in ('pending','active','suspended')) then raise exception 'This identity already has a company membership' using errcode='23505'; end if;
  update app_private.company_employee_invitations set status='expired' where tenant_id=p_tenant_id and recipient_email=normalized_email and status='pending' and expires_at<=clock_timestamp();
  token:=replace(gen_random_uuid()::text||gen_random_uuid()::text,'-','');
  insert into app_private.company_employee_invitations(tenant_id,recipient_email,branch_ids,token_digest,created_by_user_id,request_id,expires_at)
  values(p_tenant_id,normalized_email,p_branch_ids,sha256(convert_to(token,'UTF8')),actor_id,p_request_id,clock_timestamp()+interval '7 days') returning * into invitation;
  perform app_private.write_provisioning_audit('company_employee_invitation.issued',p_tenant_id,null,actor_id,jsonb_build_object('invitation_id',invitation.id,'branch_count',cardinality(p_branch_ids)));
  return query select invitation.id,token,invitation.expires_at;
end;
$function$;

create function public.accept_company_employee_invitation(p_invitation_token text)
returns table(outcome text,tenant_id uuid,membership_id uuid)
language plpgsql volatile security definer set search_path='' set row_security=off as $function$
declare actor_id uuid; actor_email text; invitation app_private.company_employee_invitations%rowtype; new_membership uuid; branch_id uuid;
begin
  if coalesce(auth.role(),'')<>'authenticated' or auth.uid() is null then raise exception 'Authenticated session required' using errcode='42501'; end if;
  actor_id:=auth.uid();
  if p_invitation_token is null or p_invitation_token !~ '^[0-9a-f]{64}$' then return query select 'rejected'::text,null::uuid,null::uuid; return; end if;
  select * into invitation from app_private.company_employee_invitations where token_digest=sha256(convert_to(p_invitation_token,'UTF8')) for update;
  if not found or invitation.status<>'pending' then return query select 'rejected'::text,null::uuid,null::uuid; return; end if;
  if invitation.expires_at<=clock_timestamp() then update app_private.company_employee_invitations set status='expired' where id=invitation.id; perform app_private.write_provisioning_audit('company_employee_invitation.expired',invitation.tenant_id,null,actor_id,jsonb_build_object('invitation_id',invitation.id)); return query select 'expired'::text,null::uuid,null::uuid; return; end if;
  select lower(email) into actor_email from auth.users where id=actor_id and email_confirmed_at is not null;
  if actor_email is null or actor_email<>invitation.recipient_email then return query select 'rejected'::text,null::uuid,null::uuid; return; end if;
  insert into public.company_memberships(tenant_id,user_id,status,branch_access_mode,created_by_user_id) values(invitation.tenant_id,actor_id,'pending','assigned_only',actor_id) returning id into new_membership;
  foreach branch_id in array invitation.branch_ids loop
    insert into public.branch_access(tenant_id,branch_id,membership_id,status,granted_by_user_id) values(invitation.tenant_id,branch_id,new_membership,'active',actor_id);
  end loop;
  update app_private.company_employee_invitations set status='accepted',accepted_at=clock_timestamp(),accepted_user_id=actor_id where id=invitation.id;
  perform app_private.write_provisioning_audit('company_employee_invitation.accepted',invitation.tenant_id,actor_id,actor_id,jsonb_build_object('invitation_id',invitation.id,'membership_id',new_membership));
  return query select 'pending_approval'::text,invitation.tenant_id,new_membership;
end;
$function$;

create function public.company_list_memberships(p_tenant_id uuid)
returns table(membership_id uuid,display_name text,status text,branch_access_mode text,created_at timestamptz,branch_count integer,role_count integer)
language plpgsql stable security definer set search_path='' set row_security=off as $function$
begin
  perform app_private.assert_company_membership_permission(p_tenant_id,'membership.read');
  return query select m.id,coalesce(p.display_name,'Identidade vinculada'),m.status,m.branch_access_mode,m.created_at,
    count(distinct ba.id) filter(where ba.status='active')::integer,count(distinct ra.id)::integer
  from public.company_memberships m left join public.user_profiles p on p.user_id=m.user_id
  left join public.branch_access ba on ba.tenant_id=m.tenant_id and ba.membership_id=m.id
  left join public.membership_role_assignments ra on ra.tenant_id=m.tenant_id and ra.membership_id=m.id
  where m.tenant_id=p_tenant_id group by m.id,p.display_name,m.status,m.branch_access_mode,m.created_at order by m.created_at desc,m.id;
end;
$function$;

create function public.company_set_membership_status(p_tenant_id uuid,p_membership_id uuid,p_status text)
returns text language plpgsql volatile security definer set search_path='' set row_security=off as $function$
declare actor_id uuid; target_user_id uuid;
begin
  actor_id:=app_private.assert_company_membership_permission(p_tenant_id,'membership.manage');
  if p_membership_id is null or p_status not in ('suspended','revoked') then raise exception 'Only suspension or revocation is allowed by this command' using errcode='22023'; end if;
  select user_id into target_user_id from public.company_memberships where tenant_id=p_tenant_id and id=p_membership_id and status in ('pending','active','suspended') for update;
  if not found then return 'not_found'; end if;
  if target_user_id=actor_id then raise exception 'Users cannot change their own membership status' using errcode='42501'; end if;
  update public.company_memberships set status=p_status where tenant_id=p_tenant_id and id=p_membership_id;
  perform app_private.write_provisioning_audit('company_membership.'||p_status,p_tenant_id,target_user_id,actor_id,jsonb_build_object('membership_id',p_membership_id));
  return p_status;
end;
$function$;

alter function app_private.assert_company_membership_permission(uuid,text) owner to postgres;
alter function public.company_create_employee_invitation(uuid,text,uuid[],uuid) owner to postgres;
alter function public.accept_company_employee_invitation(text) owner to postgres;
alter function public.company_list_memberships(uuid) owner to postgres;
alter function public.company_set_membership_status(uuid,uuid,text) owner to postgres;
revoke all on function app_private.assert_company_membership_permission(uuid,text),public.company_create_employee_invitation(uuid,text,uuid[],uuid),public.accept_company_employee_invitation(text),public.company_list_memberships(uuid),public.company_set_membership_status(uuid,uuid,text) from public,anon,authenticated,service_role;
grant execute on function public.company_create_employee_invitation(uuid,text,uuid[],uuid),public.accept_company_employee_invitation(text),public.company_list_memberships(uuid),public.company_set_membership_status(uuid,uuid,text) to authenticated;

commit;
