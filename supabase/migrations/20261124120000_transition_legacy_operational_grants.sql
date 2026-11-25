-- Replace legacy global operational grants with explicit company/branch grants.
-- The migration is intentionally atomic: it materializes only currently effective
-- coverage, proves that coverage exists, and only then removes transaction.*
-- rows from the global grant table. It never enables a module or transaction.
begin;

do $preflight$
begin
  if current_user <> 'postgres'
    or pg_catalog.to_regclass('public.company_role_permission_grants') is null
    or pg_catalog.to_regclass('public.role_permission_grants') is null
    or pg_catalog.to_regclass('public.permission_definitions') is null
    or pg_catalog.to_regclass('public.membership_role_assignments') is null
    or pg_catalog.to_regclass('public.company_memberships') is null
    or pg_catalog.to_regclass('public.branch_access') is null
    or pg_catalog.to_regprocedure('app_private.assert_current_master()') is null
    or pg_catalog.to_regprocedure('app_private.write_provisioning_audit(text,uuid,uuid,uuid,jsonb)') is null then
    raise exception 'Legacy operational grant transition prerequisites are missing';
  end if;
end;
$preflight$;

lock table public.role_permission_grants in share row exclusive mode;
lock table public.company_role_permission_grants in share row exclusive mode;
lock table public.permission_definitions in share row exclusive mode;
lock table public.company_memberships in share row exclusive mode;
lock table public.membership_role_assignments in share row exclusive mode;
lock table public.branch_access in share row exclusive mode;
lock table public.branches in share row exclusive mode;

alter table public.permission_definitions
  add column grant_scope text not null default 'branch'
  check (grant_scope in ('company', 'branch'));

update public.permission_definitions
set grant_scope = 'company'
where permission_key = any(array[
  'transaction.masterdata.party.read',
  'transaction.masterdata.party.manage',
  'transaction.masterdata.catalog.read',
  'transaction.masterdata.catalog.product.manage',
  'transaction.masterdata.catalog.product.update',
  'transaction.masterdata.catalog.product.read',
  'transaction.masterdata.catalog.service.manage'
]);

alter table public.company_role_permission_grants
  drop constraint company_role_permission_grants_pkey;
alter table public.company_role_permission_grants
  alter column branch_id drop not null;
alter table public.company_role_permission_grants
  add column grant_scope text not null default 'branch'
  check (grant_scope in ('company', 'branch'));
alter table public.company_role_permission_grants
  add constraint company_role_permission_grants_scope_branch_check
  check ((grant_scope = 'company' and branch_id is null) or (grant_scope = 'branch' and branch_id is not null));
alter table public.company_role_permission_grants
  add constraint company_role_permission_grants_scope_unique
  unique nulls not distinct (tenant_id, branch_id, role_key, permission_key);

create or replace function app_private.has_tenant_permission(
  p_tenant_id uuid,
  p_permission_key text,
  p_branch_id uuid default null
)
returns boolean
language sql
stable
security definer
set search_path = ''
set row_security = off
as $function$
  select exists (
    select 1
    from public.company_memberships as membership
    join public.companies as company
      on company.id = membership.tenant_id
     and company.status = 'active'
    join public.membership_role_assignments as assignment
      on assignment.tenant_id = membership.tenant_id
     and assignment.membership_id = membership.id
    join public.access_role_definitions as role_definition
      on role_definition.role_key = assignment.role_key
     and role_definition.approval_state = 'approved'
    join public.permission_definitions as permission
      on permission.permission_key = p_permission_key
     and permission.approval_state = 'approved'
    where membership.tenant_id = p_tenant_id
      and membership.user_id = auth.uid()
      and membership.status = 'active'
      and (
        (role_definition.scope = 'company' and assignment.branch_id is null)
        or (
          role_definition.scope = 'branch'
          and p_branch_id is not null
          and assignment.branch_id = p_branch_id
        )
      )
      and (
        (permission.permission_key not like 'transaction.%'
          and exists (
            select 1 from public.role_permission_grants global_grant
            where global_grant.role_key = role_definition.role_key
              and global_grant.permission_key = permission.permission_key
          ))
        or exists (
          select 1 from public.company_role_permission_grants scoped_grant
          where scoped_grant.tenant_id = p_tenant_id
            and scoped_grant.role_key = role_definition.role_key
            and scoped_grant.permission_key = permission.permission_key
            and scoped_grant.grant_scope = permission.grant_scope
            and (
              (permission.grant_scope = 'company' and scoped_grant.branch_id is null)
              or (permission.grant_scope = 'branch' and p_branch_id is not null and scoped_grant.branch_id = p_branch_id)
            )
        )
      )
      and (p_branch_id is null or app_private.can_access_branch(p_tenant_id, p_branch_id))
  );
