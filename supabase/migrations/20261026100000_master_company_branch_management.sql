-- Admin Master V2: company and branch metadata management.
-- Depends on migrations 20261020000000, 20261021000000,
-- 20261022100000, 20261022130000 and 20261023160000.
-- No membership, roles, permission grants or operational data are created.

begin;

do $preflight$
declare postgres_can_bypass_rls boolean;
begin
  if current_user <> 'postgres' then raise exception 'Apply this migration as postgres'; end if;
  if pg_catalog.to_regclass('public.companies') is null
    or pg_catalog.to_regclass('public.branches') is null
    or pg_catalog.to_regclass('app_private.provisioning_audit_events') is null
    or pg_catalog.to_regprocedure('app_private.write_provisioning_audit(text,uuid,uuid,uuid,jsonb)') is null
    or pg_catalog.to_regprocedure('public.is_current_user_master()') is null
    or pg_catalog.to_regprocedure('public.master_admin_list_companies(text,text,integer,integer)') is null
    or pg_catalog.to_regprocedure('public.master_admin_list_branches(uuid)') is null
    or pg_catalog.to_regprocedure('public.master_admin_get_company(uuid)') is null then
    raise exception 'Foundation and Admin Master V1 read API are required';
  end if;
  if pg_catalog.to_regprocedure('public.master_admin_management_ready()') is not null
    or pg_catalog.to_regprocedure('public.master_create_company_v2(uuid,text,text,text,text,text)') is not null
    or pg_catalog.to_regprocedure('public.master_update_company_v2(uuid,uuid,text,text,text,text,text)') is not null
    or pg_catalog.to_regprocedure('public.master_set_company_status_v2(uuid,uuid,text)') is not null
    or pg_catalog.to_regprocedure('public.master_create_branch_v2(uuid,uuid,text,text,text,text,boolean)') is not null
    or pg_catalog.to_regprocedure('public.master_update_branch_v2(uuid,uuid,text,text,text,text,boolean)') is not null
    or pg_catalog.to_regprocedure('public.master_set_branch_status_v2(uuid,uuid,text)') is not null
    or pg_catalog.to_regprocedure('public.master_admin_list_companies_v2(text,text,integer,integer)') is not null
    or pg_catalog.to_regprocedure('public.master_admin_get_company_v2(uuid)') is not null
    or pg_catalog.to_regprocedure('public.master_admin_list_branches_v2(uuid)') is not null
    or pg_catalog.to_regclass('app_private.master_management_requests') is not null then
    raise exception 'V2 management objects already exist; inspect before proceeding';
  end if;
  if not exists(select 1 from pg_catalog.pg_class where oid='public.companies'::pg_catalog.regclass and relrowsecurity and relforcerowsecurity)
    or not exists(select 1 from pg_catalog.pg_class where oid='public.branches'::pg_catalog.regclass and relrowsecurity and relforcerowsecurity) then
    raise exception 'Company and branch RLS must remain enabled and forced';
  end if;
  select r.rolsuper or r.rolbypassrls into postgres_can_bypass_rls from pg_catalog.pg_roles r where r.rolname='postgres';
  if postgres_can_bypass_rls is distinct from true then raise exception 'postgres must bypass forced RLS for the narrow Master RPCs'; end if;
  if pg_catalog.to_regprocedure('auth.uid()') is null or pg_catalog.to_regprocedure('auth.role()') is null then
    raise exception 'Supabase Auth identity helpers are missing';
  end if;
  if not exists(select 1 from pg_catalog.pg_proc p join pg_catalog.pg_roles r on r.oid=p.proowner
      where p.oid=pg_catalog.to_regprocedure('app_private.write_provisioning_audit(text,uuid,uuid,uuid,jsonb)')
        and r.rolname='postgres' and not p.prosecdef and 'search_path=""'=any(p.proconfig) and 'row_security=off'=any(p.proconfig))
    or not exists(select 1 from pg_catalog.pg_trigger t
      where t.tgrelid='app_private.provisioning_audit_events'::pg_catalog.regclass
        and t.tgname='provisioning_audit_events_append_only' and t.tgtype=27 and t.tgenabled in ('O','A')
        and t.tgfoid=pg_catalog.to_regprocedure('app_private.prevent_provisioning_audit_mutation()') and not t.tgisinternal) then
    raise exception 'Append-only transactional audit dependencies are not in the expected state';
  end if;
  if exists (
    select 1 from (values ('public.companies'),('public.branches')) as protected(table_name)
    cross join (values ('anon'),('authenticated'),('service_role')) as api_role(role_name)
    where pg_catalog.has_table_privilege(api_role.role_name,protected.table_name,'INSERT')
      or pg_catalog.has_table_privilege(api_role.role_name,protected.table_name,'UPDATE')
      or pg_catalog.has_table_privilege(api_role.role_name,protected.table_name,'DELETE')
      or pg_catalog.has_table_privilege(api_role.role_name,protected.table_name,'TRUNCATE')
  ) then raise exception 'API roles have direct company or branch write privileges'; end if;
  if exists(select 1 from pg_catalog.pg_attribute where attrelid='public.companies'::pg_catalog.regclass
      and attname in ('trade_name','cnpj','contact_email','contact_phone') and not attisdropped)
    or exists(select 1 from pg_catalog.pg_attribute where attrelid='public.branches'::pg_catalog.regclass
      and attname in ('cnpj','address','is_headquarters') and not attisdropped) then
    raise exception 'V2 metadata columns already exist; inspect before proceeding';
  end if;
  if exists(select 1 from public.branches group by tenant_id,pg_catalog.upper(pg_catalog.btrim(code)) having pg_catalog.count(*)>1) then
    raise exception 'Existing branch codes collide after normalization; resolve before proceeding';
  end if;
