-- EC-AUTH-01: authenticated, tenant-scoped authorization contracts.
--
-- This migration does not create company memberships, role assignments or
-- permission grants. The branch.manage permission is inserted only as
-- pending_approval. Until the business role catalog is separately approved and
-- an authorized company membership receives that permission, branch writes
-- remain denied. Admin Master is not a tenant role and receives no access.
--
-- Existing app_private.provision_* routines accept p_actor_user_id and are
-- service_role-only. They are disabled for service_role here until a trusted
-- server contract can derive the human actor from a verified session. This
-- migration provides only a narrow authenticated branch RPC using auth.uid().

begin;

do $preflight$
declare
  postgres_can_bypass_rls boolean;
begin
  if current_user <> 'postgres' then
    raise exception 'Apply this migration as postgres';
  end if;

  if pg_catalog.to_regclass('public.companies') is null
    or pg_catalog.to_regclass('public.branches') is null
    or pg_catalog.to_regclass('public.company_memberships') is null
    or pg_catalog.to_regclass('public.membership_role_assignments') is null
    or pg_catalog.to_regclass('public.access_role_definitions') is null
    or pg_catalog.to_regclass('public.role_permission_grants') is null
    or pg_catalog.to_regclass('public.permission_definitions') is null
    or pg_catalog.to_regclass('app_private.provisioning_audit_events') is null
    or pg_catalog.to_regprocedure('app_private.write_provisioning_audit(text,uuid,uuid,uuid,jsonb)') is null
    or pg_catalog.to_regprocedure('app_private.has_tenant_permission(uuid,text,uuid)') is null
    or pg_catalog.to_regprocedure('auth.uid()') is null
    or pg_catalog.to_regprocedure('auth.role()') is null then
    raise exception 'Required tenant authorization or audit dependencies are missing';
  end if;

  select role_row.rolsuper or role_row.rolbypassrls
    into postgres_can_bypass_rls
  from pg_catalog.pg_roles as role_row
  where role_row.rolname = 'postgres';
  if postgres_can_bypass_rls is distinct from true then
    raise exception 'postgres must bypass forced RLS for the restricted authorization routines';
  end if;

  if not exists (
    select 1 from pg_catalog.pg_class as relation_row
    where relation_row.oid = 'public.companies'::pg_catalog.regclass
      and relation_row.relrowsecurity and relation_row.relforcerowsecurity
  ) or not exists (
    select 1 from pg_catalog.pg_class as relation_row
    where relation_row.oid = 'public.branches'::pg_catalog.regclass
      and relation_row.relrowsecurity and relation_row.relforcerowsecurity
  ) or not exists (
    select 1 from pg_catalog.pg_class as relation_row
    where relation_row.oid = 'public.company_memberships'::pg_catalog.regclass
      and relation_row.relrowsecurity and relation_row.relforcerowsecurity
  ) or not exists (
    select 1 from pg_catalog.pg_class as relation_row
    where relation_row.oid = 'public.membership_role_assignments'::pg_catalog.regclass
      and relation_row.relrowsecurity and relation_row.relforcerowsecurity
  ) or not exists (
    select 1 from pg_catalog.pg_class as relation_row
    where relation_row.oid = 'public.access_role_definitions'::pg_catalog.regclass
      and relation_row.relrowsecurity and relation_row.relforcerowsecurity
  ) or not exists (
    select 1 from pg_catalog.pg_class as relation_row
    where relation_row.oid = 'public.role_permission_grants'::pg_catalog.regclass
      and relation_row.relrowsecurity and relation_row.relforcerowsecurity
  ) or not exists (
    select 1 from pg_catalog.pg_class as relation_row
    where relation_row.oid = 'public.permission_definitions'::pg_catalog.regclass
      and relation_row.relrowsecurity and relation_row.relforcerowsecurity
  ) then
    raise exception 'Required tenant tables must have RLS enabled and forced';
  end if;

  if not exists (
    select 1
    from pg_catalog.pg_proc as procedure_row
    join pg_catalog.pg_roles as role_row on role_row.oid = procedure_row.proowner
    where procedure_row.oid = pg_catalog.to_regprocedure(
      'app_private.has_tenant_permission(uuid,text,uuid)'
    )
      and role_row.rolname = 'postgres'
      and procedure_row.prosecdef
      and 'search_path=""' = any(procedure_row.proconfig)
      and 'row_security=off' = any(procedure_row.proconfig)
  ) then
    raise exception 'Existing auth.uid()-derived tenant permission helper has an unsafe contract';
  end if;
  if not pg_catalog.has_function_privilege(
      'authenticated',
      'app_private.has_tenant_permission(uuid,text,uuid)',
      'EXECUTE'
    )
    or pg_catalog.has_function_privilege(
      'anon',
      'app_private.has_tenant_permission(uuid,text,uuid)',
      'EXECUTE'
    )
    or pg_catalog.has_function_privilege(
      'service_role',
      'app_private.has_tenant_permission(uuid,text,uuid)',
      'EXECUTE'
    ) then
    raise exception 'Existing tenant permission helper has unexpected effective EXECUTE grants';
  end if;

  if exists (
    select 1
    from (values
      ('public.companies'),
      ('public.branches'),
      ('public.company_memberships'),
      ('public.branch_access'),
      ('public.membership_role_assignments'),
      ('public.access_role_definitions'),
      ('public.role_permission_grants'),
      ('public.permission_definitions')
    ) as protected_table(table_name)
    cross join (values ('anon'), ('authenticated'), ('service_role')) as api_role(role_name)
    where pg_catalog.has_table_privilege(api_role.role_name, protected_table.table_name, 'INSERT')
      or pg_catalog.has_table_privilege(api_role.role_name, protected_table.table_name, 'UPDATE')
      or pg_catalog.has_table_privilege(api_role.role_name, protected_table.table_name, 'DELETE')
      or pg_catalog.has_table_privilege(api_role.role_name, protected_table.table_name, 'TRUNCATE')
      or pg_catalog.has_table_privilege(api_role.role_name, protected_table.table_name, 'REFERENCES')
      or pg_catalog.has_table_privilege(api_role.role_name, protected_table.table_name, 'TRIGGER')
  ) then
    raise exception 'An API role has direct write or administrative table privileges';
  end if;

  if exists (
    select 1
    from pg_catalog.pg_class as relation_row
    cross join lateral pg_catalog.aclexplode(
      coalesce(relation_row.relacl, pg_catalog.acldefault('r', relation_row.relowner))
    ) as table_acl
    where relation_row.oid = 'app_private.provisioning_audit_events'::pg_catalog.regclass
      and (table_acl.grantee <> relation_row.relowner or table_acl.grantor <> relation_row.relowner)
  ) then
    raise exception 'Provisioning audit table has an unexpected explicit ACL';
  end if;

  if not exists (
    select 1
    from pg_catalog.pg_proc as procedure_row
    join pg_catalog.pg_roles as role_row on role_row.oid = procedure_row.proowner
    where procedure_row.oid = pg_catalog.to_regprocedure(
      'app_private.write_provisioning_audit(text,uuid,uuid,uuid,jsonb)'
    )
      and role_row.rolname = 'postgres'
      and not procedure_row.prosecdef
      and 'search_path=""' = any(procedure_row.proconfig)
      and 'row_security=off' = any(procedure_row.proconfig)
  ) or not exists (
    select 1
    from pg_catalog.pg_trigger as trigger_row
    where trigger_row.tgrelid = 'app_private.provisioning_audit_events'::pg_catalog.regclass
      and trigger_row.tgname = 'provisioning_audit_events_append_only'
      and trigger_row.tgtype = 27
      and trigger_row.tgenabled in ('O', 'A')
      and trigger_row.tgfoid = pg_catalog.to_regprocedure(
        'app_private.prevent_provisioning_audit_mutation()'
      )
      and not trigger_row.tgisinternal
  ) then
    raise exception 'Transactional provisioning audit writer or append-only trigger is invalid';
  end if;

  if not exists (
    select 1 from pg_catalog.pg_constraint as constraint_row
    where constraint_row.conrelid = 'public.branches'::pg_catalog.regclass
      and constraint_row.conname = 'branches_tenant_code_unique'
      and constraint_row.contype = 'u'
  ) or not exists (
    select 1 from pg_catalog.pg_constraint as constraint_row
    where constraint_row.conrelid = 'public.branches'::pg_catalog.regclass
      and constraint_row.conname = 'branches_tenant_id_id_unique'
      and constraint_row.contype = 'u'
  ) then
    raise exception 'Required same-tenant branch integrity constraints are missing';
  end if;

  if not pg_catalog.has_table_privilege('authenticated', 'public.companies', 'SELECT')
    or not pg_catalog.has_table_privilege('authenticated', 'public.branches', 'SELECT') then
    raise exception 'Authenticated read grants required by the existing RLS contracts are missing';
  end if;
  if not pg_catalog.has_schema_privilege('authenticated', 'app_private', 'USAGE') then
    raise exception 'authenticated requires app_private schema USAGE for the RLS predicate';
  end if;
  if not pg_catalog.has_schema_privilege('authenticated', 'public', 'USAGE') then
    raise exception 'authenticated requires the existing public schema USAGE grant';
  end if;

  if pg_catalog.to_regprocedure('app_private.provision_company(uuid,text,uuid)') is null
    or pg_catalog.to_regprocedure('app_private.provision_branch(uuid,uuid,text,text)') is null
    or pg_catalog.to_regprocedure('app_private.provision_membership(uuid,uuid,uuid)') is null
    or pg_catalog.to_regprocedure('app_private.activate_membership(uuid,uuid,uuid)') is null
    or pg_catalog.to_regprocedure('app_private.set_membership_status(uuid,uuid,uuid,text)') is null
    or pg_catalog.to_regprocedure('app_private.grant_branch_access(uuid,uuid,uuid,uuid)') is null
    or pg_catalog.to_regprocedure('app_private.set_branch_access_status(uuid,uuid,uuid,text)') is null
    or pg_catalog.to_regprocedure('app_private.assign_membership_role(uuid,uuid,uuid,text,uuid)') is null
    or pg_catalog.to_regprocedure('app_private.revoke_membership_role(uuid,uuid,uuid,text,uuid)') is null
    or pg_catalog.to_regprocedure('app_private.grant_role_permission(uuid,text,text)') is null
    or pg_catalog.to_regprocedure('app_private.revoke_role_permission(uuid,text,text)') is null then
    raise exception 'Legacy actor-parameter provisioning dependency is missing';
  end if;

  if pg_catalog.to_regclass('app_private.branch_creation_requests') is not null
    or pg_catalog.to_regprocedure('app_private.can_manage_tenant_branches(uuid)') is not null
    or pg_catalog.to_regprocedure('public.create_branch(uuid,uuid,text,text)') is not null
    or pg_catalog.to_regprocedure('app_private.audit_company_authorization_change()') is not null
    or exists (
      select 1 from public.permission_definitions as permission_row
      where permission_row.permission_key = 'branch.manage'
    )
    or exists (
      select 1 from pg_catalog.pg_policy as policy_row
      where policy_row.polrelid in (
        'public.companies'::pg_catalog.regclass,
        'public.branches'::pg_catalog.regclass
      )
        and policy_row.polname in (
          'companies_select_branch_manager',
          'branches_select_branch_manager'
        )
    ) then
    raise exception 'EC-AUTH-01 objects already exist; inspect before proceeding';
  end if;