$function$;

create or replace function public.master_set_role_permission_grant(
  p_role_key text,
  p_permission_key text,
  p_operation text,
  p_reason text
)
returns text
language plpgsql
volatile
security definer
set search_path = ''
set row_security = off
as $function$
declare
  actor_id uuid;
  role_state text;
  permission_state text;
  normalized_reason text := pg_catalog.btrim(coalesce(p_reason, ''));
  changed_count integer;
begin
  actor_id := app_private.assert_current_master();
  if p_role_key is null or p_permission_key is null or p_operation not in ('grant', 'revoke')
    or pg_catalog.length(normalized_reason) not between 10 and 1000 then
    raise exception 'Role, permission, operation and justification between 10 and 1000 characters are required' using errcode = '22023';
  end if;
  if p_permission_key like 'transaction.%' then
    raise exception 'Operational permissions must be administered by company or branch' using errcode = '55000';
  end if;
  select approval_state into role_state from public.access_role_definitions where role_key = p_role_key for update;
  if not found then raise exception 'Role not found' using errcode = 'P0002'; end if;
  select approval_state into permission_state from public.permission_definitions where permission_key = p_permission_key for update;
  if not found then raise exception 'Permission not found' using errcode = 'P0002'; end if;
  if p_operation = 'grant' then
    if role_state <> 'approved' or permission_state <> 'approved' then
      raise exception 'Approved role and permission are required before granting' using errcode = '55000';
    end if;
    insert into public.role_permission_grants(role_key, permission_key)
    values (p_role_key, p_permission_key) on conflict do nothing;
    get diagnostics changed_count = row_count;
  else
    delete from public.role_permission_grants where role_key = p_role_key and permission_key = p_permission_key;
    get diagnostics changed_count = row_count;
  end if;
  perform app_private.write_provisioning_audit(
    'master_role_permission.' || p_operation, null, null, actor_id,
    pg_catalog.jsonb_build_object('role_key', p_role_key, 'permission_key', p_permission_key,
      'changed', changed_count = 1, 'reason', normalized_reason)
  );
  return case when changed_count = 1 then p_operation else 'unchanged' end;
end;
$function$;

create or replace function public.master_set_company_role_permission_grant(
  p_tenant_id uuid,
  p_branch_id uuid,
  p_role_key text,
  p_permission_key text,
  p_operation text,
  p_reason text
)
returns text
language plpgsql
volatile
security definer
set search_path = ''
set row_security = off
as $function$
declare
  actor_id uuid;
  role_state text;
  permission_state text;
  permission_scope text;
  changed_count integer;
  normalized_reason text := pg_catalog.btrim(coalesce(p_reason, ''));
