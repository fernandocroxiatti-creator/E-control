-- Master-controlled approval of the existing company access catalog.
-- This migration never approves a role, permission, transaction or grant by itself.

begin;

do $preflight$
begin
  if current_user <> 'postgres' then
    raise exception 'Apply this migration as postgres';
  end if;
  if pg_catalog.to_regclass('public.access_role_definitions') is null
    or pg_catalog.to_regclass('public.permission_definitions') is null
    or pg_catalog.to_regclass('public.role_permission_grants') is null
    or pg_catalog.to_regclass('public.erp_transaction_authorization_catalog') is null
    or pg_catalog.to_regclass('app_private.provisioning_audit_events') is null
    or pg_catalog.to_regprocedure('app_private.assert_current_master()') is null
    or pg_catalog.to_regprocedure('app_private.write_provisioning_audit(text,uuid,uuid,uuid,jsonb)') is null
    or pg_catalog.to_regprocedure('public.is_current_user_master()') is null then
    raise exception 'Master and authorization foundations are required';
  end if;
  if pg_catalog.to_regprocedure('public.master_set_access_catalog_approval(text,text,text)') is not null
    or pg_catalog.to_regprocedure('public.master_set_role_permission_grant(text,text,text)') is not null
    or pg_catalog.to_regprocedure('public.master_list_access_control_matrix()') is not null then
    raise exception 'Master access governance objects already exist; inspect before applying';
  end if;
  if exists (
    select 1
    from pg_catalog.pg_class relation_row
    where relation_row.oid in (
      'public.access_role_definitions'::pg_catalog.regclass,
      'public.permission_definitions'::pg_catalog.regclass,
      'public.role_permission_grants'::pg_catalog.regclass,
      'public.erp_transaction_authorization_catalog'::pg_catalog.regclass
    )
      and (not relation_row.relrowsecurity or not relation_row.relforcerowsecurity)
  ) then
    raise exception 'Authorization catalog RLS must remain enabled and forced';
  end if;
end;
$preflight$;

-- Package 01 uses this permission for stock reads. It was intentionally absent
-- from the original seed, so add it only as a pending proposal here.
insert into public.permission_definitions (permission_key, description)
values ('transaction.inventory.stock.read', 'Consultar saldos e movimentos de estoque nas filiais autorizadas.')
on conflict (permission_key) do nothing;

create function public.master_set_access_catalog_approval(
  p_item_type text,
  p_item_key text,
  p_approval_state text
)
returns text
language plpgsql volatile security definer
set search_path = '' set row_security = off
as $function$
declare
  actor_id uuid;
  prior_state text;
begin
  actor_id := app_private.assert_current_master();
  if p_item_type not in ('role', 'permission', 'transaction')
    or p_item_key is null or pg_catalog.length(pg_catalog.btrim(p_item_key)) = 0
    or p_approval_state not in ('pending_approval', 'approved', 'retired') then
    raise exception 'Invalid catalog approval request' using errcode = '22023';
  end if;

  if p_item_type = 'role' then
    select approval_state into prior_state
    from public.access_role_definitions
    where role_key = p_item_key
    for update;
    if not found then raise exception 'Role not found' using errcode = 'P0002'; end if;
    update public.access_role_definitions set approval_state = p_approval_state
    where role_key = p_item_key and approval_state is distinct from p_approval_state;
  elsif p_item_type = 'permission' then
    select approval_state into prior_state
    from public.permission_definitions
    where permission_key = p_item_key
    for update;
    if not found then raise exception 'Permission not found' using errcode = 'P0002'; end if;
    update public.permission_definitions set approval_state = p_approval_state
    where permission_key = p_item_key and approval_state is distinct from p_approval_state;
  else
    select approval_state into prior_state
    from public.erp_transaction_authorization_catalog
    where transaction_code = p_item_key
    for update;
    if not found then raise exception 'Transaction not found' using errcode = 'P0002'; end if;
    update public.erp_transaction_authorization_catalog set approval_state = p_approval_state
    where transaction_code = p_item_key and approval_state is distinct from p_approval_state;
  end if;

  perform app_private.write_provisioning_audit(
    'master_access_catalog.approval_changed', null, null, actor_id,
    pg_catalog.jsonb_build_object(
      'item_type', p_item_type,
      'item_key', p_item_key,
      'old_approval_state', prior_state,
      'new_approval_state', p_approval_state
    )
  );
  return p_approval_state;
end;
$function$;

create function public.master_set_role_permission_grant(
  p_role_key text,
  p_permission_key text,
  p_operation text
)
returns text
language plpgsql volatile security definer
set search_path = '' set row_security = off
as $function$
declare
  actor_id uuid;
  role_state text;
  permission_state text;
  changed_count integer;
