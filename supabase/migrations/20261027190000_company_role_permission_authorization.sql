-- Company role and transaction authorization foundation.
-- All proposed roles/permissions remain pending and no role-permission grants
-- are inserted. This migration does not enable company_owner or any ERP action.

begin;

do $preflight$
begin
  if current_user <> 'postgres' then
    raise exception 'Apply this migration as postgres';
  end if;
  if pg_catalog.to_regclass('public.companies') is null
    or pg_catalog.to_regclass('public.branches') is null
    or pg_catalog.to_regclass('public.company_memberships') is null
    or pg_catalog.to_regclass('public.branch_access') is null
    or pg_catalog.to_regclass('public.access_role_definitions') is null
    or pg_catalog.to_regclass('public.permission_definitions') is null
    or pg_catalog.to_regclass('public.role_permission_grants') is null
    or pg_catalog.to_regclass('public.membership_role_assignments') is null
    or pg_catalog.to_regclass('app_private.provisioning_audit_events') is null
    or pg_catalog.to_regprocedure('app_private.has_tenant_permission(uuid,text,uuid)') is null
    or pg_catalog.to_regprocedure('app_private.can_access_branch(uuid,uuid)') is null
    or pg_catalog.to_regprocedure('public.is_current_user_master()') is null then
    raise exception 'Tenant authorization foundation is required';
  end if;
  if pg_catalog.to_regclass('public.erp_transaction_authorization_catalog') is not null
    or pg_catalog.to_regprocedure('public.authorize_company_transaction(uuid,uuid,text)') is not null
    or pg_catalog.to_regprocedure('public.assign_company_membership_role(uuid,uuid,text,uuid)') is not null
    or pg_catalog.to_regprocedure('public.revoke_company_membership_role(uuid,uuid,text,uuid)') is not null
    or pg_catalog.to_regprocedure('public.set_company_member_branch_access(uuid,uuid,uuid,text)') is not null then
    raise exception 'Company role authorization objects already exist; inspect before applying';
  end if;
  if exists (
    select 1 from (values
      ('public.companies'::pg_catalog.regclass),
      ('public.branches'::pg_catalog.regclass),
      ('public.company_memberships'::pg_catalog.regclass),
      ('public.branch_access'::pg_catalog.regclass),
      ('public.access_role_definitions'::pg_catalog.regclass),
      ('public.permission_definitions'::pg_catalog.regclass),
      ('public.role_permission_grants'::pg_catalog.regclass),
      ('public.membership_role_assignments'::pg_catalog.regclass)
    ) as protected(relation_oid)
    join pg_catalog.pg_class as relation_row on relation_row.oid = protected.relation_oid
    where not relation_row.relrowsecurity or not relation_row.relforcerowsecurity
  ) then
    raise exception 'All tenant authorization tables must retain enabled and forced RLS';
  end if;
  if pg_catalog.has_table_privilege('authenticated', 'public.membership_role_assignments', 'INSERT')
    or pg_catalog.has_table_privilege('authenticated', 'public.membership_role_assignments', 'UPDATE')
    or pg_catalog.has_table_privilege('authenticated', 'public.membership_role_assignments', 'DELETE')
    or pg_catalog.has_table_privilege('authenticated', 'public.role_permission_grants', 'INSERT')
    or pg_catalog.has_table_privilege('authenticated', 'public.role_permission_grants', 'UPDATE')
    or pg_catalog.has_table_privilege('authenticated', 'public.role_permission_grants', 'DELETE') then
    raise exception 'Authenticated users must not write role assignments or role grants directly';
  end if;
end;
$preflight$;

-- Seed proposals only. Existing role states are never promoted by this migration.
insert into public.access_role_definitions (role_key, display_name, scope)
values
  ('company_manager', 'Gerente empresarial (proposta)', 'company'),
  ('branch_supervisor', 'Supervisor de filial (proposta)', 'branch'),
  ('branch_operator', 'Operador de filial (proposta)', 'branch')
on conflict (role_key) do nothing;