end;
$preflight$;

alter table public.companies
  add column trade_name text,
  add column cnpj text,
  add column contact_email text,
  add column contact_phone text,
  add constraint companies_trade_name_length check (trade_name is null or pg_catalog.length(pg_catalog.btrim(trade_name)) between 1 and 200),
  add constraint companies_cnpj_format check (cnpj is null or cnpj ~ '^[0-9]{14}$'),
  add constraint companies_contact_email_length check (contact_email is null or pg_catalog.length(contact_email) <= 254),
  add constraint companies_contact_phone_format check (contact_phone is null or contact_phone ~ '^[0-9]{8,15}$');

alter table public.branches
  add column cnpj text,
  add column address text,
  add column is_headquarters boolean not null default false,
  add constraint branches_cnpj_format check (cnpj is null or cnpj ~ '^[0-9]{14}$'),
  add constraint branches_address_length check (address is null or pg_catalog.length(address) <= 500);

create unique index companies_cnpj_unique on public.companies(cnpj) where cnpj is not null;
create unique index branches_cnpj_unique on public.branches(cnpj) where cnpj is not null;
create unique index branches_tenant_code_normalized_unique on public.branches(tenant_id,pg_catalog.upper(pg_catalog.btrim(code)));
create unique index branches_one_headquarters_per_company on public.branches(tenant_id) where is_headquarters;

create table app_private.master_management_requests (
  actor_user_id uuid not null references auth.users(id) on delete restrict,
  operation_key text not null check (operation_key in ('company.create','company.update','company.status','branch.create','branch.update','branch.status')),
  request_id uuid not null,
  payload_fingerprint text not null check (payload_fingerprint ~ '^[0-9a-f]{32}$'),
  result_id uuid not null,
  created_at timestamptz not null default pg_catalog.clock_timestamp(),
  primary key(actor_user_id,operation_key,request_id)
);
alter table app_private.master_management_requests owner to postgres;
alter table app_private.master_management_requests enable row level security;
alter table app_private.master_management_requests force row level security;
revoke all on table app_private.master_management_requests from public,anon,authenticated,service_role;

create function app_private.assert_current_master()
returns uuid language plpgsql stable security definer
set search_path = '' set row_security = off
as $function$
declare actor_id uuid;
begin
  if coalesce(auth.role(),'') <> 'authenticated' then raise exception 'Authenticated session required' using errcode='42501'; end if;
  actor_id:=auth.uid();
  if actor_id is null then raise exception 'Authenticated user identity required' using errcode='42501'; end if;
  if public.is_current_user_master() is distinct from true then raise exception 'Active Admin Master authorization required' using errcode='42501'; end if;
  return actor_id;
end;
$function$;
alter function app_private.assert_current_master() owner to postgres;
revoke all on function app_private.assert_current_master() from public,anon,authenticated,service_role;