end;
$preflight$;

insert into public.permission_definitions (permission_key, description, approval_state)
values (
  'branch.manage',
  'Gerenciar metadados das filiais da própria empresa; concessão depende de aprovação de papel e autorização empresarial.',
  'pending_approval'
);

select app_private.write_provisioning_audit(
  'authorization.permission_definition.seeded',
  null,
  null,
  auth.uid(),
  pg_catalog.jsonb_build_object(
    'permission_key', 'branch.manage',
    'approval_state', 'pending_approval',
    'source', 'EC-AUTH-01'
  )
);

create table app_private.branch_creation_requests (
  actor_user_id uuid not null references auth.users(id) on delete restrict,
  tenant_id uuid not null references public.companies(id) on delete restrict,
  request_id uuid not null,
  normalized_code text not null,
  normalized_name text not null,
  branch_id uuid not null,
  created_at timestamptz not null default pg_catalog.clock_timestamp(),
  primary key (actor_user_id, tenant_id, request_id),
  constraint branch_creation_requests_tenant_branch_fk
    foreign key (tenant_id, branch_id)
    references public.branches(tenant_id, id) on delete restrict,
  constraint branch_creation_requests_code_length
    check (pg_catalog.length(normalized_code) between 1 and 40),
  constraint branch_creation_requests_name_length
    check (pg_catalog.length(normalized_name) between 1 and 160)
);