begin
  actor_id := app_private.assert_current_master();
  if p_role_key is null or p_permission_key is null
    or p_operation not in ('grant', 'revoke') then
    raise exception 'Invalid role permission request' using errcode = '22023';
  end if;

  select approval_state into role_state
  from public.access_role_definitions where role_key = p_role_key for update;
  if not found then raise exception 'Role not found' using errcode = 'P0002'; end if;
  select approval_state into permission_state
  from public.permission_definitions where permission_key = p_permission_key for update;
  if not found then raise exception 'Permission not found' using errcode = 'P0002'; end if;

  if p_operation = 'grant' then
    if role_state <> 'approved' or permission_state <> 'approved' then
      raise exception 'Approved role and permission are required before granting' using errcode = '55000';
    end if;
    perform pg_catalog.pg_advisory_xact_lock(pg_catalog.hashtextextended(
      'master-role-permission:' || p_role_key || ':' || p_permission_key, 0
    ));
    insert into public.role_permission_grants (role_key, permission_key)
    values (p_role_key, p_permission_key)
    on conflict (role_key, permission_key) do nothing;
    get diagnostics changed_count = row_count;
  else
    perform pg_catalog.pg_advisory_xact_lock(pg_catalog.hashtextextended(
      'master-role-permission:' || p_role_key || ':' || p_permission_key, 0
    ));
    delete from public.role_permission_grants
    where role_key = p_role_key and permission_key = p_permission_key;
    get diagnostics changed_count = row_count;
  end if;

  perform app_private.write_provisioning_audit(
    'master_role_permission.' || p_operation, null, null, actor_id,
    pg_catalog.jsonb_build_object(
      'role_key', p_role_key,
      'permission_key', p_permission_key,
      'changed', changed_count = 1
    )
  );
  return case when changed_count = 1 then p_operation else 'unchanged' end;
end;
$function$;

create function public.master_list_access_control_matrix()
returns table (
  entry_type text,
  role_key text,
  permission_key text,
  transaction_code text,
  display_name text,
  scope text,
  approval_state text
)
language plpgsql stable security definer
set search_path = '' set row_security = off
as $function$
begin
  perform app_private.assert_current_master();
  return query
    select 'role'::text, role_row.role_key, null::text, null::text,
      role_row.display_name, role_row.scope, role_row.approval_state
    from public.access_role_definitions role_row
    union all
    select 'permission'::text, null::text, permission_row.permission_key, null::text,
      permission_row.description, null::text, permission_row.approval_state
    from public.permission_definitions permission_row
    union all
    select 'transaction'::text, null::text, catalog.permission_key, catalog.transaction_code,
      catalog.module_code, null::text, catalog.approval_state
    from public.erp_transaction_authorization_catalog catalog
    union all
    select 'role_permission'::text, grant_row.role_key, grant_row.permission_key, null::text,
      permission_row.description, role_row.scope,
      role_row.approval_state || ' / ' || permission_row.approval_state
    from public.role_permission_grants grant_row
    join public.access_role_definitions role_row on role_row.role_key = grant_row.role_key
    join public.permission_definitions permission_row on permission_row.permission_key = grant_row.permission_key
    order by 1, 2 nulls last, 3 nulls last, 4 nulls last;
end;
$function$;

alter function public.master_set_access_catalog_approval(text,text,text) owner to postgres;
alter function public.master_set_role_permission_grant(text,text,text) owner to postgres;
alter function public.master_list_access_control_matrix() owner to postgres;

revoke all on function public.master_set_access_catalog_approval(text,text,text),
  public.master_set_role_permission_grant(text,text,text),
  public.master_list_access_control_matrix()
  from public, anon, authenticated, service_role;
grant execute on function public.master_set_access_catalog_approval(text,text,text),
  public.master_set_role_permission_grant(text,text,text),
  public.master_list_access_control_matrix()
  to authenticated;

do $verify$
declare
  routine text;
  routine_oid oid;
  owner_oid oid;
  authenticated_oid oid;
begin
  select oid into owner_oid from pg_catalog.pg_roles where rolname = 'postgres';
  select oid into authenticated_oid from pg_catalog.pg_roles where rolname = 'authenticated';
  if owner_oid is null or authenticated_oid is null then
    raise exception 'Required database roles are missing';
  end if;
  foreach routine in array array[
    'public.master_set_access_catalog_approval(text,text,text)',
    'public.master_set_role_permission_grant(text,text,text)',
    'public.master_list_access_control_matrix()'
  ] loop
    routine_oid := pg_catalog.to_regprocedure(routine);
    if routine_oid is null or not exists (
      select 1 from pg_catalog.pg_proc procedure_row
      where procedure_row.oid = routine_oid and procedure_row.proowner = owner_oid
        and procedure_row.prosecdef and 'search_path=""' = any(procedure_row.proconfig)
        and 'row_security=off' = any(procedure_row.proconfig)
    ) then
      raise exception 'Unsafe Master access governance routine: %', routine;
    end if;
    if not pg_catalog.has_function_privilege('authenticated', routine_oid, 'EXECUTE')
      or pg_catalog.has_function_privilege('anon', routine_oid, 'EXECUTE')
      or pg_catalog.has_function_privilege('service_role', routine_oid, 'EXECUTE') then
      raise exception 'Unsafe Master access governance ACL: %', routine;
    end if;
  end loop;
  if exists (
    select 1 from public.access_role_definitions where role_key = 'company_owner'
      and approval_state <> 'pending_approval'
  ) or exists (
    select 1 from public.permission_definitions where permission_key = 'transaction.inventory.stock.read'
      and approval_state <> 'pending_approval'
  ) or exists (
    select 1 from public.role_permission_grants grant_row
    join public.access_role_definitions role_row on role_row.role_key = grant_row.role_key
    where role_row.role_key in ('company_owner','company_manager','branch_supervisor','branch_operator')
  ) then
    raise exception 'Migration must not approve or grant operational access automatically';
  end if;
end;
$verify$;

comment on function public.master_set_access_catalog_approval(text,text,text) is
  'Master-only audited state transition for existing role, permission and transaction catalog items.';
comment on function public.master_set_role_permission_grant(text,text,text) is
  'Master-only audited grant or revocation; grants require a separately approved role and permission.';
comment on function public.master_list_access_control_matrix() is
  'Master-only read projection of roles, permissions, transactions and effective role grants.';

commit;