-- This private table stores only an MD5 fingerprint for retry consistency (not
-- authentication or authorization); raw contact data is not retained here.
create function app_private.master_management_requests(
  p_operation_key text,p_request_id uuid,p_payload jsonb,p_result_id uuid default null
)
returns uuid language plpgsql volatile security definer
set search_path = '' set row_security = off
as $function$
declare actor_id uuid; fingerprint text; old_fingerprint text; old_result uuid;
begin
  actor_id:=app_private.assert_current_master();
  if p_operation_key not in ('company.create','company.update','company.status','branch.create','branch.update','branch.status')
    or p_request_id is null or p_payload is null then raise exception 'Invalid mutation request' using errcode='22023'; end if;
  fingerprint:=pg_catalog.md5(p_payload::text);
  perform pg_catalog.pg_advisory_xact_lock(pg_catalog.hashtextextended(actor_id::text||':'||p_operation_key||':'||p_request_id::text,0));
  select payload_fingerprint,result_id into old_fingerprint,old_result
    from app_private.master_management_requests r
    where r.actor_user_id=actor_id and r.operation_key=p_operation_key and r.request_id=p_request_id;
  if found then
    if old_fingerprint is distinct from fingerprint then raise exception 'Request key was already used for different data' using errcode='22023'; end if;
    return old_result;
  end if;
  if p_result_id is null then return null; end if;
  insert into app_private.master_management_requests(actor_user_id,operation_key,request_id,payload_fingerprint,result_id)
    values(actor_id,p_operation_key,p_request_id,fingerprint,p_result_id);
  return p_result_id;
end;
$function$;
alter function app_private.master_management_requests(text,uuid,jsonb,uuid) owner to postgres;
revoke all on function app_private.master_management_requests(text,uuid,jsonb,uuid) from public,anon,authenticated,service_role;

create function app_private.is_valid_cnpj(p_value text)
returns boolean language plpgsql immutable set search_path = ''
as $function$
declare
  digits text;
  first_weights integer[]:=array[5,4,3,2,9,8,7,6,5,4,3,2];
  second_weights integer[]:=array[6,5,4,3,2,9,8,7,6,5,4,3,2];
  total integer; check_digit integer; i integer;
begin
  if p_value is null then return false; end if;
  digits:=pg_catalog.regexp_replace(p_value,'[^0-9]','','g');
  if pg_catalog.length(digits)<>14 or digits=pg_catalog.repeat(pg_catalog.substr(digits,1,1),14) then return false; end if;
  total:=0;
  for i in 1..12 loop total:=total+(pg_catalog.ascii(pg_catalog.substr(digits,i,1))-48)*first_weights[i]; end loop;
  check_digit:=case when total%11<2 then 0 else 11-total%11 end;
  if check_digit<>(pg_catalog.ascii(pg_catalog.substr(digits,13,1))-48) then return false; end if;
  total:=0;
  for i in 1..13 loop total:=total+(pg_catalog.ascii(pg_catalog.substr(digits,i,1))-48)*second_weights[i]; end loop;
  check_digit:=case when total%11<2 then 0 else 11-total%11 end;
  return check_digit=(pg_catalog.ascii(pg_catalog.substr(digits,14,1))-48);
end;
$function$;
alter function app_private.is_valid_cnpj(text) owner to postgres;
revoke all on function app_private.is_valid_cnpj(text) from public,anon,authenticated,service_role;

create function public.master_admin_management_ready()
returns boolean language plpgsql stable security definer set search_path = '' set row_security = off
as $function$ begin perform app_private.assert_current_master(); return true; end; $function$;

create function public.master_admin_list_companies_v2(p_search text default null,p_status text default null,p_limit integer default 50,p_offset integer default 0)
returns table(company_id uuid,legal_name text,trade_name text,cnpj text,contact_email text,contact_phone text,status text,
  created_at timestamptz,branch_count bigint,active_membership_count bigint)
language plpgsql stable security definer set search_path = '' set row_security = off
as $function$
begin
  perform app_private.assert_current_master();
  if p_search is not null and pg_catalog.length(p_search)>100 then raise exception 'Search text is too long' using errcode='22023'; end if;
  if p_status is not null and p_status not in ('active','suspended','closed') then raise exception 'Invalid company status' using errcode='22023'; end if;
  if p_limit is null or p_limit not between 1 and 100 or p_offset is null or p_offset not between 0 and 100000 then raise exception 'Invalid pagination' using errcode='22023'; end if;
  return query select c.id,c.legal_name,c.trade_name,c.cnpj,c.contact_email,c.contact_phone,c.status,c.created_at,
    (select pg_catalog.count(*) from public.branches b where b.tenant_id=c.id),
    (select pg_catalog.count(*) from public.company_memberships m where m.tenant_id=c.id and m.status='active')
    from public.companies c
    where (p_status is null or c.status=p_status)
      and (p_search is null or c.legal_name ilike '%'||pg_catalog.replace(pg_catalog.replace(p_search,'%','\%'),'_','\_')||'%'
        or coalesce(c.trade_name,'') ilike '%'||pg_catalog.replace(pg_catalog.replace(p_search,'%','\%'),'_','\_')||'%')
    order by c.created_at desc,c.id limit p_limit offset p_offset;
end;
$function$;