begin
  actor_id := app_private.assert_current_master();
  if p_tenant_id is null or p_role_key is null or p_permission_key is null
    or p_operation not in ('grant', 'revoke')
    or pg_catalog.length(normalized_reason) not between 10 and 1000 then
    raise exception 'Company, role, permission, operation and justification between 10 and 1000 characters are required' using errcode = '22023';
  end if;
  if p_permission_key not like 'transaction.%' then
    raise exception 'Only operational permissions may be administered in company scope' using errcode = '22023';
  end if;
  perform pg_catalog.pg_advisory_xact_lock(pg_catalog.hashtextextended(
    'company-role-permission:' || p_tenant_id::text || ':' || coalesce(p_branch_id::text, 'company') || ':' || p_role_key || ':' || p_permission_key, 0
  ));
  perform 1 from public.companies where id = p_tenant_id and status = 'active' for update;
  if not found then raise exception 'Active company not found' using errcode = 'P0002'; end if;
  select approval_state, grant_scope into permission_state, permission_scope
  from public.permission_definitions where permission_key = p_permission_key for update;
  if not found then raise exception 'Permission not found' using errcode = 'P0002'; end if;
  if (permission_scope = 'company' and p_branch_id is not null)
    or (permission_scope = 'branch' and p_branch_id is null) then
    raise exception 'Permission scope does not match the selected company or branch' using errcode = '22023';
  end if;
  if p_branch_id is not null then
    perform 1 from public.branches where tenant_id = p_tenant_id and id = p_branch_id and status = 'active' for update;
    if not found then raise exception 'Active branch not found for company' using errcode = 'P0002'; end if;
  end if;
  select approval_state into role_state from public.access_role_definitions where role_key = p_role_key for update;
  if not found then raise exception 'Role not found' using errcode = 'P0002'; end if;
  if p_operation = 'grant' then
    if role_state <> 'approved' or permission_state <> 'approved' then
      raise exception 'Approved role and permission are required before granting' using errcode = '55000';
    end if;
    insert into public.company_role_permission_grants(
      tenant_id, branch_id, grant_scope, role_key, permission_key, reason, created_by_user_id
    ) values (
      p_tenant_id, p_branch_id, permission_scope, p_role_key, p_permission_key, normalized_reason, actor_id
    ) on conflict (tenant_id, branch_id, role_key, permission_key) do nothing;
    get diagnostics changed_count = row_count;
  else
    delete from public.company_role_permission_grants
      where tenant_id = p_tenant_id and branch_id is not distinct from p_branch_id
        and role_key = p_role_key and permission_key = p_permission_key;
    get diagnostics changed_count = row_count;
  end if;
  perform app_private.write_provisioning_audit(
    'master_company_role_permission.' || p_operation, p_tenant_id, null, actor_id,
    pg_catalog.jsonb_build_object('branch_id', p_branch_id, 'grant_scope', permission_scope,
      'role_key', p_role_key, 'permission_key', p_permission_key,
      'changed', changed_count = 1, 'reason', normalized_reason)
  );
  return case when changed_count = 1 then p_operation else 'unchanged' end;
end;
$function$;

drop function public.master_list_company_scoped_permission_grants(uuid);
create function public.master_list_company_scoped_permission_grants(p_tenant_id uuid)
returns table (
  branch_id uuid,
  branch_code text,
  branch_name text,
  grant_scope text,
  role_key text,
  permission_key text,
  reason text,
  created_at timestamptz
)
language plpgsql
stable
security definer
set search_path = ''
set row_security = off
as $function$
begin
  perform app_private.assert_current_master();
  if p_tenant_id is null or not exists (select 1 from public.companies where id = p_tenant_id) then
    raise exception 'Company not found' using errcode = 'P0002';
  end if;
  return query
    select grant_row.branch_id, branch.code, branch.name, grant_row.grant_scope,
      grant_row.role_key, grant_row.permission_key, grant_row.reason, grant_row.created_at
    from public.company_role_permission_grants grant_row
    left join public.branches branch
      on branch.tenant_id = grant_row.tenant_id and branch.id = grant_row.branch_id
    where grant_row.tenant_id = p_tenant_id
    order by grant_row.grant_scope, branch.code nulls first, grant_row.role_key, grant_row.permission_key;
end;
$function$;

