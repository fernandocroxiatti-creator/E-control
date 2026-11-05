-- Corrects one atomic availability update when several selected transactions
-- belong to the same module. It changes no availability rows on installation.
begin;

do $preflight$
begin
  if current_user <> 'postgres'
    or to_regclass('public.company_module_availability') is null
    or to_regclass('public.company_transaction_availability') is null
    or to_regclass('public.erp_transaction_authorization_catalog') is null
    or to_regprocedure('app_private.assert_current_master()') is null
    or to_regprocedure('app_private.write_provisioning_audit(text,uuid,uuid,uuid,jsonb)') is null then
    raise exception 'Company access availability prerequisites are missing';
  end if;
end;
$preflight$;

create or replace function public.master_set_company_transaction_availability(
  p_tenant_id uuid,
  p_enabled_transaction_codes text[]
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
begin
  actor_id := app_private.assert_current_master();
  if p_tenant_id is null then
    raise exception 'Company is required' using errcode = '22023';
  end if;

  perform pg_catalog.pg_advisory_xact_lock(pg_catalog.hashtextextended('company-access:' || p_tenant_id::text, 0));
  perform 1
  from public.companies
  where id = p_tenant_id and status = 'active'
  for update;
  if not found then
    raise exception 'Active company not found' using errcode = 'P0002';
  end if;

  select coalesce(array_agg(distinct code order by code), array[]::text[])
    into normalized_codes
  from unnest(coalesce(p_enabled_transaction_codes, array[]::text[])) code
  where code ~ '^[A-Z][A-Z0-9]{1,19}$';

  if cardinality(normalized_codes) <> cardinality(coalesce(p_enabled_transaction_codes, array[]::text[]))
    or exists (
      select 1
      from unnest(normalized_codes) code
      left join public.erp_transaction_authorization_catalog catalog
        on catalog.transaction_code = code
       and catalog.approval_state = 'approved'
      where catalog.transaction_code is null
    ) then
    raise exception 'Only globally approved catalog transactions may be enabled' using errcode = '22023';
  end if;

  -- One module can contain many selected transactions. Grouping is required so
  -- ON CONFLICT never attempts to update the same (tenant_id,module_code) row twice.
  insert into public.company_module_availability(tenant_id, module_code, enabled, changed_by_user_id)
  select p_tenant_id, catalog.module_code, true, actor_id
  from public.erp_transaction_authorization_catalog catalog
  where catalog.transaction_code = any(normalized_codes)
  group by catalog.module_code
  on conflict (tenant_id, module_code) do update
    set enabled = excluded.enabled,
        changed_by_user_id = excluded.changed_by_user_id,
        changed_at = clock_timestamp();

  update public.company_module_availability module_availability
  set enabled = false,
      changed_by_user_id = actor_id,
      changed_at = clock_timestamp()
  where module_availability.tenant_id = p_tenant_id
    and not exists (
      select 1
      from public.erp_transaction_authorization_catalog catalog
      where catalog.transaction_code = any(normalized_codes)
        and catalog.module_code = module_availability.module_code
    );

  insert into public.company_transaction_availability(tenant_id, transaction_code, enabled, changed_by_user_id)
  select p_tenant_id, catalog.transaction_code, true, actor_id
  from public.erp_transaction_authorization_catalog catalog
  where catalog.transaction_code = any(normalized_codes)
  on conflict (tenant_id, transaction_code) do update
    set enabled = excluded.enabled,
        changed_by_user_id = excluded.changed_by_user_id,
        changed_at = clock_timestamp();

  update public.company_transaction_availability transaction_availability
  set enabled = false,
      changed_by_user_id = actor_id,
      changed_at = clock_timestamp()
  where transaction_availability.tenant_id = p_tenant_id
    and not (transaction_availability.transaction_code = any(normalized_codes));

  perform app_private.write_provisioning_audit(
    'master_company_access.changed',
    p_tenant_id,
    null,
    actor_id,
    jsonb_build_object('enabled_transaction_codes', normalized_codes)
  );
  return 'updated';
end;
$function$;

alter function public.master_set_company_transaction_availability(uuid, text[]) owner to postgres;
revoke all on function public.master_set_company_transaction_availability(uuid, text[]) from public, anon, authenticated, service_role;
grant execute on function public.master_set_company_transaction_availability(uuid, text[]) to authenticated;

do $verify$
declare
  routine oid := to_regprocedure('public.master_set_company_transaction_availability(uuid,text[])');
begin
  if routine is null
    or not exists (
      select 1
      from pg_catalog.pg_proc procedure_row
      join pg_catalog.pg_roles owner_role on owner_role.oid = procedure_row.proowner
      where procedure_row.oid = routine
        and owner_role.rolname = 'postgres'
        and procedure_row.prosecdef
        and 'search_path=""' = any(procedure_row.proconfig)
        and 'row_security=off' = any(procedure_row.proconfig)
    )
    or not has_function_privilege('authenticated', routine, 'EXECUTE')
    or has_function_privilege('anon', routine, 'EXECUTE')
    or has_function_privilege('service_role', routine, 'EXECUTE') then
    raise exception 'Unsafe company access availability routine';
  end if;
end;
$verify$;

comment on function public.master_set_company_transaction_availability(uuid, text[]) is
  'Master-only atomic replacement of one company availability set; duplicate source modules are consolidated without granting roles or memberships.';

commit;