create function public.master_admin_get_company_v2(p_company_id uuid)
returns table(company_id uuid,legal_name text,trade_name text,cnpj text,contact_email text,contact_phone text,status text,
  created_at timestamptz,branch_count bigint,active_membership_count bigint)
language plpgsql stable security definer set search_path = '' set row_security = off
as $function$
begin
  perform app_private.assert_current_master();
  if p_company_id is null then raise exception 'Company is required' using errcode='22023'; end if;
  return query select c.id,c.legal_name,c.trade_name,c.cnpj,c.contact_email,c.contact_phone,c.status,c.created_at,
    (select pg_catalog.count(*) from public.branches b where b.tenant_id=c.id),
    (select pg_catalog.count(*) from public.company_memberships m where m.tenant_id=c.id and m.status='active')
    from public.companies c where c.id=p_company_id;
end;
$function$;

create function public.master_admin_list_branches_v2(p_tenant_id uuid)
returns table(branch_id uuid,tenant_id uuid,code text,name text,cnpj text,address text,is_headquarters boolean,status text,created_at timestamptz)
language plpgsql stable security definer set search_path = '' set row_security = off
as $function$
begin
  perform app_private.assert_current_master();
  if p_tenant_id is null then raise exception 'Company is required' using errcode='22023'; end if;
  return query select b.id,b.tenant_id,b.code,b.name,b.cnpj,b.address,b.is_headquarters,b.status,b.created_at
    from public.branches b where b.tenant_id=p_tenant_id order by b.is_headquarters desc,b.code,b.id;
end;
$function$;

create function public.master_create_company_v2(p_request_id uuid,p_legal_name text,p_trade_name text,p_cnpj text,p_contact_email text,p_contact_phone text)
returns uuid language plpgsql volatile security definer set search_path = '' set row_security = off
as $function$
declare
  actor_id uuid; new_id uuid; replay_id uuid; name_value text; trade_value text; cnpj_value text; email_value text; phone_value text; payload jsonb;
begin
  actor_id:=app_private.assert_current_master();
  if p_request_id is null or p_legal_name is null then raise exception 'Request key and legal name are required' using errcode='22023'; end if;
  name_value:=pg_catalog.btrim(p_legal_name); trade_value:=nullif(pg_catalog.btrim(p_trade_name),'');
  if nullif(pg_catalog.btrim(p_cnpj),'') is not null and p_cnpj ~ '[^0-9./[:space:]-]' then raise exception 'Company CNPJ contains invalid characters' using errcode='22023'; end if;
  if nullif(pg_catalog.btrim(p_contact_phone),'') is not null and p_contact_phone ~ '[^0-9+() ./-]' then raise exception 'Company phone contains invalid characters' using errcode='22023'; end if;
  cnpj_value:=case when nullif(pg_catalog.btrim(p_cnpj),'') is null then null else pg_catalog.regexp_replace(p_cnpj,'[^0-9]','','g') end;
  email_value:=nullif(pg_catalog.lower(pg_catalog.btrim(p_contact_email)),'');
  phone_value:=case when nullif(pg_catalog.btrim(p_contact_phone),'') is null then null else pg_catalog.regexp_replace(p_contact_phone,'[^0-9]','','g') end;
  if pg_catalog.length(name_value) not between 1 and 200 or (trade_value is not null and pg_catalog.length(trade_value)>200)
    or (cnpj_value is not null and not app_private.is_valid_cnpj(cnpj_value))
    or (email_value is not null and (pg_catalog.length(email_value)>254 or email_value !~ '^[^[:space:]@]+@[^[:space:]@]+\.[^[:space:]@]+$'))
    or (phone_value is not null and pg_catalog.length(phone_value) not between 8 and 15) then raise exception 'Company data is invalid' using errcode='22023'; end if;
  payload:=pg_catalog.jsonb_build_object('legal_name',name_value,'trade_name',trade_value,'cnpj',cnpj_value,'contact_email',email_value,'contact_phone',phone_value);
  replay_id:=app_private.master_management_requests('company.create',p_request_id,payload);
  if replay_id is not null then return replay_id; end if;
  insert into public.companies(legal_name,trade_name,cnpj,contact_email,contact_phone)
    values(name_value,trade_value,cnpj_value,email_value,phone_value) returning id into new_id;
  perform app_private.write_provisioning_audit('company.created',new_id,null,actor_id,
    pg_catalog.jsonb_build_object('request_id',p_request_id,'changed_fields',pg_catalog.jsonb_build_array('legal_name','trade_name','cnpj','contact_email','contact_phone')));
  perform app_private.master_management_requests('company.create',p_request_id,payload,new_id);
  return new_id;