insert into public.permission_definitions (permission_key, description)
values
  ('company.profile.read', 'Consultar dados cadastrais da própria empresa.'),
  ('company.profile.manage', 'Alterar dados cadastrais da própria empresa.'),
  ('membership.invite', 'Convidar usuários para a própria empresa.'),
  ('membership.manage', 'Ativar, suspender ou revogar vínculos da própria empresa.'),
  ('membership.role.assign', 'Atribuir somente papéis aprovados dentro da autoridade efetiva do ator.'),
  ('transaction.purchasing.purchase_order.create', 'Transação ME21N: criar pedido de compra.'),
  ('transaction.purchasing.purchase_order.approve', 'Aprovar pedidos de compra conforme alçada empresarial.'),
  ('transaction.inventory.stock.read', 'Consultar saldos de estoque nas filiais autorizadas.'),
  ('transaction.inventory.stock.adjust', 'Ajustar estoque nas filiais autorizadas.'),
  ('transaction.sales.order.create', 'Criar pedidos de venda nas filiais autorizadas.'),
  ('transaction.sales.order.approve', 'Aprovar pedidos de venda conforme alçada empresarial.'),
  ('transaction.finance.receivable.read', 'Consultar contas a receber da própria empresa.'),
  ('transaction.finance.payable.read', 'Consultar contas a pagar da própria empresa.'),
  ('transaction.finance.payment.execute', 'Executar pagamentos conforme alçada empresarial.'),
  ('transaction.reports.financial.read', 'Consultar relatórios financeiros da própria empresa.')
on conflict (permission_key) do nothing;

create table public.erp_transaction_authorization_catalog (
  transaction_code text primary key check (transaction_code ~ '^[A-Z][A-Z0-9]{1,19}$'),
  module_code text not null check (module_code ~ '^[A-Z][A-Z0-9]{1,9}$'),
  permission_key text not null unique references public.permission_definitions(permission_key) on delete restrict,
  approval_state text not null default 'pending_approval'
    check (approval_state in ('pending_approval', 'approved', 'retired')),
  created_at timestamptz not null default pg_catalog.now()
);
alter table public.erp_transaction_authorization_catalog owner to postgres;
alter table public.erp_transaction_authorization_catalog enable row level security;
alter table public.erp_transaction_authorization_catalog force row level security;
revoke all on table public.erp_transaction_authorization_catalog from public, anon, authenticated, service_role;

insert into public.erp_transaction_authorization_catalog
  (transaction_code, module_code, permission_key)
values ('ME21N', 'PUR', 'transaction.purchasing.purchase_order.create');

create function public.authorize_company_transaction(
  p_tenant_id uuid,
  p_branch_id uuid,
  p_transaction_code text
)
returns boolean
language plpgsql stable security definer
set search_path = '' set row_security = off
as $function$
declare
  required_permission text;
begin
  if coalesce(auth.role(), '') <> 'authenticated' or auth.uid() is null
    or p_tenant_id is null or p_branch_id is null
    or p_transaction_code is null
    or p_transaction_code !~ '^[A-Z][A-Z0-9]{1,19}$' then
    return false;
  end if;
  select catalog.permission_key into required_permission
  from public.erp_transaction_authorization_catalog as catalog
  join public.permission_definitions as permission
    on permission.permission_key = catalog.permission_key
   and permission.approval_state = 'approved'
  where catalog.transaction_code = p_transaction_code
    and catalog.approval_state = 'approved';
  if required_permission is null then return false; end if;
  return app_private.has_tenant_permission(p_tenant_id, required_permission, p_branch_id)
    and app_private.can_access_branch(p_tenant_id, p_branch_id);
end;
$function$;

create function public.assign_company_membership_role(
  p_tenant_id uuid,
  p_membership_id uuid,
  p_role_key text,
  p_branch_id uuid default null
)
returns text
language plpgsql volatile security definer
set search_path = '' set row_security = off
as $function$
declare
  actor_id uuid;
  actor_membership_id uuid;
  target_user_id uuid;
  requested_scope text;