do $transition$
begin
  with candidates as (
    select distinct on (membership.tenant_id, global_grant.role_key, global_grant.permission_key)
      membership.tenant_id, null::uuid as branch_id, 'company'::text as grant_scope,
      global_grant.role_key, global_grant.permission_key,
      'Migração auditada de grant global operacional legado'::text as reason,
      assignment.assigned_by_user_id as created_by_user_id
    from public.role_permission_grants global_grant
    join public.permission_definitions permission on permission.permission_key = global_grant.permission_key
    join public.membership_role_assignments assignment on assignment.role_key = global_grant.role_key
    join public.access_role_definitions role_definition on role_definition.role_key = assignment.role_key
    join public.company_memberships membership on membership.tenant_id = assignment.tenant_id and membership.id = assignment.membership_id
    join public.companies company on company.id = membership.tenant_id and company.status = 'active'
    where global_grant.permission_key like 'transaction.%'
      and permission.grant_scope = 'company'
      and membership.status = 'active'
      and role_definition.scope = 'company'
      and assignment.branch_id is null
    order by membership.tenant_id, global_grant.role_key, global_grant.permission_key, assignment.assigned_by_user_id
  ), inserted as (
    insert into public.company_role_permission_grants(tenant_id, branch_id, grant_scope, role_key, permission_key, reason, created_by_user_id)
    select tenant_id, branch_id, grant_scope, role_key, permission_key, reason, created_by_user_id from candidates
    on conflict (tenant_id, branch_id, role_key, permission_key) do nothing
    returning tenant_id, branch_id, grant_scope, role_key, permission_key, created_by_user_id
  )
  insert into app_private.provisioning_audit_events(
    event_key, tenant_id, subject_user_id, actor_user_id, actor_database_role, actor_api_role, details
  ) select
    'master_legacy_global_grant.materialized', tenant_id, null, created_by_user_id,
    session_user::text, null,
    pg_catalog.jsonb_build_object('grant_scope', grant_scope, 'branch_id', branch_id,
      'role_key', role_key, 'permission_key', permission_key, 'source', 'legacy_global_grant')
  from inserted;

  with candidates as (
    select distinct on (membership.tenant_id, branch.id, global_grant.role_key, global_grant.permission_key)
      membership.tenant_id, branch.id as branch_id, 'branch'::text as grant_scope,
      global_grant.role_key, global_grant.permission_key,
      'Migração auditada de grant global operacional legado'::text as reason,
      assignment.assigned_by_user_id as created_by_user_id
    from public.role_permission_grants global_grant
    join public.permission_definitions permission on permission.permission_key = global_grant.permission_key
    join public.membership_role_assignments assignment on assignment.role_key = global_grant.role_key
    join public.access_role_definitions role_definition on role_definition.role_key = assignment.role_key
    join public.company_memberships membership on membership.tenant_id = assignment.tenant_id and membership.id = assignment.membership_id
    join public.companies company on company.id = membership.tenant_id and company.status = 'active'
    join public.branches branch on branch.tenant_id = membership.tenant_id and branch.status = 'active'
    where global_grant.permission_key like 'transaction.%'
      and permission.grant_scope = 'branch'
      and membership.status = 'active'
      and (
        (role_definition.scope = 'company' and assignment.branch_id is null and (
          membership.branch_access_mode = 'all_branches'
          or exists (select 1 from public.branch_access access_link where access_link.tenant_id = membership.tenant_id and access_link.membership_id = membership.id and access_link.branch_id = branch.id and access_link.status = 'active')
        ))
        or (role_definition.scope = 'branch' and assignment.branch_id = branch.id and (
          membership.branch_access_mode = 'all_branches'
          or exists (select 1 from public.branch_access access_link where access_link.tenant_id = membership.tenant_id and access_link.membership_id = membership.id and access_link.branch_id = branch.id and access_link.status = 'active')
        ))
      )
    order by membership.tenant_id, branch.id, global_grant.role_key, global_grant.permission_key, assignment.assigned_by_user_id
  ), inserted as (
    insert into public.company_role_permission_grants(tenant_id, branch_id, grant_scope, role_key, permission_key, reason, created_by_user_id)
    select tenant_id, branch_id, grant_scope, role_key, permission_key, reason, created_by_user_id from candidates
    on conflict (tenant_id, branch_id, role_key, permission_key) do nothing
    returning tenant_id, branch_id, grant_scope, role_key, permission_key, created_by_user_id
  )
  insert into app_private.provisioning_audit_events(
    event_key, tenant_id, subject_user_id, actor_user_id, actor_database_role, actor_api_role, details
  ) select
    'master_legacy_global_grant.materialized', tenant_id, null, created_by_user_id,
    session_user::text, null,
    pg_catalog.jsonb_build_object('grant_scope', grant_scope, 'branch_id', branch_id,
      'role_key', role_key, 'permission_key', permission_key, 'source', 'legacy_global_grant')
  from inserted;

  if exists (
    select 1
    from public.role_permission_grants global_grant
    join public.permission_definitions permission on permission.permission_key = global_grant.permission_key
    join public.membership_role_assignments assignment on assignment.role_key = global_grant.role_key
    join public.access_role_definitions role_definition on role_definition.role_key = assignment.role_key
    join public.company_memberships membership on membership.tenant_id = assignment.tenant_id and membership.id = assignment.membership_id and membership.status = 'active'
    join public.companies company on company.id = membership.tenant_id and company.status = 'active'
    where global_grant.permission_key like 'transaction.%'
      and permission.grant_scope = 'company'
      and role_definition.scope = 'company' and assignment.branch_id is null
      and not exists (select 1 from public.company_role_permission_grants scoped
        where scoped.tenant_id = membership.tenant_id and scoped.branch_id is null
          and scoped.role_key = global_grant.role_key and scoped.permission_key = global_grant.permission_key
          and scoped.grant_scope = 'company')
  ) then
    raise exception 'Legacy company-scoped operational grant coverage is incomplete';
  end if;

  if exists (
    select 1
    from public.role_permission_grants global_grant
    join public.permission_definitions permission on permission.permission_key = global_grant.permission_key
    join public.membership_role_assignments assignment on assignment.role_key = global_grant.role_key
    join public.access_role_definitions role_definition on role_definition.role_key = assignment.role_key
    join public.company_memberships membership on membership.tenant_id = assignment.tenant_id and membership.id = assignment.membership_id and membership.status = 'active'
    join public.companies company on company.id = membership.tenant_id and company.status = 'active'
    join public.branches branch on branch.tenant_id = membership.tenant_id and branch.status = 'active'
    where global_grant.permission_key like 'transaction.%'
      and permission.grant_scope = 'branch'
      and ((role_definition.scope = 'company' and assignment.branch_id is null) or (role_definition.scope = 'branch' and assignment.branch_id = branch.id))
      and (membership.branch_access_mode = 'all_branches' or exists (select 1 from public.branch_access access_link where access_link.tenant_id = membership.tenant_id and access_link.membership_id = membership.id and access_link.branch_id = branch.id and access_link.status = 'active'))
      and not exists (select 1 from public.company_role_permission_grants scoped
        where scoped.tenant_id = membership.tenant_id and scoped.branch_id = branch.id
          and scoped.role_key = global_grant.role_key and scoped.permission_key = global_grant.permission_key
          and scoped.grant_scope = 'branch')
  ) then
    raise exception 'Legacy branch-scoped operational grant coverage is incomplete';
  end if;

  delete from public.role_permission_grants where permission_key like 'transaction.%';