end;
$function$;

create function public.master_update_company_v2(p_request_id uuid,p_company_id uuid,p_legal_name text,p_trade_name text,p_cnpj text,p_contact_email text,p_contact_phone text)
returns uuid language plpgsql volatile security definer set search_path = '' set row_security = off
as $function$
declare actor_id uuid; replay_id uuid; name_value text; trade_value text; cnpj_value text; email_value text; phone_value text; payload jsonb;
begin
  actor_id:=app_private.assert_current_master();
  if p_request_id is null or p_company_id is null or p_legal_name is null then raise exception 'Request key, company and legal name are required' using errcode='22023'; end if;
  name_value:=pg_catalog.btrim(p_legal_name); trade_value:=nullif(pg_catalog.btrim(p_trade_name),'');
  if nullif(pg_catalog.btrim(p_cnpj),'') is not null and p_cnpj ~ '[^0-9./[:space:]-]' then raise exception 'Company CNPJ contains invalid characters' using errcode='22023'; end if;
  if nullif(pg_catalog.btrim(p_contact_phone),'') is not null and p_contact_phone ~ '[^0-9+() ./-]' then raise exception 'Company phone contains invalid characters' using errcode='22023'; end if;
  cnpj_value:=case when nullif(pg_catalog.btrim(p_cnpj),'') is null then null else pg_catalog.regexp_replace(p_cnpj,'[^0-9]','','g') end;
  email_value:=nullif(pg_catalog.lower(pg_catalog.btrim(p_contact_email)),'');
  phone_value:=case when nullif(pg_catalog.btrim(p_contact_phone),'') is null then null else pg_catalog.regexp_replace(p_contact_phone,'[^0-9]','','g') end;
  if pg_catalog.length(name_value) not between 1 and 200 or (trade_value is not null and pg_catalog.length(trade_value)>200)
    or (cnpj_value is not null and not app_private.is_valid_cnpj(cnpj_value))
    or (email_value is not null and (pg_catalog.length(email_value)>254 or email_value !~ '^[^[:space:]@]+@[^[:space:]@]+\.[^[:space:]@]+$'))
    or (phone_value is not null and pg_catalog.length(phone_value) not between 8 and 15) then raise exception 'Company data is invalid' using errcode='22023'; end if;
  payload:=pg_catalog.jsonb_build_object('company_id',p_company_id,'legal_name',name_value,'trade_name',trade_value,'cnpj',cnpj_value,'contact_email',email_value,'contact_phone',phone_value);
  replay_id:=app_private.master_management_requests('company.update',p_request_id,payload);
  if replay_id is not null then return replay_id; end if;
  perform 1 from public.companies where id=p_company_id for update;
  if not found then raise exception 'Company not found' using errcode='P0002'; end if;
  update public.companies set legal_name=name_value,trade_name=trade_value,cnpj=cnpj_value,contact_email=email_value,contact_phone=phone_value where id=p_company_id;
  perform app_private.write_provisioning_audit('company.updated',p_company_id,null,actor_id,
    pg_catalog.jsonb_build_object('request_id',p_request_id,'changed_fields',pg_catalog.jsonb_build_array('legal_name','trade_name','cnpj','contact_email','contact_phone')));
  perform app_private.master_management_requests('company.update',p_request_id,payload,p_company_id);
  return p_company_id;
end;
$function$;

create function public.master_set_company_status_v2(p_request_id uuid,p_company_id uuid,p_status text)
returns uuid language plpgsql volatile security definer set search_path = '' set row_security = off
as $function$
declare actor_id uuid; replay_id uuid; payload jsonb; old_status text;
begin
  actor_id:=app_private.assert_current_master();
  if p_request_id is null or p_company_id is null or p_status is null or p_status not in ('active','suspended') then raise exception 'Invalid company status request' using errcode='22023'; end if;
  payload:=pg_catalog.jsonb_build_object('company_id',p_company_id,'status',p_status);
  replay_id:=app_private.master_management_requests('company.status',p_request_id,payload);
  if replay_id is not null then return replay_id; end if;
  select status into old_status from public.companies where id=p_company_id for update;
  if not found then raise exception 'Company not found' using errcode='P0002'; end if;
  if old_status='closed' then raise exception 'Closed company status is terminal' using errcode='22023'; end if;
  update public.companies set status=p_status where id=p_company_id;
  perform app_private.write_provisioning_audit('company.status_changed',p_company_id,null,actor_id,
    pg_catalog.jsonb_build_object('request_id',p_request_id,'old_status',old_status,'new_status',p_status));
  perform app_private.master_management_requests('company.status',p_request_id,payload,p_company_id);
  return p_company_id;