begin
  if coalesce(auth.role(), '') <> 'authenticated' or auth.uid() is null then
    raise exception 'Authenticated session required' using errcode = '42501';
  end if;
  actor_id := auth.uid();
  if p_tenant_id is null or p_membership_id is null or p_role_key is null then
    raise exception 'Tenant, membership and role are required' using errcode = '22023';
  end if;
  perform pg_catalog.pg_advisory_xact_lock(pg_catalog.hashtextextended(
    'company-authz:' || p_tenant_id::text, 0
  ));
  perform 1 from public.companies as company
  where company.id = p_tenant_id and company.status = 'active' for share;
  if not found then raise exception 'Active company not found' using errcode = 'P0002'; end if;
  select membership.id into actor_membership_id
  from public.company_memberships as membership
  where membership.tenant_id = p_tenant_id and membership.user_id = actor_id
    and membership.status = 'active' for share;
  if not found then raise exception 'Active company membership required' using errcode = '42501'; end if;
  select membership.user_id into target_user_id
  from public.company_memberships as membership
  where membership.tenant_id = p_tenant_id and membership.id = p_membership_id
    and membership.status = 'active' for update;
  if not found then raise exception 'Active target membership not found' using errcode = 'P0002'; end if;
  if target_user_id = actor_id then
    raise exception 'Users cannot change their own role assignment' using errcode = '42501';
  end if;
  select role_definition.scope into requested_scope
  from public.access_role_definitions as role_definition
  where role_definition.role_key = p_role_key and role_definition.approval_state = 'approved'
  for share;
  if not found then raise exception 'Approved role required' using errcode = '55000'; end if;
  if (requested_scope = 'company' and p_branch_id is not null)
    or (requested_scope = 'branch' and p_branch_id is null) then
    raise exception 'Role scope and branch scope do not match' using errcode = '22023';
  end if;
  if p_role_key = 'company_owner' then
    raise exception 'The first company_owner may only be established through the one-time Master invitation flow'
      using errcode = '42501';
  end if;
  if p_branch_id is not null and not exists (
    select 1 from public.branches as branch
    where branch.tenant_id = p_tenant_id and branch.id = p_branch_id and branch.status = 'active'
  ) then raise exception 'Active branch in this company required' using errcode = '23503'; end if;
  if not app_private.has_tenant_permission(p_tenant_id, 'membership.role.assign', p_branch_id) then
    raise exception 'Role assignment permission required in this scope' using errcode = '42501';
  end if;
  if exists (
    select 1
    from public.role_permission_grants as role_grant
    join public.permission_definitions as permission
      on permission.permission_key = role_grant.permission_key
     and permission.approval_state = 'approved'
    where role_grant.role_key = p_role_key
      and not app_private.has_tenant_permission(p_tenant_id, role_grant.permission_key, p_branch_id)
  ) then
    raise exception 'Actor cannot delegate permissions they do not effectively hold' using errcode = '42501';
  end if;
  insert into public.membership_role_assignments
    (tenant_id, membership_id, role_key, branch_id, assigned_by_user_id)
  values (p_tenant_id, p_membership_id, p_role_key, p_branch_id, actor_id);
  return 'assigned';
end;
$function$;

create function public.revoke_company_membership_role(
  p_tenant_id uuid,
  p_membership_id uuid,
  p_role_key text,
  p_branch_id uuid default null
)
returns text
language plpgsql volatile security definer
set search_path = '' set row_security = off
as $function$
declare
  actor_id uuid;
  target_user_id uuid;
begin
  if coalesce(auth.role(), '') <> 'authenticated' or auth.uid() is null then
    raise exception 'Authenticated session required' using errcode = '42501';
  end if;
  actor_id := auth.uid();
  if p_tenant_id is null or p_membership_id is null or p_role_key is null then
    raise exception 'Tenant, membership and role are required' using errcode = '22023';
  end if;
  perform pg_catalog.pg_advisory_xact_lock(pg_catalog.hashtextextended(
    'company-authz:' || p_tenant_id::text, 0
  ));
  perform 1 from public.companies as company
  where company.id = p_tenant_id and company.status = 'active' for share;
  if not found then raise exception 'Active company not found' using errcode = 'P0002'; end if;
  perform 1 from public.company_memberships as actor_membership
  where actor_membership.tenant_id = p_tenant_id and actor_membership.user_id = actor_id
    and actor_membership.status = 'active' for share;
  if not found then raise exception 'Active company membership required' using errcode = '42501'; end if;
  select membership.user_id into target_user_id
  from public.company_memberships as membership
  join public.companies as company on company.id = membership.tenant_id and company.status = 'active'
  where membership.tenant_id = p_tenant_id and membership.id = p_membership_id
    and membership.status = 'active' for update of membership;
  if not found then raise exception 'Active target membership not found' using errcode = 'P0002'; end if;
  if target_user_id = actor_id then
    raise exception 'Users cannot change their own role assignment' using errcode = '42501';
  end if;
  if not app_private.has_tenant_permission(p_tenant_id, 'membership.role.assign', p_branch_id) then
    raise exception 'Role assignment permission required in this scope' using errcode = '42501';
  end if;
  if p_branch_id is not null and not exists (
    select 1 from public.branches as branch
    where branch.tenant_id = p_tenant_id and branch.id = p_branch_id and branch.status = 'active'
  ) then raise exception 'Active branch in this company required' using errcode = '23503'; end if;
  delete from public.membership_role_assignments as assignment
  where assignment.tenant_id = p_tenant_id and assignment.membership_id = p_membership_id
    and assignment.role_key = p_role_key and assignment.branch_id is not distinct from p_branch_id;
  if not found then return 'not_assigned'; end if;
  return 'revoked';
