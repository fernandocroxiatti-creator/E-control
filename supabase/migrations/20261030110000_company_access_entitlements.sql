-- Master-controlled company availability. No company, module or transaction is enabled by this migration.
begin;

do $preflight$
begin
  if current_user <> 'postgres' then raise exception 'Apply this migration as postgres'; end if;
  if pg_catalog.to_regclass('public.companies') is null or pg_catalog.to_regclass('public.erp_transaction_authorization_catalog') is null
    or pg_catalog.to_regprocedure('app_private.assert_current_master()') is null
    or pg_catalog.to_regprocedure('app_private.write_provisioning_audit(text,uuid,uuid,uuid,jsonb)') is null
    or pg_catalog.to_regprocedure('public.authorize_company_transaction(uuid,uuid,text)') is null then
    raise exception 'Company, catalog and authorization foundations are required';
  end if;
  if pg_catalog.to_regclass('public.company_transaction_availability') is not null then raise exception 'Company availability already exists'; end if;
end;
$preflight$;

create table public.company_module_availability (
  tenant_id uuid not null references public.companies(id) on delete restrict,
  module_code text not null check (module_code ~ '^[A-Z][A-Z0-9]{1,9}$'),
  enabled boolean not null default false,
  changed_by_user_id uuid not null,
  changed_at timestamptz not null default pg_catalog.clock_timestamp(),
  primary key (tenant_id, module_code)
);
create table public.company_transaction_availability (
  tenant_id uuid not null references public.companies(id) on delete restrict,
  transaction_code text not null references public.erp_transaction_authorization_catalog(transaction_code) on delete restrict,
  enabled boolean not null default false,
  changed_by_user_id uuid not null,
  changed_at timestamptz not null default pg_catalog.clock_timestamp(),
  primary key (tenant_id, transaction_code)
);
alter table public.company_module_availability owner to postgres;
alter table public.company_transaction_availability owner to postgres;
alter table public.company_module_availability enable row level security;
alter table public.company_module_availability force row level security;
alter table public.company_transaction_availability enable row level security;
alter table public.company_transaction_availability force row level security;
revoke all on table public.company_module_availability, public.company_transaction_availability from public, anon, authenticated, service_role;

create function public.master_list_company_access(p_tenant_id uuid)
returns table(module_code text, transaction_code text, permission_key text, approval_state text, enabled boolean)
language plpgsql stable security definer set search_path = '' set row_security = off as $fn$
begin
  perform app_private.assert_current_master();
  if p_tenant_id is null or not exists (select 1 from public.companies where id=p_tenant_id) then raise exception 'Company not found' using errcode='P0002'; end if;
  return query select c.module_code,c.transaction_code,c.permission_key,c.approval_state,
    coalesce(t.enabled,false) and coalesce(m.enabled,false)
  from public.erp_transaction_authorization_catalog c
  left join public.company_module_availability m on m.tenant_id=p_tenant_id and m.module_code=c.module_code
  left join public.company_transaction_availability t on t.tenant_id=p_tenant_id and t.transaction_code=c.transaction_code
  order by c.module_code,c.transaction_code;
end;
$fn$;

create function public.master_set_company_transaction_availability(p_tenant_id uuid,p_enabled_transaction_codes text[])
returns text language plpgsql volatile security definer set search_path = '' set row_security = off as $fn$
declare actor_id uuid; normalized_codes text[]; changed_count integer;
begin
  actor_id:=app_private.assert_current_master();
  if p_tenant_id is null then raise exception 'Company is required' using errcode='22023'; end if;
  perform pg_catalog.pg_advisory_xact_lock(pg_catalog.hashtextextended('company-access:'||p_tenant_id::text,0));
  perform 1 from public.companies where id=p_tenant_id and status='active' for update;
  if not found then raise exception 'Active company not found' using errcode='P0002'; end if;
  select coalesce(array_agg(distinct code order by code),array[]::text[]) into normalized_codes
  from unnest(coalesce(p_enabled_transaction_codes,array[]::text[])) code
  where code ~ '^[A-Z][A-Z0-9]{1,19}$';
  if cardinality(normalized_codes) <> cardinality(coalesce(p_enabled_transaction_codes,array[]::text[]))
    or exists(select 1 from unnest(normalized_codes) code left join public.erp_transaction_authorization_catalog c on c.transaction_code=code and c.approval_state='approved' where c.transaction_code is null) then
    raise exception 'Only globally approved catalog transactions may be enabled' using errcode='22023';
  end if;
  insert into public.company_module_availability(tenant_id,module_code,enabled,changed_by_user_id)
    select p_tenant_id,c.module_code,true,actor_id from public.erp_transaction_authorization_catalog c where c.transaction_code=any(normalized_codes)
    on conflict(tenant_id,module_code) do update set enabled=excluded.enabled,changed_by_user_id=excluded.changed_by_user_id,changed_at=clock_timestamp();
  update public.company_module_availability m set enabled=false,changed_by_user_id=actor_id,changed_at=clock_timestamp()
   where m.tenant_id=p_tenant_id and not exists(select 1 from public.erp_transaction_authorization_catalog c where c.transaction_code=any(normalized_codes) and c.module_code=m.module_code);
  insert into public.company_transaction_availability(tenant_id,transaction_code,enabled,changed_by_user_id)
    select p_tenant_id,c.transaction_code,true,actor_id from public.erp_transaction_authorization_catalog c where c.transaction_code=any(normalized_codes)
    on conflict(tenant_id,transaction_code) do update set enabled=excluded.enabled,changed_by_user_id=excluded.changed_by_user_id,changed_at=clock_timestamp();
  update public.company_transaction_availability t set enabled=false,changed_by_user_id=actor_id,changed_at=clock_timestamp()
   where t.tenant_id=p_tenant_id and not (t.transaction_code=any(normalized_codes));
  get diagnostics changed_count=row_count;
  perform app_private.write_provisioning_audit('master_company_access.changed',p_tenant_id,null,actor_id,jsonb_build_object('enabled_transaction_codes',normalized_codes));
  return 'updated';