end;
$function$;

create function public.master_create_branch_v2(p_request_id uuid,p_company_id uuid,p_code text,p_name text,p_cnpj text,p_address text,p_is_headquarters boolean)
returns uuid language plpgsql volatile security definer set search_path = '' set row_security = off
as $function$
declare actor_id uuid; replay_id uuid; new_id uuid; code_value text; name_value text; cnpj_value text; address_value text; payload jsonb;
begin
  actor_id:=app_private.assert_current_master();
  if p_request_id is null or p_company_id is null or p_code is null or p_name is null then raise exception 'Request key, company, code and name are required' using errcode='22023'; end if;
  code_value:=pg_catalog.upper(pg_catalog.btrim(p_code)); name_value:=pg_catalog.btrim(p_name);
  if nullif(pg_catalog.btrim(p_cnpj),'') is not null and p_cnpj ~ '[^0-9./[:space:]-]' then raise exception 'Branch CNPJ contains invalid characters' using errcode='22023'; end if;
  cnpj_value:=case when nullif(pg_catalog.btrim(p_cnpj),'') is null then null else pg_catalog.regexp_replace(p_cnpj,'[^0-9]','','g') end;
  address_value:=nullif(pg_catalog.btrim(p_address),'');
  if pg_catalog.length(code_value) not between 1 and 40 or code_value !~ '^[A-Z0-9][A-Z0-9._-]*$'
    or pg_catalog.length(name_value) not between 1 and 160
    or (cnpj_value is not null and not app_private.is_valid_cnpj(cnpj_value))
    or (address_value is not null and pg_catalog.length(address_value)>500) then raise exception 'Branch data is invalid' using errcode='22023'; end if;
  payload:=pg_catalog.jsonb_build_object('company_id',p_company_id,'code',code_value,'name',name_value,'cnpj',cnpj_value,'address',address_value,'is_headquarters',coalesce(p_is_headquarters,false));
  replay_id:=app_private.master_management_requests('branch.create',p_request_id,payload);
  if replay_id is not null then return replay_id; end if;
  perform 1 from public.companies where id=p_company_id and status='active' for share;
  if not found then raise exception 'Active company not found' using errcode='P0002'; end if;
  insert into public.branches(tenant_id,code,name,cnpj,address,is_headquarters)
    values(p_company_id,code_value,name_value,cnpj_value,address_value,coalesce(p_is_headquarters,false)) returning id into new_id;
  perform app_private.write_provisioning_audit('branch.created',p_company_id,null,actor_id,
    pg_catalog.jsonb_build_object('request_id',p_request_id,'branch_id',new_id,'changed_fields',pg_catalog.jsonb_build_array('code','name','cnpj','address','is_headquarters')));
  perform app_private.master_management_requests('branch.create',p_request_id,payload,new_id);
  return new_id;
end;
$function$;

create function public.master_update_branch_v2(p_request_id uuid,p_branch_id uuid,p_code text,p_name text,p_cnpj text,p_address text,p_is_headquarters boolean)
returns uuid language plpgsql volatile security definer set search_path = '' set row_security = off
as $function$
declare actor_id uuid; replay_id uuid; branch_row public.branches%rowtype; code_value text; name_value text; cnpj_value text; address_value text; payload jsonb;
begin
  actor_id:=app_private.assert_current_master();
  if p_request_id is null or p_branch_id is null or p_code is null or p_name is null then raise exception 'Request key, branch, code and name are required' using errcode='22023'; end if;
  code_value:=pg_catalog.upper(pg_catalog.btrim(p_code)); name_value:=pg_catalog.btrim(p_name);
  if nullif(pg_catalog.btrim(p_cnpj),'') is not null and p_cnpj ~ '[^0-9./[:space:]-]' then raise exception 'Branch CNPJ contains invalid characters' using errcode='22023'; end if;
  cnpj_value:=case when nullif(pg_catalog.btrim(p_cnpj),'') is null then null else pg_catalog.regexp_replace(p_cnpj,'[^0-9]','','g') end;
  address_value:=nullif(pg_catalog.btrim(p_address),'');
  if pg_catalog.length(code_value) not between 1 and 40 or code_value !~ '^[A-Z0-9][A-Z0-9._-]*$'
    or pg_catalog.length(name_value) not between 1 and 160
    or (cnpj_value is not null and not app_private.is_valid_cnpj(cnpj_value))
    or (address_value is not null and pg_catalog.length(address_value)>500) then raise exception 'Branch data is invalid' using errcode='22023'; end if;
  payload:=pg_catalog.jsonb_build_object('branch_id',p_branch_id,'code',code_value,'name',name_value,'cnpj',cnpj_value,'address',address_value,'is_headquarters',coalesce(p_is_headquarters,false));
  replay_id:=app_private.master_management_requests('branch.update',p_request_id,payload);
  if replay_id is not null then return replay_id; end if;
  select * into branch_row from public.branches where id=p_branch_id for update;
  if not found then raise exception 'Branch not found' using errcode='P0002'; end if;
  update public.branches set code=code_value,name=name_value,cnpj=cnpj_value,address=address_value,is_headquarters=coalesce(p_is_headquarters,false) where id=p_branch_id;
  perform app_private.write_provisioning_audit('branch.updated',branch_row.tenant_id,null,actor_id,
    pg_catalog.jsonb_build_object('request_id',p_request_id,'branch_id',p_branch_id,'changed_fields',pg_catalog.jsonb_build_array('code','name','cnpj','address','is_headquarters')));
  perform app_private.master_management_requests('branch.update',p_request_id,payload,p_branch_id);
  return p_branch_id;