end;
$function$;

create function public.set_company_member_branch_access(
  p_tenant_id uuid,
  p_membership_id uuid,
  p_branch_id uuid,
  p_status text
)
returns text
language plpgsql volatile security definer
set search_path = '' set row_security = off
as $function$
declare
  actor_id uuid;
  target_user_id uuid;
  existing_status text;
begin
  if coalesce(auth.role(), '') <> 'authenticated' or auth.uid() is null then
    raise exception 'Authenticated session required' using errcode = '42501';
  end if;
  actor_id := auth.uid();
  if p_tenant_id is null or p_membership_id is null or p_branch_id is null
    or p_status is null or p_status not in ('active', 'revoked') then
    raise exception 'Branch access status must be active or revoked' using errcode = '22023';
  end if;
  perform pg_catalog.pg_advisory_xact_lock(pg_catalog.hashtextextended(
    'company-authz:' || p_tenant_id::text, 0
  ));
  perform 1 from public.companies as company
  where company.id = p_tenant_id and company.status = 'active' for share;
  if not found then raise exception 'Active company not found' using errcode = 'P0002'; end if;
  perform 1 from public.company_memberships as actor_membership
  where actor_membership.tenant_id = p_tenant_id and actor_membership.user_id = actor_id
    and actor_membership.status = 'active' for share;
  if not found then raise exception 'Active company membership required' using errcode = '42501'; end if;
  select membership.user_id into target_user_id
  from public.company_memberships as membership
  where membership.tenant_id = p_tenant_id and membership.id = p_membership_id
    and membership.status = 'active' for update;
  if not found then raise exception 'Active target membership not found' using errcode = 'P0002'; end if;
  if target_user_id = actor_id then
    raise exception 'Users cannot change their own branch access' using errcode = '42501';
  end if;
  if not exists (select 1 from public.branches as branch
      where branch.tenant_id = p_tenant_id and branch.id = p_branch_id and branch.status = 'active') then
    raise exception 'Active branch in this company required' using errcode = '23503';
  end if;
  if not app_private.has_tenant_permission(p_tenant_id, 'branch_access.manage', p_branch_id) then
    raise exception 'Branch access management permission required in this scope' using errcode = '42501';
  end if;
  select access_link.status into existing_status from public.branch_access as access_link
  where access_link.tenant_id = p_tenant_id and access_link.membership_id = p_membership_id
    and access_link.branch_id = p_branch_id for update;
  if found then
    if existing_status = p_status then return 'unchanged'; end if;
    update public.branch_access set status = p_status
    where tenant_id = p_tenant_id and membership_id = p_membership_id and branch_id = p_branch_id;
    return 'updated';
  end if;
  if p_status = 'revoked' then return 'unchanged'; end if;
  insert into public.branch_access
    (tenant_id, membership_id, branch_id, status, granted_by_user_id)
  values (p_tenant_id, p_membership_id, p_branch_id, 'active', actor_id);
  return 'created';
end;
$function$;

alter function public.authorize_company_transaction(uuid,uuid,text) owner to postgres;
alter function public.assign_company_membership_role(uuid,uuid,text,uuid) owner to postgres;
alter function public.revoke_company_membership_role(uuid,uuid,text,uuid) owner to postgres;
alter function public.set_company_member_branch_access(uuid,uuid,uuid,text) owner to postgres;