end;
$fn$;

create or replace function public.authorize_company_transaction(p_tenant_id uuid,p_branch_id uuid,p_transaction_code text)
returns boolean language plpgsql stable security definer set search_path = '' set row_security = off as $fn$
declare required_permission text;
begin
  if coalesce(auth.role(),'')<>'authenticated' or auth.uid() is null or p_tenant_id is null or p_branch_id is null or p_transaction_code is null or p_transaction_code !~ '^[A-Z][A-Z0-9]{1,19}$' then return false; end if;
  select c.permission_key into required_permission from public.erp_transaction_authorization_catalog c
    join public.permission_definitions p on p.permission_key=c.permission_key and p.approval_state='approved'
    join public.company_module_availability m on m.tenant_id=p_tenant_id and m.module_code=c.module_code and m.enabled
    join public.company_transaction_availability t on t.tenant_id=p_tenant_id and t.transaction_code=c.transaction_code and t.enabled
    join public.companies company on company.id=p_tenant_id and company.status='active'
   where c.transaction_code=p_transaction_code and c.approval_state='approved';
  return required_permission is not null and app_private.has_tenant_permission(p_tenant_id,required_permission,p_branch_id) and app_private.can_access_branch(p_tenant_id,p_branch_id);
end;
$fn$;

alter function public.master_list_company_access(uuid) owner to postgres;
alter function public.master_set_company_transaction_availability(uuid,text[]) owner to postgres;
alter function public.authorize_company_transaction(uuid,uuid,text) owner to postgres;
revoke all on function public.master_list_company_access(uuid),public.master_set_company_transaction_availability(uuid,text[]),public.authorize_company_transaction(uuid,uuid,text) from public,anon,authenticated,service_role;
grant execute on function public.master_list_company_access(uuid),public.master_set_company_transaction_availability(uuid,text[]),public.authorize_company_transaction(uuid,uuid,text) to authenticated;

do $verify$
declare routine text; oid_value oid;
begin
  if exists(select 1 from public.company_transaction_availability where enabled) then raise exception 'Migration must not enable company transactions'; end if;
  foreach routine in array array['public.master_list_company_access(uuid)','public.master_set_company_transaction_availability(uuid,text[])','public.authorize_company_transaction(uuid,uuid,text)'] loop
    oid_value:=pg_catalog.to_regprocedure(routine);
    if oid_value is null or not exists(select 1 from pg_catalog.pg_proc p join pg_catalog.pg_roles r on r.oid=p.proowner where p.oid=oid_value and r.rolname='postgres' and p.prosecdef and 'search_path=""'=any(p.proconfig) and 'row_security=off'=any(p.proconfig))
      or not pg_catalog.has_function_privilege('authenticated',oid_value,'EXECUTE') or pg_catalog.has_function_privilege('anon',oid_value,'EXECUTE') or pg_catalog.has_function_privilege('service_role',oid_value,'EXECUTE') then raise exception 'Unsafe company access routine: %',routine; end if;
  end loop;
end;
$verify$;
comment on function public.master_set_company_transaction_availability(uuid,text[]) is 'Master-only replacement of one company transaction availability set; does not grant roles or memberships.';
commit;