alter table app_private.branch_creation_requests owner to postgres;
alter table app_private.branch_creation_requests enable row level security;
alter table app_private.branch_creation_requests force row level security;
revoke all on table app_private.branch_creation_requests
  from public, anon, authenticated, service_role;

-- This predicate accepts only a tenant selector. The caller is always
-- auth.uid(); an Admin Master status or app metadata is never consulted. The
-- existing permission engine requires an active membership, an approved
-- company-scoped role assignment and an approved branch.manage grant.
create function app_private.can_manage_tenant_branches(p_tenant_id uuid)
returns boolean
language sql
stable
security definer
set search_path = ''
set row_security = off
as $can_manage$
  select coalesce(
    auth.role() = 'authenticated'
    and auth.uid() is not null
    and app_private.has_tenant_permission(p_tenant_id, 'branch.manage', null),
    false
  );
$can_manage$;

alter function app_private.can_manage_tenant_branches(uuid) owner to postgres;
revoke all on function app_private.can_manage_tenant_branches(uuid)
  from public, anon, authenticated, service_role;
grant execute on function app_private.can_manage_tenant_branches(uuid) to authenticated;

-- Existing membership policies remain intact. These additional read policies
-- expose only company/branch metadata to an explicitly authorized tenant
-- branch manager; they do not grant membership or operational data access.
create policy companies_select_branch_manager
  on public.companies for select to authenticated
  using (app_private.can_manage_tenant_branches(id));