end;
$function$;

create function public.master_set_branch_status_v2(p_request_id uuid,p_branch_id uuid,p_status text)
returns uuid language plpgsql volatile security definer set search_path = '' set row_security = off
as $function$
declare actor_id uuid; replay_id uuid; payload jsonb; tenant_id uuid; old_status text;
begin
  actor_id:=app_private.assert_current_master();
  if p_request_id is null or p_branch_id is null or p_status is null or p_status not in ('active','inactive') then raise exception 'Invalid branch status request' using errcode='22023'; end if;
  payload:=pg_catalog.jsonb_build_object('branch_id',p_branch_id,'status',p_status);
  replay_id:=app_private.master_management_requests('branch.status',p_request_id,payload);
  if replay_id is not null then return replay_id; end if;
  select b.tenant_id,b.status into tenant_id,old_status from public.branches b where b.id=p_branch_id for update;
  if not found then raise exception 'Branch not found' using errcode='P0002'; end if;
  if p_status='active' then
    perform 1 from public.companies c where c.id=tenant_id and c.status='active' for share;
    if not found then raise exception 'Cannot activate a branch of a non-active company' using errcode='22023'; end if;
  end if;
  update public.branches set status=p_status where id=p_branch_id;
  perform app_private.write_provisioning_audit('branch.status_changed',tenant_id,null,actor_id,
    pg_catalog.jsonb_build_object('request_id',p_request_id,'branch_id',p_branch_id,'old_status',old_status,'new_status',p_status));
  perform app_private.master_management_requests('branch.status',p_request_id,payload,p_branch_id);
  return p_branch_id;
end;
$function$;

alter function public.master_admin_management_ready() owner to postgres;
alter function public.master_admin_list_companies_v2(text,text,integer,integer) owner to postgres;
alter function public.master_admin_get_company_v2(uuid) owner to postgres;
alter function public.master_admin_list_branches_v2(uuid) owner to postgres;
alter function public.master_create_company_v2(uuid,text,text,text,text,text) owner to postgres;
alter function public.master_update_company_v2(uuid,uuid,text,text,text,text,text) owner to postgres;
alter function public.master_set_company_status_v2(uuid,uuid,text) owner to postgres;
alter function public.master_create_branch_v2(uuid,uuid,text,text,text,text,boolean) owner to postgres;
alter function public.master_update_branch_v2(uuid,uuid,text,text,text,text,boolean) owner to postgres;
alter function public.master_set_branch_status_v2(uuid,uuid,text) owner to postgres;

revoke all on function public.master_admin_management_ready() from public,anon,authenticated,service_role;
revoke all on function public.master_admin_list_companies_v2(text,text,integer,integer) from public,anon,authenticated,service_role;
revoke all on function public.master_admin_get_company_v2(uuid) from public,anon,authenticated,service_role;
revoke all on function public.master_admin_list_branches_v2(uuid) from public,anon,authenticated,service_role;
revoke all on function public.master_create_company_v2(uuid,text,text,text,text,text) from public,anon,authenticated,service_role;
revoke all on function public.master_update_company_v2(uuid,uuid,text,text,text,text,text) from public,anon,authenticated,service_role;
revoke all on function public.master_set_company_status_v2(uuid,uuid,text) from public,anon,authenticated,service_role;
revoke all on function public.master_create_branch_v2(uuid,uuid,text,text,text,text,boolean) from public,anon,authenticated,service_role;
revoke all on function public.master_update_branch_v2(uuid,uuid,text,text,text,text,boolean) from public,anon,authenticated,service_role;
revoke all on function public.master_set_branch_status_v2(uuid,uuid,text) from public,anon,authenticated,service_role;
grant execute on function public.master_admin_management_ready() to authenticated;
grant execute on function public.master_admin_list_companies_v2(text,text,integer,integer) to authenticated;
grant execute on function public.master_admin_get_company_v2(uuid) to authenticated;
grant execute on function public.master_admin_list_branches_v2(uuid) to authenticated;
grant execute on function public.master_create_company_v2(uuid,text,text,text,text,text) to authenticated;
grant execute on function public.master_update_company_v2(uuid,uuid,text,text,text,text,text) to authenticated;
grant execute on function public.master_set_company_status_v2(uuid,uuid,text) to authenticated;
grant execute on function public.master_create_branch_v2(uuid,uuid,text,text,text,text,boolean) to authenticated;
grant execute on function public.master_update_branch_v2(uuid,uuid,text,text,text,text,boolean) to authenticated;
grant execute on function public.master_set_branch_status_v2(uuid,uuid,text) to authenticated;