end;
$transition$;

-- The pilot migration predates grant_scope and stored all of its grants with a
-- branch. A shared master-data permission now has company semantics under D12.
-- First materialize a company tuple for every such legacy branch tuple. This
-- is the explicit, audited contract change; it is not a fallback or automatic
-- grant for a company without an existing scoped grant.
insert into public.company_role_permission_grants(
  tenant_id, branch_id, grant_scope, role_key, permission_key, reason, created_by_user_id
)
select distinct on (legacy_scoped.tenant_id, legacy_scoped.role_key, legacy_scoped.permission_key)
  legacy_scoped.tenant_id,
  null::uuid,
  'company',
  legacy_scoped.role_key,
  legacy_scoped.permission_key,
  'Normalização auditada de grant legado de cadastro compartilhado',
  legacy_scoped.created_by_user_id
from public.company_role_permission_grants legacy_scoped
join public.permission_definitions permission
  on permission.permission_key = legacy_scoped.permission_key
where permission.grant_scope = 'company'
  and legacy_scoped.grant_scope = 'branch'
  and legacy_scoped.branch_id is not null
order by legacy_scoped.tenant_id, legacy_scoped.role_key, legacy_scoped.permission_key,
  legacy_scoped.created_at, legacy_scoped.branch_id
on conflict (tenant_id, branch_id, role_key, permission_key) do nothing;