create policy branches_select_branch_manager
  on public.branches for select to authenticated
  using (app_private.can_manage_tenant_branches(tenant_id));

-- A narrow authenticated RPC creates metadata only. tenant_id is an untrusted
-- resource selector, never proof of authority; authorization is rechecked
-- against auth.uid() and the locked tenant-scoped authorization row.
create function public.create_branch(
  p_tenant_id uuid,
  p_request_id uuid,
  p_code text,
  p_name text
)
returns uuid
language plpgsql
volatile
security definer
set search_path = ''
set row_security = off
as $create_branch$
declare
  actor_id uuid;
  membership_id uuid;
  authorization_assignment_id uuid;
  normalized_code text;
  normalized_name text;
  previous_request app_private.branch_creation_requests%rowtype;
  new_branch_id uuid;
begin
  if coalesce(auth.role(), '') <> 'authenticated' then
    raise exception 'Authenticated session required' using errcode = '42501';
  end if;

  actor_id := auth.uid();
  if actor_id is null then
    raise exception 'Authenticated user identity required' using errcode = '42501';
  end if;
  if p_tenant_id is null or p_request_id is null
    or p_code is null or p_name is null then
    raise exception 'Tenant, request key, branch code and name are required'
      using errcode = '22023';
  end if;

  normalized_code := pg_catalog.btrim(p_code);
  normalized_name := pg_catalog.btrim(p_name);
  if pg_catalog.length(normalized_code) not between 1 and 40
    or pg_catalog.length(normalized_name) not between 1 and 160 then
    raise exception 'Branch code or name is outside the allowed length'
      using errcode = '22023';
  end if;

  -- Serialize retries for this verified actor, tenant selector and request.
  perform pg_catalog.pg_advisory_xact_lock(
    pg_catalog.hashtextextended(
      actor_id::text || ':' || p_tenant_id::text || ':' || p_request_id::text,
      0
    )
  );

  -- Revalidate and lock every authorization component through commit. A
  -- concurrent membership, role, grant or company change waits for this
  -- operation; tenant_id remains only a scope selector.
  select membership.id, assignment.id
    into membership_id, authorization_assignment_id
  from public.company_memberships as membership
  join public.companies as company
    on company.id = membership.tenant_id
   and company.status = 'active'
  join public.membership_role_assignments as assignment
    on assignment.tenant_id = membership.tenant_id
   and assignment.membership_id = membership.id
   and assignment.branch_id is null
  join public.access_role_definitions as role_definition
    on role_definition.role_key = assignment.role_key
   and role_definition.scope = 'company'
   and role_definition.approval_state = 'approved'
  join public.role_permission_grants as role_grant
    on role_grant.role_key = role_definition.role_key
   and role_grant.permission_key = 'branch.manage'
  join public.permission_definitions as permission
    on permission.permission_key = role_grant.permission_key
   and permission.approval_state = 'approved'
  where membership.tenant_id = p_tenant_id
    and membership.user_id = actor_id
    and membership.status = 'active'
  for share of membership, company, assignment, role_definition, role_grant, permission;

  if membership_id is null or authorization_assignment_id is null then
    raise exception 'No active branch-management permission for this company'
      using errcode = '42501';
  end if;

  select request_row.*
    into previous_request
  from app_private.branch_creation_requests as request_row
  where request_row.actor_user_id = actor_id
    and request_row.tenant_id = p_tenant_id
    and request_row.request_id = p_request_id;

  if found then
    if previous_request.normalized_code is distinct from normalized_code
      or previous_request.normalized_name is distinct from normalized_name then
      raise exception 'Request key was already used for different branch data'
        using errcode = '22023';
    end if;
    return previous_request.branch_id;
  end if;

  insert into public.branches (tenant_id, code, name)
  values (p_tenant_id, normalized_code, normalized_name)
  returning id into new_branch_id;

  insert into app_private.branch_creation_requests (
    actor_user_id, tenant_id, request_id,
    normalized_code, normalized_name, branch_id
  ) values (
    actor_id, p_tenant_id, p_request_id,
    normalized_code, normalized_name, new_branch_id
  );

  perform app_private.write_provisioning_audit(
    'branch.provisioned',
    p_tenant_id,
    null,
    actor_id,
    pg_catalog.jsonb_build_object(
      'branch_id', new_branch_id,
      'creation_request_id', p_request_id,
      'code', normalized_code,
      'membership_id', membership_id,
      'role_assignment_id', authorization_assignment_id,
      'permission_key', 'branch.manage',
      'provisioning_path', 'authenticated_tenant_authorization'
    )
  );

  return new_branch_id;
end;
$create_branch$;

