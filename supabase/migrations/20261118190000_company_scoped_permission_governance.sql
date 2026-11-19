-- Company-scoped operational grants with mandatory, auditable Master reasons.
-- This migration creates no approval, availability, membership or grant.
begin;

do $preflight$
begin
  if current_user <> 'postgres'
    or pg_catalog.to_regclass('public.companies') is null
    or pg_catalog.to_regclass('public.branches') is null
    or pg_catalog.to_regclass('public.company_memberships') is null
    or pg_catalog.to_regclass('public.membership_role_assignments') is null
    or pg_catalog.to_regclass('public.access_role_definitions') is null
    or pg_catalog.to_regclass('public.permission_definitions') is null
    or pg_catalog.to_regclass('public.role_permission_grants') is null
    or pg_catalog.to_regclass('public.company_transaction_availability') is null
    or pg_catalog.to_regclass('public.erp_transaction_authorization_catalog') is null
    or pg_catalog.to_regprocedure('app_private.assert_current_master()') is null
    or pg_catalog.to_regprocedure('app_private.can_access_branch(uuid,uuid)') is null
    or pg_catalog.to_regprocedure('app_private.write_provisioning_audit(text,uuid,uuid,uuid,jsonb)') is null then
    raise exception 'Company-scoped governance prerequisites are missing';
  end if;

  if not exists (
    select 1
    from pg_catalog.pg_class relation_row
    where relation_row.oid in (
      'public.access_role_definitions'::pg_catalog.regclass,
      'public.permission_definitions'::pg_catalog.regclass,
      'public.role_permission_grants'::pg_catalog.regclass,
      'public.company_transaction_availability'::pg_catalog.regclass
    )
      and relation_row.relrowsecurity
      and relation_row.relforcerowsecurity
  ) then
    raise exception 'Existing authorization relations must keep RLS and FORCE RLS';
  end if;
end;
$preflight$;

create table public.company_role_permission_grants (
  tenant_id uuid not null references public.companies(id) on delete restrict,
  branch_id uuid not null,
  role_key text not null references public.access_role_definitions(role_key) on delete restrict,
  permission_key text not null references public.permission_definitions(permission_key) on delete restrict,
  reason text not null check (pg_catalog.length(pg_catalog.btrim(reason)) between 10 and 1000),
  created_by_user_id uuid not null references auth.users(id) on delete restrict,
  created_at timestamptz not null default pg_catalog.clock_timestamp(),
  primary key (tenant_id, branch_id, role_key, permission_key),
  foreign key (tenant_id, branch_id) references public.branches(tenant_id, id) on delete restrict
);

alter table public.company_role_permission_grants owner to postgres;
alter table public.company_role_permission_grants enable row level security;
alter table public.company_role_permission_grants force row level security;
revoke all on table public.company_role_permission_grants from public, anon, authenticated, service_role;

-- A scoped grant is deliberately additive. It can only satisfy a branch-bound
-- authorization; all existing global grants retain their previous semantics.
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
        exists (
          select 1
          from public.role_permission_grants as global_grant
          where global_grant.role_key = role_definition.role_key
            and global_grant.permission_key = p_permission_key
        )
        or (
          p_branch_id is not null
          and exists (
            select 1
            from public.company_role_permission_grants as scoped_grant
            where scoped_grant.tenant_id = p_tenant_id
              and scoped_grant.branch_id = p_branch_id
              and scoped_grant.role_key = role_definition.role_key
              and scoped_grant.permission_key = p_permission_key
          )
        )
      )
      and (p_branch_id is null or app_private.can_access_branch(p_tenant_id, p_branch_id))
  );
$function$;