with replaced as (
  delete from public.company_role_permission_grants legacy_scoped
  using public.permission_definitions permission
  where permission.permission_key = legacy_scoped.permission_key
    and permission.grant_scope = 'company'
    and legacy_scoped.grant_scope = 'branch'
    and legacy_scoped.branch_id is not null
  returning legacy_scoped.tenant_id, legacy_scoped.branch_id, legacy_scoped.role_key,
    legacy_scoped.permission_key, legacy_scoped.created_by_user_id
)
insert into app_private.provisioning_audit_events(
  event_key, tenant_id, subject_user_id, actor_user_id, actor_database_role, actor_api_role, details
)
select
  'master_legacy_scoped_grant.normalized', tenant_id, null, created_by_user_id,
  session_user::text, null,
  pg_catalog.jsonb_build_object('from_scope', 'branch', 'to_scope', 'company',
    'branch_id', branch_id, 'role_key', role_key, 'permission_key', permission_key,
    'source', 'pre_grant_scope_pilot',
    'policy', 'D12_shared_master_data_company_scope')
from replaced;

alter function app_private.has_tenant_permission(uuid, text, uuid) owner to postgres;
alter function public.master_set_role_permission_grant(text, text, text, text) owner to postgres;
alter function public.master_set_company_role_permission_grant(uuid, uuid, text, text, text, text) owner to postgres;
alter function public.master_list_company_scoped_permission_grants(uuid) owner to postgres;

revoke all on function app_private.has_tenant_permission(uuid, text, uuid) from public, anon, authenticated, service_role;
grant execute on function app_private.has_tenant_permission(uuid, text, uuid) to authenticated;
revoke all on function public.master_set_role_permission_grant(text, text, text, text),
  public.master_set_company_role_permission_grant(uuid, uuid, text, text, text, text),
  public.master_list_company_scoped_permission_grants(uuid)
  from public, anon, authenticated, service_role;
grant execute on function public.master_set_role_permission_grant(text, text, text, text),
  public.master_set_company_role_permission_grant(uuid, uuid, text, text, text, text),
  public.master_list_company_scoped_permission_grants(uuid)
  to authenticated;

do $verify$
declare
  routine_oid oid;
begin
  if exists (select 1 from public.role_permission_grants where permission_key like 'transaction.%') then
    raise exception 'Legacy global operational grants must not remain';
  end if;
  if exists (select 1 from public.company_role_permission_grants grant_row join public.permission_definitions permission using (permission_key)
    where grant_row.grant_scope <> permission.grant_scope
      or (grant_row.grant_scope = 'company' and grant_row.branch_id is not null)
      or (grant_row.grant_scope = 'branch' and grant_row.branch_id is null)) then
    raise exception 'Scoped grant scope integrity check failed';
  end if;
  foreach routine_oid in array array[
    pg_catalog.to_regprocedure('app_private.has_tenant_permission(uuid,text,uuid)'),
    pg_catalog.to_regprocedure('public.master_set_role_permission_grant(text,text,text,text)'),
    pg_catalog.to_regprocedure('public.master_set_company_role_permission_grant(uuid,uuid,text,text,text,text)'),
    pg_catalog.to_regprocedure('public.master_list_company_scoped_permission_grants(uuid)')
  ] loop
    if routine_oid is null or not exists (
      select 1 from pg_catalog.pg_proc procedure_row join pg_catalog.pg_roles owner_role on owner_role.oid = procedure_row.proowner
      where procedure_row.oid = routine_oid and owner_role.rolname = 'postgres' and procedure_row.prosecdef
        and 'search_path=""' = any(procedure_row.proconfig) and 'row_security=off' = any(procedure_row.proconfig)
    ) or pg_catalog.has_function_privilege('anon', routine_oid, 'EXECUTE')
      or pg_catalog.has_function_privilege('service_role', routine_oid, 'EXECUTE') then
      raise exception 'Unsafe operational grant transition routine';
    end if;
  end loop;
end;
$verify$;

comment on column public.permission_definitions.grant_scope is
  'Authorization scope for operational grants. company applies to shared master data; branch applies to transactions with a branch context.';
comment on table public.company_role_permission_grants is
  'Master-only operational grants. Company-scoped rows have no branch; branch-scoped rows require one active branch. No direct table access is granted.';

commit;