alter function public.create_branch(uuid, uuid, text, text) owner to postgres;
revoke all on function public.create_branch(uuid, uuid, text, text)
  from public, anon, authenticated, service_role;
grant execute on function public.create_branch(uuid, uuid, text, text) to authenticated;

-- Audit changes to authorization-bearing rows irrespective of whether a
-- future trusted routine or a database operator performs them. The human actor
-- is auth.uid() when present; a SQL operator is recorded only as a database
-- session role by write_provisioning_audit, never impersonated as a user.
create function app_private.audit_company_authorization_change()
returns trigger
language plpgsql
security definer
set search_path = ''
set row_security = off
as $audit_authorization$
declare
  current_row jsonb;
  old_row jsonb;
  audit_tenant_id uuid;
  old_tenant_id uuid;
  new_tenant_id uuid;
  subject_user_id uuid;
  target_membership_id uuid;
  record_key text;
begin
  if tg_op = 'DELETE' then
    current_row := pg_catalog.to_jsonb(old);
    old_row := current_row;
  else
    current_row := pg_catalog.to_jsonb(new);
    if tg_op = 'UPDATE' then old_row := pg_catalog.to_jsonb(old); end if;
  end if;

  if tg_table_name = 'companies' then
    old_tenant_id := nullif(old_row ->> 'id', '')::pg_catalog.uuid;
    new_tenant_id := nullif(current_row ->> 'id', '')::pg_catalog.uuid;
  else
    old_tenant_id := nullif(old_row ->> 'tenant_id', '')::pg_catalog.uuid;
    new_tenant_id := nullif(current_row ->> 'tenant_id', '')::pg_catalog.uuid;
  end if;
  audit_tenant_id := coalesce(new_tenant_id, old_tenant_id);

  if current_row ? 'user_id' then
    subject_user_id := nullif(current_row ->> 'user_id', '')::pg_catalog.uuid;
  elsif old_row ? 'user_id' then
    subject_user_id := nullif(old_row ->> 'user_id', '')::pg_catalog.uuid;
  elsif current_row ? 'membership_id' or old_row ? 'membership_id' then
    target_membership_id := coalesce(
      nullif(current_row ->> 'membership_id', '')::pg_catalog.uuid,
      nullif(old_row ->> 'membership_id', '')::pg_catalog.uuid
    );
    select membership.user_id into subject_user_id
    from public.company_memberships as membership
    where membership.id = target_membership_id
      and membership.tenant_id = audit_tenant_id;
  end if;

  record_key := coalesce(
    current_row ->> 'id',
    old_row ->> 'id',
    current_row ->> 'role_key',
    old_row ->> 'role_key',
    current_row ->> 'permission_key',
    old_row ->> 'permission_key'
  );

  perform app_private.write_provisioning_audit(
    'authorization.' || tg_table_name || '.' || pg_catalog.lower(tg_op),
    audit_tenant_id,
    subject_user_id,
    auth.uid(),
    pg_catalog.jsonb_build_object(
      'table_name', tg_table_schema || '.' || tg_table_name,
      'operation', tg_op,
      'record_key', record_key,
      'old_tenant_id', old_tenant_id,
      'new_tenant_id', new_tenant_id,
      'membership_id', coalesce(
        current_row ->> 'membership_id', old_row ->> 'membership_id'
      ),
      'branch_id', coalesce(current_row ->> 'branch_id', old_row ->> 'branch_id'),
      'role_key', coalesce(current_row ->> 'role_key', old_row ->> 'role_key'),
      'permission_key', coalesce(current_row ->> 'permission_key', old_row ->> 'permission_key'),
      'old_status', old_row ->> 'status',
      'new_status', current_row ->> 'status',
      'old_approval_state', old_row ->> 'approval_state',
      'new_approval_state', current_row ->> 'approval_state'
    )
  );

  return null;
end;
$audit_authorization$;

alter function app_private.audit_company_authorization_change() owner to postgres;
revoke all on function app_private.audit_company_authorization_change()
  from public, anon, authenticated, service_role;

create trigger authorization_companies_audit
after update or delete on public.companies
for each row execute function app_private.audit_company_authorization_change();
create trigger authorization_branches_audit
after update or delete on public.branches
for each row execute function app_private.audit_company_authorization_change();
create trigger authorization_memberships_audit
after insert or update or delete on public.company_memberships
for each row execute function app_private.audit_company_authorization_change();
create trigger authorization_branch_access_audit
after insert or update or delete on public.branch_access
for each row execute function app_private.audit_company_authorization_change();
create trigger authorization_role_assignments_audit
after insert or update or delete on public.membership_role_assignments
for each row execute function app_private.audit_company_authorization_change();
create trigger authorization_role_permission_grants_audit
after insert or update or delete on public.role_permission_grants
for each row execute function app_private.audit_company_authorization_change();
create trigger authorization_role_definitions_audit
after insert or update or delete on public.access_role_definitions
for each row execute function app_private.audit_company_authorization_change();
create trigger authorization_permission_definitions_audit
after insert or update or delete on public.permission_definitions
for each row execute function app_private.audit_company_authorization_change();