do $verify$
declare function_oid oid; owner_oid oid; authenticated_oid oid;
begin
  select oid into owner_oid from pg_catalog.pg_roles where rolname='postgres';
  select oid into authenticated_oid from pg_catalog.pg_roles where rolname='authenticated';
  foreach function_oid in array array[
    pg_catalog.to_regprocedure('public.master_admin_management_ready()'),
    pg_catalog.to_regprocedure('public.master_admin_list_companies_v2(text,text,integer,integer)'),
    pg_catalog.to_regprocedure('public.master_admin_get_company_v2(uuid)'),
    pg_catalog.to_regprocedure('public.master_admin_list_branches_v2(uuid)'),
    pg_catalog.to_regprocedure('public.master_create_company_v2(uuid,text,text,text,text,text)'),
    pg_catalog.to_regprocedure('public.master_update_company_v2(uuid,uuid,text,text,text,text,text)'),
    pg_catalog.to_regprocedure('public.master_set_company_status_v2(uuid,uuid,text)'),
    pg_catalog.to_regprocedure('public.master_create_branch_v2(uuid,uuid,text,text,text,text,boolean)'),
    pg_catalog.to_regprocedure('public.master_update_branch_v2(uuid,uuid,text,text,text,text,boolean)'),
    pg_catalog.to_regprocedure('public.master_set_branch_status_v2(uuid,uuid,text)')
  ] loop
    if function_oid is null or not pg_catalog.has_function_privilege('authenticated',function_oid,'EXECUTE')
      or pg_catalog.has_function_privilege('anon',function_oid,'EXECUTE')
      or pg_catalog.has_function_privilege('service_role',function_oid,'EXECUTE') then raise exception 'V2 RPC effective ACL is invalid'; end if;
    if not exists(select 1 from pg_catalog.pg_proc p where p.oid=function_oid and p.proowner=owner_oid and p.prosecdef
      and 'search_path=""'=any(p.proconfig) and 'row_security=off'=any(p.proconfig)) then raise exception 'V2 RPC security configuration is invalid'; end if;
    if exists(select 1 from pg_catalog.pg_proc p cross join lateral pg_catalog.aclexplode(coalesce(p.proacl,pg_catalog.acldefault('f',p.proowner))) acl
      where p.oid=function_oid and (acl.grantee not in(owner_oid,authenticated_oid) or acl.grantor<>owner_oid or acl.privilege_type<>'EXECUTE' or acl.is_grantable))
      or not exists(select 1 from pg_catalog.pg_proc p cross join lateral pg_catalog.aclexplode(coalesce(p.proacl,pg_catalog.acldefault('f',p.proowner))) acl
        where p.oid=function_oid and acl.grantee=authenticated_oid and acl.grantor=owner_oid and acl.privilege_type='EXECUTE' and not acl.is_grantable)
      then raise exception 'V2 RPC explicit ACL is invalid'; end if;
  end loop;
  if not exists(select 1 from pg_catalog.pg_class where oid='public.companies'::pg_catalog.regclass and relrowsecurity and relforcerowsecurity)
    or not exists(select 1 from pg_catalog.pg_class where oid='public.branches'::pg_catalog.regclass and relrowsecurity and relforcerowsecurity)
    or pg_catalog.has_table_privilege('authenticated','public.companies','INSERT')
    or pg_catalog.has_table_privilege('authenticated','public.companies','UPDATE')
    or pg_catalog.has_table_privilege('authenticated','public.branches','INSERT')
    or pg_catalog.has_table_privilege('authenticated','public.branches','UPDATE') then
    raise exception 'V2 altered direct table access or weakened forced RLS';
  end if;
end;
$verify$;

commit;