revoke all on function public.authorize_company_transaction(uuid,uuid,text) from public, anon, authenticated, service_role;
revoke all on function public.assign_company_membership_role(uuid,uuid,text,uuid) from public, anon, authenticated, service_role;
revoke all on function public.revoke_company_membership_role(uuid,uuid,text,uuid) from public, anon, authenticated, service_role;
revoke all on function public.set_company_member_branch_access(uuid,uuid,uuid,text) from public, anon, authenticated, service_role;
grant execute on function public.authorize_company_transaction(uuid,uuid,text) to authenticated;
grant execute on function public.assign_company_membership_role(uuid,uuid,text,uuid) to authenticated;
grant execute on function public.revoke_company_membership_role(uuid,uuid,text,uuid) to authenticated;
grant execute on function public.set_company_member_branch_access(uuid,uuid,uuid,text) to authenticated;

do $verify$
declare
  routine text;
  routine_oid oid;
begin
  if exists (
    select 1 from public.access_role_definitions as role_definition
    where role_definition.role_key in ('company_owner','company_manager','branch_supervisor','branch_operator')
      and role_definition.approval_state <> 'pending_approval'
  ) then raise exception 'Proposed company roles must remain pending approval'; end if;
  if exists (
    select 1 from public.role_permission_grants as role_grant
    where role_grant.role_key in ('company_owner','company_manager','branch_supervisor','branch_operator')
  ) then raise exception 'Proposed company roles must not receive permission grants before approval'; end if;
  if pg_catalog.has_table_privilege('anon', 'public.erp_transaction_authorization_catalog', 'SELECT')
    or pg_catalog.has_table_privilege('authenticated', 'public.erp_transaction_authorization_catalog', 'SELECT')
    or pg_catalog.has_table_privilege('service_role', 'public.erp_transaction_authorization_catalog', 'SELECT') then
    raise exception 'Transaction authorization catalog must not be directly readable by API roles';
  end if;
  foreach routine in array array[
    'public.authorize_company_transaction(uuid,uuid,text)',
    'public.assign_company_membership_role(uuid,uuid,text,uuid)',
    'public.revoke_company_membership_role(uuid,uuid,text,uuid)',
    'public.set_company_member_branch_access(uuid,uuid,uuid,text)'
  ] loop
    routine_oid := pg_catalog.to_regprocedure(routine);
    if routine_oid is null or not exists (
      select 1 from pg_catalog.pg_proc as procedure_row
      join pg_catalog.pg_roles as owner_row on owner_row.oid = procedure_row.proowner
      where procedure_row.oid = routine_oid and owner_row.rolname = 'postgres'
        and procedure_row.prosecdef
        and 'search_path=""' = any(procedure_row.proconfig)
        and 'row_security=off' = any(procedure_row.proconfig)
    ) then raise exception 'Authorization routine has an unsafe definition: %', routine; end if;
    if not pg_catalog.has_function_privilege('authenticated', routine_oid, 'EXECUTE')
      or pg_catalog.has_function_privilege('anon', routine_oid, 'EXECUTE')
      or pg_catalog.has_function_privilege('service_role', routine_oid, 'EXECUTE')
      or exists (
        select 1
        from pg_catalog.pg_proc as procedure_row
        cross join lateral pg_catalog.aclexplode(
          coalesce(procedure_row.proacl, pg_catalog.acldefault('f', procedure_row.proowner))
        ) as function_acl
        where procedure_row.oid = routine_oid
          and function_acl.grantee = 0
          and function_acl.privilege_type = 'EXECUTE'
      ) then
      raise exception 'Authorization routine ACL is unsafe: %', routine;
    end if;
  end loop;
end;
$verify$;

comment on function public.authorize_company_transaction(uuid,uuid,text) is
  'Returns true only for auth.uid() with an approved transaction mapping, approved permission, active tenant membership and authorized branch; denies unknown transactions.';
comment on function public.assign_company_membership_role(uuid,uuid,text,uuid) is
  'Assigns an approved company role only when the authenticated actor has role-assignment authority and every target permission is within the actor effective permission set.';
comment on function public.revoke_company_membership_role(uuid,uuid,text,uuid) is
  'Revokes a role in the actor tenant and branch scope; self-role changes are denied and changes are audited by the assignment trigger.';
comment on function public.set_company_member_branch_access(uuid,uuid,uuid,text) is
  'Changes branch access only for an active branch in the actor tenant and with an approved branch_access.manage permission; changes are audited.';

commit;