alter table public.companies enable always trigger authorization_companies_audit;
alter table public.branches enable always trigger authorization_branches_audit;
alter table public.company_memberships enable always trigger authorization_memberships_audit;
alter table public.branch_access enable always trigger authorization_branch_access_audit;
alter table public.membership_role_assignments enable always trigger authorization_role_assignments_audit;
alter table public.role_permission_grants enable always trigger authorization_role_permission_grants_audit;
alter table public.access_role_definitions enable always trigger authorization_role_definitions_audit;
alter table public.permission_definitions enable always trigger authorization_permission_definitions_audit;

-- The older operator-oriented routines accept an actor UUID and therefore are
-- not valid application-session contracts. Keep them unavailable to
-- service_role until replaced with authenticated, auth.uid()-derived APIs.
revoke execute on function app_private.provision_company(uuid, text, uuid) from service_role;
revoke execute on function app_private.provision_branch(uuid, uuid, text, text) from service_role;
revoke execute on function app_private.provision_membership(uuid, uuid, uuid) from service_role;
revoke execute on function app_private.activate_membership(uuid, uuid, uuid) from service_role;
revoke execute on function app_private.set_membership_status(uuid, uuid, uuid, text) from service_role;
revoke execute on function app_private.grant_branch_access(uuid, uuid, uuid, uuid) from service_role;
revoke execute on function app_private.set_branch_access_status(uuid, uuid, uuid, text) from service_role;
revoke execute on function app_private.assign_membership_role(uuid, uuid, uuid, text, uuid) from service_role;
revoke execute on function app_private.revoke_membership_role(uuid, uuid, uuid, text, uuid) from service_role;
revoke execute on function app_private.grant_role_permission(uuid, text, text) from service_role;
revoke execute on function app_private.revoke_role_permission(uuid, text, text) from service_role;

do $verify$
declare
  function_oid oid := pg_catalog.to_regprocedure('public.create_branch(uuid,uuid,text,text)');
  helper_oid oid := pg_catalog.to_regprocedure('app_private.can_manage_tenant_branches(uuid)');
  audit_function_oid oid := pg_catalog.to_regprocedure('app_private.audit_company_authorization_change()');
  owner_oid oid;
  authenticated_oid oid;
  request_table_oid oid := 'app_private.branch_creation_requests'::pg_catalog.regclass;
  request_table_owner_oid oid;