drop function public.master_set_access_catalog_approval(text, text, text);
create function public.master_set_access_catalog_approval(
  p_item_type text,
  p_item_key text,
  p_approval_state text,
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
  prior_state text;
  normalized_reason text := pg_catalog.btrim(coalesce(p_reason, ''));
begin
  actor_id := app_private.assert_current_master();
  if p_item_type not in ('role', 'permission', 'transaction')
    or p_item_key is null or pg_catalog.length(pg_catalog.btrim(p_item_key)) = 0
    or p_approval_state not in ('pending_approval', 'approved', 'retired')
    or pg_catalog.length(normalized_reason) not between 10 and 1000 then
    raise exception 'A justification between 10 and 1000 characters is required' using errcode = '22023';
  end if;

  if p_item_type = 'role' then
    select approval_state into prior_state from public.access_role_definitions
      where role_key = p_item_key for update;
    if not found then raise exception 'Role not found' using errcode = 'P0002'; end if;
    update public.access_role_definitions set approval_state = p_approval_state
      where role_key = p_item_key and approval_state is distinct from p_approval_state;
  elsif p_item_type = 'permission' then
    select approval_state into prior_state from public.permission_definitions
      where permission_key = p_item_key for update;
    if not found then raise exception 'Permission not found' using errcode = 'P0002'; end if;
    update public.permission_definitions set approval_state = p_approval_state
      where permission_key = p_item_key and approval_state is distinct from p_approval_state;
  else
    select approval_state into prior_state from public.erp_transaction_authorization_catalog
      where transaction_code = p_item_key for update;
    if not found then raise exception 'Transaction not found' using errcode = 'P0002'; end if;
    update public.erp_transaction_authorization_catalog set approval_state = p_approval_state
      where transaction_code = p_item_key and approval_state is distinct from p_approval_state;
  end if;

  perform app_private.write_provisioning_audit(
    'master_access_catalog.approval_changed', null, null, actor_id,
    pg_catalog.jsonb_build_object(
      'item_type', p_item_type, 'item_key', p_item_key,
      'old_approval_state', prior_state, 'new_approval_state', p_approval_state,
      'reason', normalized_reason
    )
  );
  return p_approval_state;
end;
$function$;

drop function public.master_set_role_permission_grant(text, text, text);
create function public.master_set_role_permission_grant(
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
  changed_count integer;
  normalized_reason text := pg_catalog.btrim(coalesce(p_reason, ''));
begin
  actor_id := app_private.assert_current_master();
  if p_role_key is null or p_permission_key is null or p_operation not in ('grant', 'revoke')
    or pg_catalog.length(normalized_reason) not between 10 and 1000 then
    raise exception 'A justification between 10 and 1000 characters is required' using errcode = '22023';
  end if;

  perform pg_catalog.pg_advisory_xact_lock(pg_catalog.hashtextextended(
    'master-role-permission:' || p_role_key || ':' || p_permission_key, 0
  ));
  select approval_state into role_state from public.access_role_definitions
    where role_key = p_role_key for update;
  if not found then raise exception 'Role not found' using errcode = 'P0002'; end if;
  select approval_state into permission_state from public.permission_definitions
    where permission_key = p_permission_key for update;
  if not found then raise exception 'Permission not found' using errcode = 'P0002'; end if;

  if p_operation = 'grant' then
    if role_state <> 'approved' or permission_state <> 'approved' then
      raise exception 'Approved role and permission are required before granting' using errcode = '55000';
    end if;
    insert into public.role_permission_grants(role_key, permission_key)
    values (p_role_key, p_permission_key)
    on conflict (role_key, permission_key) do nothing;
    get diagnostics changed_count = row_count;
  else
    delete from public.role_permission_grants
      where role_key = p_role_key and permission_key = p_permission_key;
    get diagnostics changed_count = row_count;
  end if;

  perform app_private.write_provisioning_audit(
    'master_role_permission.' || p_operation, null, null, actor_id,
    pg_catalog.jsonb_build_object(
      'role_key', p_role_key, 'permission_key', p_permission_key,
      'changed', changed_count = 1, 'reason', normalized_reason
    )
  );
  return case when changed_count = 1 then p_operation else 'unchanged' end;
end;
$function$;

drop function public.master_set_company_transaction_availability(uuid, text[]);
create function public.master_set_company_transaction_availability(
  p_tenant_id uuid,
  p_enabled_transaction_codes text[],
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
  normalized_codes text[];
  normalized_reason text := pg_catalog.btrim(coalesce(p_reason, ''));
begin
  actor_id := app_private.assert_current_master();
  if p_tenant_id is null or pg_catalog.length(normalized_reason) not between 10 and 1000 then
    raise exception 'A company and a justification between 10 and 1000 characters are required' using errcode = '22023';
  end if;

  perform pg_catalog.pg_advisory_xact_lock(pg_catalog.hashtextextended('company-access:' || p_tenant_id::text, 0));
  perform 1 from public.companies where id = p_tenant_id and status = 'active' for update;
  if not found then raise exception 'Active company not found' using errcode = 'P0002'; end if;

  select coalesce(array_agg(distinct code order by code), array[]::text[]) into normalized_codes
  from unnest(coalesce(p_enabled_transaction_codes, array[]::text[])) code
  where code ~ '^[A-Z][A-Z0-9]{1,19}$';
  if cardinality(normalized_codes) <> cardinality(coalesce(p_enabled_transaction_codes, array[]::text[]))
    or exists (
      select 1 from unnest(normalized_codes) code
      left join public.erp_transaction_authorization_catalog catalog
        on catalog.transaction_code = code and catalog.approval_state = 'approved'
      where catalog.transaction_code is null
    ) then
    raise exception 'Only globally approved catalog transactions may be enabled' using errcode = '22023';
  end if;

  insert into public.company_module_availability(tenant_id, module_code, enabled, changed_by_user_id)
  select p_tenant_id, catalog.module_code, true, actor_id
  from public.erp_transaction_authorization_catalog catalog
  where catalog.transaction_code = any(normalized_codes)
  group by catalog.module_code
  on conflict (tenant_id, module_code) do update set
    enabled = excluded.enabled, changed_by_user_id = excluded.changed_by_user_id, changed_at = clock_timestamp();
  update public.company_module_availability module_availability set
    enabled = false, changed_by_user_id = actor_id, changed_at = clock_timestamp()
  where module_availability.tenant_id = p_tenant_id
    and not exists (
      select 1 from public.erp_transaction_authorization_catalog catalog
      where catalog.transaction_code = any(normalized_codes)
        and catalog.module_code = module_availability.module_code
    );
  insert into public.company_transaction_availability(tenant_id, transaction_code, enabled, changed_by_user_id)
  select p_tenant_id, catalog.transaction_code, true, actor_id
  from public.erp_transaction_authorization_catalog catalog
  where catalog.transaction_code = any(normalized_codes)
  on conflict (tenant_id, transaction_code) do update set
    enabled = excluded.enabled, changed_by_user_id = excluded.changed_by_user_id, changed_at = clock_timestamp();
  update public.company_transaction_availability transaction_availability set
    enabled = false, changed_by_user_id = actor_id, changed_at = clock_timestamp()
  where transaction_availability.tenant_id = p_tenant_id
    and not (transaction_availability.transaction_code = any(normalized_codes));

  perform app_private.write_provisioning_audit(
    'master_company_access.changed', p_tenant_id, null, actor_id,
    pg_catalog.jsonb_build_object('enabled_transaction_codes', normalized_codes, 'reason', normalized_reason)
  );
  return 'updated';
end;
$function$;

create function public.master_set_company_role_permission_grant(
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
  changed_count integer;
  normalized_reason text := pg_catalog.btrim(coalesce(p_reason, ''));
begin
  actor_id := app_private.assert_current_master();
  if p_tenant_id is null or p_branch_id is null or p_role_key is null or p_permission_key is null
    or p_operation not in ('grant', 'revoke')
    or pg_catalog.length(normalized_reason) not between 10 and 1000 then
    raise exception 'A company, branch and justification between 10 and 1000 characters are required' using errcode = '22023';
  end if;
  if p_role_key <> 'company_owner'
    or p_permission_key <> 'transaction.purchasing.receipt.manage' then
    raise exception 'This Phase 1 scoped grant is limited to company_owner and the ZGR01 receipt permission' using errcode = '22023';
  end if;

  perform pg_catalog.pg_advisory_xact_lock(pg_catalog.hashtextextended(
    'company-scoped-role-permission:' || p_tenant_id::text || ':' || p_branch_id::text || ':' || p_role_key || ':' || p_permission_key, 0
  ));
  perform 1 from public.companies where id = p_tenant_id and status = 'active' for update;
  if not found then raise exception 'Active company not found' using errcode = 'P0002'; end if;
  perform 1 from public.branches
    where tenant_id = p_tenant_id and id = p_branch_id and status = 'active' for update;
  if not found then raise exception 'Active branch not found for company' using errcode = 'P0002'; end if;
  select approval_state into role_state from public.access_role_definitions
    where role_key = p_role_key for update;
  if not found then raise exception 'Role not found' using errcode = 'P0002'; end if;
  select approval_state into permission_state from public.permission_definitions
    where permission_key = p_permission_key for update;
  if not found then raise exception 'Permission not found' using errcode = 'P0002'; end if;

  if p_operation = 'grant' then
    if role_state <> 'approved' or permission_state <> 'approved' then
      raise exception 'Approved role and permission are required before granting' using errcode = '55000';
    end if;
    if exists (
      select 1 from public.role_permission_grants
      where role_key = p_role_key and permission_key = p_permission_key
    ) then
      raise exception 'A global grant already exists; a company-scoped duplicate is not permitted' using errcode = '55000';
    end if;
    insert into public.company_role_permission_grants(
      tenant_id, branch_id, role_key, permission_key, reason, created_by_user_id
    ) values (
      p_tenant_id, p_branch_id, p_role_key, p_permission_key, normalized_reason, actor_id
    ) on conflict (tenant_id, branch_id, role_key, permission_key) do nothing;
    get diagnostics changed_count = row_count;
  else
    delete from public.company_role_permission_grants
      where tenant_id = p_tenant_id and branch_id = p_branch_id
        and role_key = p_role_key and permission_key = p_permission_key;
    get diagnostics changed_count = row_count;
  end if;

  perform app_private.write_provisioning_audit(
    'master_company_role_permission.' || p_operation, p_tenant_id, null, actor_id,
    pg_catalog.jsonb_build_object(
      'branch_id', p_branch_id, 'role_key', p_role_key,
      'permission_key', p_permission_key, 'changed', changed_count = 1,
      'reason', normalized_reason
    )
  );
  return case when changed_count = 1 then p_operation else 'unchanged' end;
end;
$function$;

create function public.master_list_company_scoped_permission_grants(p_tenant_id uuid)
returns table (
  branch_id uuid,
  branch_code text,
  branch_name text,
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
    select grant_row.branch_id, branch.code, branch.name, grant_row.role_key,
      grant_row.permission_key, grant_row.reason, grant_row.created_at
    from public.company_role_permission_grants grant_row
    join public.branches branch
      on branch.tenant_id = grant_row.tenant_id and branch.id = grant_row.branch_id
    where grant_row.tenant_id = p_tenant_id
    order by branch.code, grant_row.role_key, grant_row.permission_key;
end;
$function$;

alter function app_private.has_tenant_permission(uuid, text, uuid) owner to postgres;
alter function public.master_set_access_catalog_approval(text, text, text, text) owner to postgres;
alter function public.master_set_role_permission_grant(text, text, text, text) owner to postgres;
alter function public.master_set_company_transaction_availability(uuid, text[], text) owner to postgres;
alter function public.master_set_company_role_permission_grant(uuid, uuid, text, text, text, text) owner to postgres;
alter function public.master_list_company_scoped_permission_grants(uuid) owner to postgres;

revoke all on function app_private.has_tenant_permission(uuid, text, uuid) from public, anon, authenticated, service_role;
grant execute on function app_private.has_tenant_permission(uuid, text, uuid) to authenticated;
revoke all on function public.master_set_access_catalog_approval(text, text, text, text),
  public.master_set_role_permission_grant(text, text, text, text),
  public.master_set_company_transaction_availability(uuid, text[], text),
  public.master_set_company_role_permission_grant(uuid, uuid, text, text, text, text),
  public.master_list_company_scoped_permission_grants(uuid)
  from public, anon, authenticated, service_role;
grant execute on function public.master_set_access_catalog_approval(text, text, text, text),
  public.master_set_role_permission_grant(text, text, text, text),
  public.master_set_company_transaction_availability(uuid, text[], text),
  public.master_set_company_role_permission_grant(uuid, uuid, text, text, text, text),
  public.master_list_company_scoped_permission_grants(uuid)
  to authenticated;

do $verify$
declare
  routine text;
  routine_oid oid;
begin
  if exists (
    select 1 from pg_catalog.pg_class relation_row
    where relation_row.oid = 'public.company_role_permission_grants'::pg_catalog.regclass
      and (not relation_row.relrowsecurity or not relation_row.relforcerowsecurity)
  ) or pg_catalog.has_table_privilege('authenticated', 'public.company_role_permission_grants', 'SELECT, INSERT, UPDATE, DELETE')
    or pg_catalog.has_table_privilege('anon', 'public.company_role_permission_grants', 'SELECT, INSERT, UPDATE, DELETE')
    or pg_catalog.has_table_privilege('service_role', 'public.company_role_permission_grants', 'SELECT, INSERT, UPDATE, DELETE') then
    raise exception 'Company-scoped grants must remain inaccessible by direct table privileges';
  end if;

  foreach routine in array array[
    'app_private.has_tenant_permission(uuid,text,uuid)',
    'public.master_set_access_catalog_approval(text,text,text,text)',
    'public.master_set_role_permission_grant(text,text,text,text)',
    'public.master_set_company_transaction_availability(uuid,text[],text)',
    'public.master_set_company_role_permission_grant(uuid,uuid,text,text,text,text)',
    'public.master_list_company_scoped_permission_grants(uuid)'
  ] loop
    routine_oid := pg_catalog.to_regprocedure(routine);
    if routine_oid is null or not exists (
      select 1 from pg_catalog.pg_proc procedure_row
      join pg_catalog.pg_roles owner_role on owner_role.oid = procedure_row.proowner
      where procedure_row.oid = routine_oid
        and owner_role.rolname = 'postgres'
        and procedure_row.prosecdef
        and 'search_path=""' = any(procedure_row.proconfig)
        and 'row_security=off' = any(procedure_row.proconfig)
    ) or not pg_catalog.has_function_privilege('authenticated', routine_oid, 'EXECUTE')
      or pg_catalog.has_function_privilege('anon', routine_oid, 'EXECUTE')
      or pg_catalog.has_function_privilege('service_role', routine_oid, 'EXECUTE') then
      raise exception 'Unsafe scoped governance routine: %', routine;
    end if;
  end loop;

  if exists (
    select 1 from public.company_role_permission_grants
  ) or exists (
    select 1 from public.role_permission_grants
    where permission_key in ('transaction.purchasing.receipt.manage', 'transaction.inventory.valuation.initial')
  ) or exists (
    select 1 from public.company_transaction_availability
    where transaction_code in ('ZGR01', 'ZIV01') and enabled
  ) then
    raise exception 'Migration must not grant or enable Phase 1 operations automatically';
  end if;
end;
$verify$;

comment on table public.company_role_permission_grants is
  'Master-only, branch-bound additive grants. A row is ineffective without active membership, matching approved role, approved permission, branch access and company transaction availability.';
comment on function public.master_set_company_role_permission_grant(uuid, uuid, text, text, text, text) is
  'Master-only audited Phase 1 grant/revoke for company_owner and ZGR01 only, scoped to exactly one active company and branch; global grants are intentionally rejected as duplicates.';

commit;