begin
  select role_row.oid into owner_oid
  from pg_catalog.pg_roles as role_row where role_row.rolname = 'postgres';
  select role_row.oid into authenticated_oid
  from pg_catalog.pg_roles as role_row where role_row.rolname = 'authenticated';
  select relation_row.relowner into request_table_owner_oid
  from pg_catalog.pg_class as relation_row where relation_row.oid = request_table_oid;

  if owner_oid is null or authenticated_oid is null
    or not exists (
      select 1 from pg_catalog.pg_proc as procedure_row
      where procedure_row.oid = function_oid
        and procedure_row.proowner = owner_oid
        and procedure_row.prosecdef
        and procedure_row.pronargs = 4
        and 'search_path=""' = any(procedure_row.proconfig)
        and 'row_security=off' = any(procedure_row.proconfig)
    )
    or not exists (
      select 1 from pg_catalog.pg_proc as procedure_row
      where procedure_row.oid = helper_oid
        and procedure_row.proowner = owner_oid
        and procedure_row.prosecdef
        and 'search_path=""' = any(procedure_row.proconfig)
        and 'row_security=off' = any(procedure_row.proconfig)
    )
    or not exists (
      select 1 from pg_catalog.pg_proc as procedure_row
      where procedure_row.oid = audit_function_oid
        and procedure_row.proowner = owner_oid
        and procedure_row.prosecdef
        and 'search_path=""' = any(procedure_row.proconfig)
        and 'row_security=off' = any(procedure_row.proconfig)
    ) then
    raise exception 'Branch authorization function owner or security configuration is invalid';
  end if;

  if not exists (
    select 1 from pg_catalog.pg_proc as procedure_row
    cross join lateral pg_catalog.aclexplode(
      coalesce(procedure_row.proacl, pg_catalog.acldefault('f', procedure_row.proowner))
    ) as function_acl
    where procedure_row.oid = function_oid
      and function_acl.grantee = authenticated_oid
      and function_acl.grantor = owner_oid
      and function_acl.privilege_type = 'EXECUTE'
      and not function_acl.is_grantable
  ) or exists (
    select 1 from pg_catalog.pg_proc as procedure_row
    cross join lateral pg_catalog.aclexplode(
      coalesce(procedure_row.proacl, pg_catalog.acldefault('f', procedure_row.proowner))
    ) as function_acl
    where procedure_row.oid in (function_oid, helper_oid)
      and (
        function_acl.grantee not in (owner_oid, authenticated_oid)
        or function_acl.grantor <> owner_oid
        or function_acl.privilege_type <> 'EXECUTE'
        or function_acl.is_grantable
      )
  ) then
    raise exception 'Branch authorization function ACL is broader than intended';
  end if;

  if pg_catalog.pg_has_role('anon', 'authenticated', 'USAGE')
    or pg_catalog.pg_has_role('service_role', 'authenticated', 'USAGE')
    or exists (
      select 1
      from pg_catalog.pg_roles as privileged_role
      where (privileged_role.rolsuper or privileged_role.rolbypassrls)
        and (
          pg_catalog.pg_has_role('authenticated', privileged_role.oid, 'USAGE')
          or pg_catalog.pg_has_role('anon', privileged_role.oid, 'USAGE')
        )
    ) then
    raise exception 'An API role inherits authenticated or RLS-bypass privileges';
  end if;

  if request_table_owner_oid is distinct from owner_oid
    or not exists (
      select 1 from pg_catalog.pg_class as relation_row
      where relation_row.oid = request_table_oid
        and relation_row.relrowsecurity
        and relation_row.relforcerowsecurity
    )
    or exists (
      select 1
      from pg_catalog.pg_class as relation_row
      cross join lateral pg_catalog.aclexplode(
        coalesce(relation_row.relacl, pg_catalog.acldefault('r', relation_row.relowner))
      ) as table_acl
      where relation_row.oid = request_table_oid
        and (table_acl.grantee <> owner_oid or table_acl.grantor <> owner_oid)
    )
    or pg_catalog.has_table_privilege('anon', request_table_oid, 'SELECT')
    or pg_catalog.has_table_privilege('authenticated', request_table_oid, 'SELECT')
    or pg_catalog.has_table_privilege('service_role', request_table_oid, 'SELECT')
    or exists (
      select 1 from pg_catalog.pg_policy as policy_row
      where policy_row.polrelid = request_table_oid
    ) then
    raise exception 'Private idempotency table ownership, RLS, policies or ACL is invalid';
  end if;

  if exists (
    select 1 from pg_catalog.pg_policy as policy_row
    where policy_row.polrelid in (
      'public.companies'::pg_catalog.regclass,
      'public.branches'::pg_catalog.regclass
    )
      and policy_row.polname in (
        'companies_select_branch_manager',
        'branches_select_branch_manager'
      )
      and (policy_row.polcmd <> 'r' or not policy_row.polpermissive)
  ) then
    raise exception 'Branch manager read policies have unexpected commands or mode';
  end if;

  if (
    select pg_catalog.count(*)
    from pg_catalog.pg_trigger as trigger_row
    where trigger_row.tgfoid = audit_function_oid
      and not trigger_row.tgisinternal
  ) <> 8 or exists (
    select 1
    from pg_catalog.pg_trigger as trigger_row
    where trigger_row.tgfoid = audit_function_oid
      and not trigger_row.tgisinternal
      and (
        trigger_row.tgenabled <> 'A'
        or (trigger_row.tgname = 'authorization_companies_audit'
          and (trigger_row.tgrelid <> 'public.companies'::pg_catalog.regclass or trigger_row.tgtype <> 25))
        or (trigger_row.tgname = 'authorization_branches_audit'
          and (trigger_row.tgrelid <> 'public.branches'::pg_catalog.regclass or trigger_row.tgtype <> 25))
        or (trigger_row.tgname = 'authorization_memberships_audit'
          and (trigger_row.tgrelid <> 'public.company_memberships'::pg_catalog.regclass or trigger_row.tgtype <> 29))
        or (trigger_row.tgname = 'authorization_branch_access_audit'
          and (trigger_row.tgrelid <> 'public.branch_access'::pg_catalog.regclass or trigger_row.tgtype <> 29))
        or (trigger_row.tgname = 'authorization_role_assignments_audit'
          and (trigger_row.tgrelid <> 'public.membership_role_assignments'::pg_catalog.regclass or trigger_row.tgtype <> 29))
        or (trigger_row.tgname = 'authorization_role_permission_grants_audit'
          and (trigger_row.tgrelid <> 'public.role_permission_grants'::pg_catalog.regclass or trigger_row.tgtype <> 29))
        or (trigger_row.tgname = 'authorization_role_definitions_audit'
          and (trigger_row.tgrelid <> 'public.access_role_definitions'::pg_catalog.regclass or trigger_row.tgtype <> 29))
        or (trigger_row.tgname = 'authorization_permission_definitions_audit'
          and (trigger_row.tgrelid <> 'public.permission_definitions'::pg_catalog.regclass or trigger_row.tgtype <> 29))
        or trigger_row.tgname not in (
          'authorization_companies_audit',
          'authorization_branches_audit',
          'authorization_memberships_audit',
          'authorization_branch_access_audit',
          'authorization_role_assignments_audit',
          'authorization_role_permission_grants_audit',
          'authorization_role_definitions_audit',
          'authorization_permission_definitions_audit'
        )
        or trigger_row.tgconstraint <> 0
        or trigger_row.tgqual is not null
        or pg_catalog.cardinality(trigger_row.tgattr) <> 0
        or pg_catalog.octet_length(trigger_row.tgargs) <> 0
        or trigger_row.tgoldtable is not null
        or trigger_row.tgnewtable is not null
      )
  ) or exists (
    select 1
    from pg_catalog.pg_proc as procedure_row
    cross join lateral pg_catalog.aclexplode(
      coalesce(procedure_row.proacl, pg_catalog.acldefault('f', procedure_row.proowner))
    ) as function_acl
    where procedure_row.oid = audit_function_oid
      and (function_acl.grantee <> owner_oid or function_acl.grantor <> owner_oid)
  ) then
    raise exception 'Authorization audit triggers or their function ACL are invalid';
  end if;

  if pg_catalog.has_function_privilege('service_role', function_oid, 'EXECUTE')
    or pg_catalog.has_function_privilege('anon', function_oid, 'EXECUTE')
    or pg_catalog.has_function_privilege('anon', helper_oid, 'EXECUTE')
    or pg_catalog.has_function_privilege('service_role', helper_oid, 'EXECUTE')
    or not pg_catalog.has_function_privilege('authenticated', helper_oid, 'EXECUTE')
    or pg_catalog.has_function_privilege('anon', audit_function_oid, 'EXECUTE')
    or pg_catalog.has_function_privilege('authenticated', audit_function_oid, 'EXECUTE')
    or pg_catalog.has_function_privilege('service_role', audit_function_oid, 'EXECUTE') then
    raise exception 'A non-user API role can execute a branch authorization function';
  end if;

  if exists (
    select 1
    from pg_catalog.unnest(array[
      pg_catalog.to_regprocedure('app_private.provision_company(uuid,text,uuid)'),
      pg_catalog.to_regprocedure('app_private.provision_branch(uuid,uuid,text,text)'),
      pg_catalog.to_regprocedure('app_private.provision_membership(uuid,uuid,uuid)'),
      pg_catalog.to_regprocedure('app_private.activate_membership(uuid,uuid,uuid)'),
      pg_catalog.to_regprocedure('app_private.set_membership_status(uuid,uuid,uuid,text)'),
      pg_catalog.to_regprocedure('app_private.grant_branch_access(uuid,uuid,uuid,uuid)'),
      pg_catalog.to_regprocedure('app_private.set_branch_access_status(uuid,uuid,uuid,text)'),
      pg_catalog.to_regprocedure('app_private.assign_membership_role(uuid,uuid,uuid,text,uuid)'),
      pg_catalog.to_regprocedure('app_private.revoke_membership_role(uuid,uuid,uuid,text,uuid)'),
      pg_catalog.to_regprocedure('app_private.grant_role_permission(uuid,text,text)'),
      pg_catalog.to_regprocedure('app_private.revoke_role_permission(uuid,text,text)')
    ]) as legacy_function(function_oid)
    where pg_catalog.has_function_privilege('anon', legacy_function.function_oid, 'EXECUTE')
      or pg_catalog.has_function_privilege('authenticated', legacy_function.function_oid, 'EXECUTE')
      or pg_catalog.has_function_privilege('service_role', legacy_function.function_oid, 'EXECUTE')
  ) then
    raise exception 'Legacy actor-parameter provisioning routines remain executable by an API role';
  end if;
end;
$verify$;

comment on function app_private.can_manage_tenant_branches(uuid) is
  'RLS predicate for metadata access through an active auth.uid()-derived company membership and approved branch.manage permission; does not grant operational access.';

comment on function public.create_branch(uuid, uuid, text, text) is
  'Creates branch metadata only for authenticated auth.uid() with a locked active company membership and approved branch.manage permission. Idempotent per actor, tenant and request ID; audits atomically; grants no membership or operational access.';

comment on table app_private.branch_creation_requests is
  'Private idempotency records for authenticated branch creation; no client API privileges.';

comment on function app_private.audit_company_authorization_change() is
  'Append-only audit trigger for company, branch, membership and permission changes; actor identity comes only from auth.uid() when available.';

commit;
