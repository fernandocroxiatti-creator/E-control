-- Operational ERP foundation: business partners, catalog and transactional inventory.
-- All new permissions and transactions start pending_approval. This migration grants no role.

begin;

do $preflight$
begin
  if current_user <> 'postgres' then raise exception 'Apply this migration as postgres'; end if;
  if pg_catalog.to_regclass('public.companies') is null
    or pg_catalog.to_regclass('public.branches') is null
    or pg_catalog.to_regclass('public.company_memberships') is null
    or pg_catalog.to_regclass('public.permission_definitions') is null
    or pg_catalog.to_regclass('public.erp_transaction_authorization_catalog') is null
    or pg_catalog.to_regprocedure('app_private.has_tenant_permission(uuid,text,uuid)') is null
    or pg_catalog.to_regprocedure('app_private.can_access_branch(uuid,uuid)') is null
    or pg_catalog.to_regprocedure('auth.uid()') is null then
    raise exception 'Tenant authorization foundation is required';
  end if;
  if pg_catalog.to_regclass('public.business_parties') is not null
    or pg_catalog.to_regclass('public.catalog_items') is not null
    or pg_catalog.to_regclass('public.inventory_movements') is not null
    or pg_catalog.to_regprocedure('public.operational_record_inventory_movement(uuid,uuid,uuid,text,numeric,uuid,text)') is not null then
    raise exception 'Operational ERP objects already exist; inspect before applying';
  end if;
end;
$preflight$;

insert into public.permission_definitions (permission_key, description)
values
  ('transaction.masterdata.party.read', 'Consultar clientes e fornecedores da própria empresa.'),
  ('transaction.masterdata.party.manage', 'Cadastrar e alterar clientes e fornecedores da própria empresa.'),
  ('transaction.masterdata.catalog.read', 'Consultar produtos e serviços da própria empresa.'),
  ('transaction.masterdata.catalog.product.manage', 'Cadastrar e alterar produtos da própria empresa.'),
  ('transaction.masterdata.catalog.service.manage', 'Cadastrar e alterar serviços da própria empresa.'),
  ('transaction.inventory.stock.move', 'Registrar estoque inicial, entradas, saídas e ajustes nas filiais autorizadas.')
on conflict (permission_key) do nothing;

insert into public.erp_transaction_authorization_catalog (transaction_code, module_code, permission_key)
values
  ('BP01', 'MDM', 'transaction.masterdata.party.manage'),
  ('MM01', 'MDM', 'transaction.masterdata.catalog.product.manage'),
  ('SV01', 'MDM', 'transaction.masterdata.catalog.service.manage'),
  ('MIGO', 'INV', 'transaction.inventory.stock.move')
on conflict (transaction_code) do nothing;

create table public.business_parties (
  id uuid primary key default pg_catalog.gen_random_uuid(),
  tenant_id uuid not null references public.companies(id) on delete restrict,
  party_type text not null check (party_type in ('customer', 'supplier', 'both')),
  legal_name text not null check (pg_catalog.length(pg_catalog.btrim(legal_name)) between 1 and 200),
  document_number text check (document_number is null or document_number ~ '^(?:[0-9]{11}|[0-9]{14})$'),
  contact_email text check (contact_email is null or (contact_email = pg_catalog.lower(pg_catalog.btrim(contact_email)) and contact_email ~ '^[^[:space:]@]+@[^[:space:]@]+\\.[^[:space:]@]+$')),
  contact_phone text,
  address jsonb not null default '{}'::jsonb check (pg_catalog.jsonb_typeof(address) = 'object'),
  status text not null default 'active' check (status in ('active', 'inactive')),
  request_id uuid not null,
  created_by_user_id uuid not null references auth.users(id) on delete restrict,
  created_at timestamptz not null default pg_catalog.clock_timestamp(),
  updated_at timestamptz not null default pg_catalog.clock_timestamp(),
  constraint business_parties_tenant_id_id_unique unique (tenant_id, id),
  constraint business_parties_tenant_request_unique unique (tenant_id, request_id)
);
create unique index business_parties_tenant_document_unique on public.business_parties (tenant_id, document_number)
  where document_number is not null;
create index business_parties_tenant_lookup_idx on public.business_parties (tenant_id, status, legal_name);

create table public.catalog_items (
  id uuid primary key default pg_catalog.gen_random_uuid(),
  tenant_id uuid not null references public.companies(id) on delete restrict,
  item_type text not null check (item_type in ('product', 'service')),
  code text not null check (code ~ '^[A-Z0-9][A-Z0-9._-]{0,63}$'),
  name text not null check (pg_catalog.length(pg_catalog.btrim(name)) between 1 and 160),
  description text,
  category text,
  brand text,
  application_model text,
  unit_of_measure text not null default 'UN' check (unit_of_measure ~ '^[A-Z]{1,8}$'),
  supplier_code text,
  preferred_supplier_id uuid,
  current_cost numeric(18,4) not null default 0 check (current_cost >= 0),
  selling_price numeric(18,4) not null default 0 check (selling_price >= 0),
  default_markup_percent numeric(9,4) check (default_markup_percent is null or default_markup_percent >= 0),
  target_margin_percent numeric(9,4) check (target_margin_percent is null or (target_margin_percent >= 0 and target_margin_percent < 100)),
  minimum_stock numeric(18,4) not null default 0 check (minimum_stock >= 0),
  reorder_point numeric(18,4) not null default 0 check (reorder_point >= 0),
  estimated_minutes integer check (estimated_minutes is null or estimated_minutes >= 0),
  service_cost numeric(18,4) check (service_cost is null or service_cost >= 0),
  status text not null default 'active' check (status in ('active', 'inactive')),
  request_id uuid not null,
  created_by_user_id uuid not null references auth.users(id) on delete restrict,
  created_at timestamptz not null default pg_catalog.clock_timestamp(),
  updated_at timestamptz not null default pg_catalog.clock_timestamp(),
  constraint catalog_items_tenant_id_id_unique unique (tenant_id, id),
  constraint catalog_items_tenant_code_unique unique (tenant_id, code),
  constraint catalog_items_tenant_request_unique unique (tenant_id, request_id),
  constraint catalog_items_preferred_supplier_fk foreign key (tenant_id, preferred_supplier_id)
    references public.business_parties(tenant_id, id) on delete restrict,
  constraint catalog_items_type_stock_check check (
    (item_type = 'product') or (minimum_stock = 0 and reorder_point = 0)
  )
);
create index catalog_items_tenant_lookup_idx on public.catalog_items (tenant_id, item_type, status, name);

create table public.catalog_item_cost_history (
  id uuid primary key default pg_catalog.gen_random_uuid(),
  tenant_id uuid not null,
  item_id uuid not null,
  previous_cost numeric(18,4) not null check (previous_cost >= 0),
  new_cost numeric(18,4) not null check (new_cost >= 0),
  changed_by_user_id uuid not null references auth.users(id) on delete restrict,
  created_at timestamptz not null default pg_catalog.clock_timestamp(),
  constraint catalog_item_cost_history_item_fk foreign key (tenant_id, item_id)
    references public.catalog_items(tenant_id, id) on delete restrict
);
create index catalog_item_cost_history_item_idx on public.catalog_item_cost_history (tenant_id, item_id, created_at desc);

create table public.inventory_balances (
  tenant_id uuid not null,
  branch_id uuid not null,
  item_id uuid not null,
  quantity numeric(18,4) not null default 0 check (quantity >= 0),
  updated_at timestamptz not null default pg_catalog.clock_timestamp(),
  primary key (tenant_id, branch_id, item_id),
  constraint inventory_balances_branch_fk foreign key (tenant_id, branch_id)
    references public.branches(tenant_id, id) on delete restrict,
  constraint inventory_balances_item_fk foreign key (tenant_id, item_id)
    references public.catalog_items(tenant_id, id) on delete restrict
);

create table public.inventory_movements (
  id uuid primary key default pg_catalog.gen_random_uuid(),
  tenant_id uuid not null,
  branch_id uuid not null,
  item_id uuid not null,
  movement_type text not null check (movement_type in ('initial', 'entry', 'exit', 'adjustment_positive', 'adjustment_negative')),
  quantity numeric(18,4) not null check (quantity > 0),
  balance_after numeric(18,4) not null check (balance_after >= 0),
  reference_note text check (reference_note is null or pg_catalog.length(pg_catalog.btrim(reference_note)) <= 500),
  request_id uuid not null,
  created_by_user_id uuid not null references auth.users(id) on delete restrict,
  created_at timestamptz not null default pg_catalog.clock_timestamp(),
  constraint inventory_movements_tenant_request_unique unique (tenant_id, request_id),
  constraint inventory_movements_branch_fk foreign key (tenant_id, branch_id)
    references public.branches(tenant_id, id) on delete restrict,
  constraint inventory_movements_item_fk foreign key (tenant_id, item_id)
    references public.catalog_items(tenant_id, id) on delete restrict
);
create index inventory_movements_item_history_idx on public.inventory_movements (tenant_id, branch_id, item_id, created_at desc);

create table app_private.operational_audit_events (
  id uuid primary key default pg_catalog.gen_random_uuid(),
  event_key text not null,
  tenant_id uuid not null references public.companies(id) on delete restrict,
  branch_id uuid,
  subject_id uuid,
  actor_user_id uuid not null references auth.users(id) on delete restrict,
  details jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default pg_catalog.clock_timestamp(),
  check (pg_catalog.jsonb_typeof(details) = 'object')
);
create index operational_audit_events_tenant_created_idx on app_private.operational_audit_events (tenant_id, created_at desc);

alter table public.business_parties enable row level security;
alter table public.business_parties force row level security;
alter table public.catalog_items enable row level security;
alter table public.catalog_items force row level security;
alter table public.catalog_item_cost_history enable row level security;
alter table public.catalog_item_cost_history force row level security;
alter table public.inventory_balances enable row level security;
alter table public.inventory_balances force row level security;
alter table public.inventory_movements enable row level security;
alter table public.inventory_movements force row level security;
alter table app_private.operational_audit_events enable row level security;
alter table app_private.operational_audit_events force row level security;
revoke all on table public.business_parties, public.catalog_items, public.catalog_item_cost_history,
  public.inventory_balances, public.inventory_movements, app_private.operational_audit_events
  from public, anon, authenticated, service_role;

create function app_private.assert_operational_permission(p_tenant_id uuid, p_permission_key text, p_branch_id uuid default null)
returns uuid language plpgsql stable security definer set search_path = '' set row_security = off as $function$
declare actor_id uuid;
begin
  if coalesce(auth.role(), '') <> 'authenticated' or auth.uid() is null then
    raise exception 'Authenticated session required' using errcode = '42501';
  end if;
  actor_id := auth.uid();
  if p_tenant_id is null or p_permission_key is null
    or not app_private.is_active_company_member(p_tenant_id)
    or (p_branch_id is not null and not app_private.can_access_branch(p_tenant_id, p_branch_id))
    or not app_private.has_tenant_permission(p_tenant_id, p_permission_key, p_branch_id) then
    raise exception 'Operational permission denied' using errcode = '42501';
  end if;
  return actor_id;
end;
$function$;

create function app_private.write_operational_audit(p_event_key text, p_tenant_id uuid, p_branch_id uuid, p_subject_id uuid, p_actor_user_id uuid, p_details jsonb)
returns void language sql security definer set search_path = '' set row_security = off as $function$
  insert into app_private.operational_audit_events (event_key, tenant_id, branch_id, subject_id, actor_user_id, details)
  values (p_event_key, p_tenant_id, p_branch_id, p_subject_id, p_actor_user_id, coalesce(p_details, '{}'::jsonb));
$function$;

create function public.operational_list_business_parties(p_tenant_id uuid, p_search text default null, p_party_type text default null, p_status text default null, p_limit integer default 50, p_offset integer default 0)
returns table (party_id uuid, party_type text, legal_name text, document_number text, contact_email text, contact_phone text, status text, created_at timestamptz)
language plpgsql stable security definer set search_path = '' set row_security = off as $function$
begin
  perform app_private.assert_operational_permission(p_tenant_id, 'transaction.masterdata.party.read');
  if p_limit not between 1 and 100 or p_offset < 0 or p_party_type not in ('customer','supplier','both') and p_party_type is not null or p_status not in ('active','inactive') and p_status is not null then
    raise exception 'Invalid business party listing request' using errcode = '22023';
  end if;
  return query select p.id, p.party_type, p.legal_name, p.document_number, p.contact_email, p.contact_phone, p.status, p.created_at
    from public.business_parties p where p.tenant_id = p_tenant_id
      and (p_search is null or p.legal_name ilike '%' || pg_catalog.btrim(p_search) || '%' or coalesce(p.document_number,'') like '%' || pg_catalog.btrim(p_search) || '%')
      and (p_party_type is null or p.party_type = p_party_type or p.party_type = 'both')
      and (p_status is null or p.status = p_status)
    order by p.legal_name, p.id limit p_limit offset p_offset;
end;
$function$;

create function public.operational_create_business_party(p_tenant_id uuid, p_party_type text, p_legal_name text, p_document_number text, p_contact_email text, p_contact_phone text, p_address jsonb, p_request_id uuid)
returns uuid language plpgsql volatile security definer set search_path = '' set row_security = off as $function$
declare actor_id uuid; party_id uuid; normalized_document text;
begin
  actor_id := app_private.assert_operational_permission(p_tenant_id, 'transaction.masterdata.party.manage');
  normalized_document := nullif(regexp_replace(coalesce(p_document_number,''), '[^0-9]', '', 'g'), '');
  if p_request_id is null or p_party_type not in ('customer','supplier','both') or p_legal_name is null or length(btrim(p_legal_name)) not between 1 and 200 or (normalized_document is not null and normalized_document !~ '^(?:[0-9]{11}|[0-9]{14})$') or (p_address is not null and jsonb_typeof(p_address) <> 'object') then
    raise exception 'Invalid business party request' using errcode = '22023';
  end if;
  perform pg_advisory_xact_lock(hashtextextended('business-party:' || p_tenant_id::text || ':' || p_request_id::text,0));
  select p.id into party_id from public.business_parties p where p.tenant_id=p_tenant_id and p.request_id=p_request_id;
  if found then return party_id; end if;
  insert into public.business_parties (tenant_id, party_type, legal_name, document_number, contact_email, contact_phone, address, request_id, created_by_user_id)
  values (p_tenant_id, p_party_type, btrim(p_legal_name), normalized_document, nullif(lower(btrim(p_contact_email)),''), nullif(btrim(p_contact_phone),''), coalesce(p_address, '{}'::jsonb), p_request_id, actor_id)
  returning id into party_id;
  perform app_private.write_operational_audit('business_party.created', p_tenant_id, null, party_id, actor_id, jsonb_build_object('party_type',p_party_type));
  return party_id;
end;
$function$;

create function public.operational_create_catalog_item(p_tenant_id uuid, p_item_type text, p_code text, p_name text, p_description text, p_category text, p_brand text, p_application_model text, p_unit_of_measure text, p_supplier_code text, p_preferred_supplier_id uuid, p_current_cost numeric, p_selling_price numeric, p_default_markup_percent numeric, p_target_margin_percent numeric, p_minimum_stock numeric, p_reorder_point numeric, p_estimated_minutes integer, p_service_cost numeric, p_request_id uuid)
returns uuid language plpgsql volatile security definer set search_path = '' set row_security = off as $function$
declare actor_id uuid; item_id uuid; normalized_code text;
begin
  if p_item_type not in ('product','service') then raise exception 'Invalid catalog item type' using errcode = '22023'; end if;
  actor_id := app_private.assert_operational_permission(p_tenant_id, case when p_item_type='product' then 'transaction.masterdata.catalog.product.manage' else 'transaction.masterdata.catalog.service.manage' end);
  normalized_code := upper(btrim(coalesce(p_code,'')));
  if p_request_id is null or p_item_type not in ('product','service') or normalized_code !~ '^[A-Z0-9][A-Z0-9._-]{0,63}$' or p_name is null or length(btrim(p_name)) not between 1 and 160 or coalesce(p_current_cost,0) < 0 or coalesce(p_selling_price,0) < 0 or coalesce(p_default_markup_percent,0) < 0 or (p_target_margin_percent is not null and (p_target_margin_percent < 0 or p_target_margin_percent >= 100)) or coalesce(p_minimum_stock,0) < 0 or coalesce(p_reorder_point,0) < 0 or (p_item_type = 'service' and (coalesce(p_minimum_stock,0) <> 0 or coalesce(p_reorder_point,0) <> 0)) then
    raise exception 'Invalid catalog item request' using errcode = '22023';
  end if;
  if p_preferred_supplier_id is not null and not exists (select 1 from public.business_parties p where p.tenant_id = p_tenant_id and p.id = p_preferred_supplier_id and p.party_type in ('supplier','both') and p.status = 'active') then
    raise exception 'Active supplier in this company required' using errcode = '23503';
  end if;
  perform pg_advisory_xact_lock(hashtextextended('catalog-item:' || p_tenant_id::text || ':' || p_request_id::text,0));
  select i.id into item_id from public.catalog_items i where i.tenant_id=p_tenant_id and i.request_id=p_request_id;
  if found then return item_id; end if;
  insert into public.catalog_items (tenant_id,item_type,code,name,description,category,brand,application_model,unit_of_measure,supplier_code,preferred_supplier_id,current_cost,selling_price,default_markup_percent,target_margin_percent,minimum_stock,reorder_point,estimated_minutes,service_cost,request_id,created_by_user_id)
  values (p_tenant_id,p_item_type,normalized_code,btrim(p_name),nullif(btrim(p_description),''),nullif(btrim(p_category),''),nullif(btrim(p_brand),''),nullif(btrim(p_application_model),''),upper(coalesce(nullif(btrim(p_unit_of_measure),''),'UN')),nullif(btrim(p_supplier_code),''),p_preferred_supplier_id,coalesce(p_current_cost,0),coalesce(p_selling_price,0),p_default_markup_percent,p_target_margin_percent,coalesce(p_minimum_stock,0),coalesce(p_reorder_point,0),p_estimated_minutes,p_service_cost,p_request_id,actor_id)
  returning id into item_id;
  perform app_private.write_operational_audit('catalog_item.created', p_tenant_id, null, item_id, actor_id, jsonb_build_object('item_type',p_item_type,'code',normalized_code));
  return item_id;
end;
$function$;

create function public.operational_update_business_party(p_tenant_id uuid, p_party_id uuid, p_legal_name text, p_contact_email text, p_contact_phone text, p_address jsonb, p_request_id uuid)
returns uuid language plpgsql volatile security definer set search_path = '' set row_security = off as $function$
declare actor_id uuid; updated_id uuid;
begin
  actor_id := app_private.assert_operational_permission(p_tenant_id, 'transaction.masterdata.party.manage');
  if p_party_id is null or p_request_id is null or p_legal_name is null or length(btrim(p_legal_name)) not between 1 and 200 or (p_address is not null and jsonb_typeof(p_address) <> 'object') then raise exception 'Invalid business party update request' using errcode='22023'; end if;
  update public.business_parties set legal_name=btrim(p_legal_name),contact_email=nullif(lower(btrim(p_contact_email)),''),contact_phone=nullif(btrim(p_contact_phone),''),address=coalesce(p_address,'{}'::jsonb),updated_at=clock_timestamp()
    where tenant_id=p_tenant_id and id=p_party_id returning id into updated_id;
  if not found then raise exception 'Business party not found in this company' using errcode='P0002'; end if;
  perform app_private.write_operational_audit('business_party.updated',p_tenant_id,null,updated_id,actor_id,jsonb_build_object('request_id',p_request_id));
  return updated_id;
end;
$function$;

create function public.operational_set_business_party_status(p_tenant_id uuid, p_party_id uuid, p_status text, p_request_id uuid)
returns text language plpgsql volatile security definer set search_path = '' set row_security = off as $function$
declare actor_id uuid;
begin
  actor_id := app_private.assert_operational_permission(p_tenant_id, 'transaction.masterdata.party.manage');
  if p_party_id is null or p_request_id is null or p_status not in ('active','inactive') then raise exception 'Invalid business party status request' using errcode='22023'; end if;
  update public.business_parties set status=p_status,updated_at=clock_timestamp() where tenant_id=p_tenant_id and id=p_party_id;
  if not found then raise exception 'Business party not found in this company' using errcode='P0002'; end if;
  perform app_private.write_operational_audit('business_party.status_changed',p_tenant_id,null,p_party_id,actor_id,jsonb_build_object('status',p_status,'request_id',p_request_id));
  return p_status;
end;
$function$;

create function public.operational_update_catalog_item(p_tenant_id uuid, p_item_id uuid, p_name text, p_description text, p_category text, p_selling_price numeric, p_minimum_stock numeric, p_reorder_point numeric, p_status text, p_request_id uuid)
returns uuid language plpgsql volatile security definer set search_path = '' set row_security = off as $function$
declare actor_id uuid; updated_id uuid; item_type_value text;
begin
  if coalesce(auth.role(), '') <> 'authenticated' or auth.uid() is null then raise exception 'Authenticated session required' using errcode='42501'; end if;
  perform app_private.assert_operational_permission(p_tenant_id, 'transaction.masterdata.catalog.read');
  if p_item_id is null or p_request_id is null or p_name is null or length(btrim(p_name)) not between 1 and 160 or coalesce(p_selling_price,0)<0 or coalesce(p_minimum_stock,0)<0 or coalesce(p_reorder_point,0)<0 or p_status not in ('active','inactive') then raise exception 'Invalid catalog item update request' using errcode='22023'; end if;
  select item_type into item_type_value from public.catalog_items where tenant_id=p_tenant_id and id=p_item_id for update;
  if not found then raise exception 'Catalog item not found in this company' using errcode='P0002'; end if;
  if item_type_value='service' and (coalesce(p_minimum_stock,0)<>0 or coalesce(p_reorder_point,0)<>0) then raise exception 'Services cannot carry stock thresholds' using errcode='22023'; end if;
  actor_id := app_private.assert_operational_permission(p_tenant_id, case when item_type_value='product' then 'transaction.masterdata.catalog.product.manage' else 'transaction.masterdata.catalog.service.manage' end);
  update public.catalog_items set name=btrim(p_name),description=nullif(btrim(p_description),''),category=nullif(btrim(p_category),''),selling_price=p_selling_price,minimum_stock=p_minimum_stock,reorder_point=p_reorder_point,status=p_status,updated_at=clock_timestamp() where tenant_id=p_tenant_id and id=p_item_id returning id into updated_id;
  perform app_private.write_operational_audit('catalog_item.updated',p_tenant_id,null,updated_id,actor_id,jsonb_build_object('status',p_status,'request_id',p_request_id));
  return updated_id;
end;
$function$;

create function public.operational_set_catalog_item_status(p_tenant_id uuid, p_item_id uuid, p_status text, p_request_id uuid)
returns text language plpgsql volatile security definer set search_path = '' set row_security = off as $function$
declare actor_id uuid; item_type_value text;
begin
  if coalesce(auth.role(), '') <> 'authenticated' or auth.uid() is null then raise exception 'Authenticated session required' using errcode='42501'; end if;
  perform app_private.assert_operational_permission(p_tenant_id, 'transaction.masterdata.catalog.read');
  if p_item_id is null or p_request_id is null or p_status not in ('active','inactive') then raise exception 'Invalid catalog item status request' using errcode='22023'; end if;
  select item_type into item_type_value from public.catalog_items where tenant_id=p_tenant_id and id=p_item_id for update;
  if not found then raise exception 'Catalog item not found in this company' using errcode='P0002'; end if;
  actor_id := app_private.assert_operational_permission(p_tenant_id, case when item_type_value='product' then 'transaction.masterdata.catalog.product.manage' else 'transaction.masterdata.catalog.service.manage' end);
  update public.catalog_items set status=p_status,updated_at=clock_timestamp() where tenant_id=p_tenant_id and id=p_item_id;
  perform app_private.write_operational_audit('catalog_item.status_changed',p_tenant_id,null,p_item_id,actor_id,jsonb_build_object('status',p_status,'request_id',p_request_id));
  return p_status;
end;
$function$;

create function public.operational_record_inventory_movement(p_tenant_id uuid, p_branch_id uuid, p_item_id uuid, p_movement_type text, p_quantity numeric, p_request_id uuid, p_reference_note text default null)
returns table (movement_id uuid, balance_after numeric)
language plpgsql volatile security definer set search_path = '' set row_security = off as $function$
declare actor_id uuid; delta numeric; current_quantity numeric; new_quantity numeric; existing_id uuid; existing_balance numeric;
begin
  actor_id := app_private.assert_operational_permission(p_tenant_id, 'transaction.inventory.stock.move', p_branch_id);
  if p_item_id is null or p_request_id is null or p_movement_type not in ('initial','entry','exit','adjustment_positive','adjustment_negative') or p_quantity is null or p_quantity <= 0 then raise exception 'Invalid inventory movement request' using errcode = '22023'; end if;
  perform pg_advisory_xact_lock(hashtextextended('inventory:' || p_tenant_id::text || ':' || p_branch_id::text || ':' || p_item_id::text,0));
  select m.id,m.balance_after into existing_id,existing_balance from public.inventory_movements m where m.tenant_id=p_tenant_id and m.request_id=p_request_id;
  if found then return query select existing_id,existing_balance; return; end if;
  if not exists (select 1 from public.catalog_items i where i.tenant_id=p_tenant_id and i.id=p_item_id and i.item_type='product' and i.status='active') then raise exception 'Active product in this company required' using errcode = '23503'; end if;
  if not exists (select 1 from public.branches b where b.tenant_id=p_tenant_id and b.id=p_branch_id and b.status='active') then raise exception 'Active branch in this company required' using errcode = '23503'; end if;
  if p_movement_type='initial' and exists (select 1 from public.inventory_movements m where m.tenant_id=p_tenant_id and m.branch_id=p_branch_id and m.item_id=p_item_id and m.movement_type='initial') then raise exception 'Initial stock was already recorded for this item and branch' using errcode = '23505'; end if;
  select b.quantity into current_quantity from public.inventory_balances b where b.tenant_id=p_tenant_id and b.branch_id=p_branch_id and b.item_id=p_item_id for update;
  current_quantity := coalesce(current_quantity,0);
  delta := case when p_movement_type in ('initial','entry','adjustment_positive') then p_quantity else -p_quantity end;
  new_quantity := current_quantity + delta;
  if new_quantity < 0 then raise exception 'Negative inventory is not allowed' using errcode = '23514'; end if;
  insert into public.inventory_balances (tenant_id,branch_id,item_id,quantity) values (p_tenant_id,p_branch_id,p_item_id,new_quantity)
  on conflict (tenant_id,branch_id,item_id) do update set quantity=excluded.quantity,updated_at=clock_timestamp();
  insert into public.inventory_movements as movement (tenant_id,branch_id,item_id,movement_type,quantity,balance_after,reference_note,request_id,created_by_user_id)
  values (p_tenant_id,p_branch_id,p_item_id,p_movement_type,p_quantity,new_quantity,nullif(btrim(p_reference_note),''),p_request_id,actor_id)
  returning movement.id,movement.balance_after into movement_id,balance_after;
  perform app_private.write_operational_audit('inventory.movement.recorded',p_tenant_id,p_branch_id,movement_id,actor_id,jsonb_build_object('item_id',p_item_id,'movement_type',p_movement_type,'quantity',p_quantity,'balance_after',balance_after));
  return next;
end;
$function$;


create function public.operational_list_catalog_items(p_tenant_id uuid, p_search text default null, p_item_type text default null, p_status text default null, p_limit integer default 50, p_offset integer default 0)
returns table (item_id uuid, item_type text, code text, name text, category text, unit_of_measure text, current_cost numeric, selling_price numeric, minimum_stock numeric, reorder_point numeric, status text, created_at timestamptz)
language plpgsql stable security definer set search_path = '' set row_security = off as $function$
begin
  perform app_private.assert_operational_permission(p_tenant_id, 'transaction.masterdata.catalog.read');
  if p_limit not between 1 and 100 or p_offset < 0 or p_item_type not in ('product','service') and p_item_type is not null or p_status not in ('active','inactive') and p_status is not null then raise exception 'Invalid catalog listing request' using errcode = '22023'; end if;
  return query select i.id,i.item_type,i.code,i.name,i.category,i.unit_of_measure,i.current_cost,i.selling_price,i.minimum_stock,i.reorder_point,i.status,i.created_at
    from public.catalog_items i where i.tenant_id=p_tenant_id
      and (p_search is null or i.code ilike '%' || btrim(p_search) || '%' or i.name ilike '%' || btrim(p_search) || '%')
      and (p_item_type is null or i.item_type=p_item_type) and (p_status is null or i.status=p_status)
    order by i.name,i.id limit p_limit offset p_offset;
end;
$function$;

create function public.operational_update_catalog_item_cost(p_tenant_id uuid, p_item_id uuid, p_current_cost numeric, p_request_id uuid)
returns numeric language plpgsql volatile security definer set search_path = '' set row_security = off as $function$
declare actor_id uuid; prior_cost numeric; item_type_value text;
begin
  if coalesce(auth.role(), '') <> 'authenticated' or auth.uid() is null then raise exception 'Authenticated session required' using errcode='42501'; end if;
  perform app_private.assert_operational_permission(p_tenant_id, 'transaction.masterdata.catalog.read');
  if p_item_id is null or p_request_id is null or p_current_cost is null or p_current_cost < 0 then raise exception 'Invalid catalog cost update request' using errcode = '22023'; end if;
  perform pg_advisory_xact_lock(hashtextextended('catalog-cost:' || p_tenant_id::text || ':' || p_item_id::text,0));
  select i.current_cost,i.item_type into prior_cost,item_type_value from public.catalog_items i where i.tenant_id=p_tenant_id and i.id=p_item_id for update;
  if not found then raise exception 'Catalog item not found in this company' using errcode = 'P0002'; end if;
  actor_id := app_private.assert_operational_permission(p_tenant_id, case when item_type_value='product' then 'transaction.masterdata.catalog.product.manage' else 'transaction.masterdata.catalog.service.manage' end);
  if prior_cost is distinct from p_current_cost then
    update public.catalog_items set current_cost=p_current_cost, updated_at=clock_timestamp() where tenant_id=p_tenant_id and id=p_item_id;
    insert into public.catalog_item_cost_history (tenant_id,item_id,previous_cost,new_cost,changed_by_user_id) values (p_tenant_id,p_item_id,prior_cost,p_current_cost,actor_id);
    perform app_private.write_operational_audit('catalog_item.cost_changed',p_tenant_id,null,p_item_id,actor_id,jsonb_build_object('previous_cost',prior_cost,'new_cost',p_current_cost,'request_id',p_request_id));
  end if;
  return p_current_cost;
end;
$function$;

create function public.operational_list_inventory_balances(p_tenant_id uuid, p_branch_id uuid, p_search text default null, p_limit integer default 50, p_offset integer default 0)
returns table (item_id uuid, code text, name text, quantity numeric, minimum_stock numeric, reorder_point numeric, below_reorder_point boolean)
language plpgsql stable security definer set search_path = '' set row_security = off as $function$
begin
  perform app_private.assert_operational_permission(p_tenant_id, 'transaction.inventory.stock.read', p_branch_id);
  if p_limit not between 1 and 100 or p_offset < 0 then raise exception 'Invalid inventory listing request' using errcode = '22023'; end if;
  return query select i.id,i.code,i.name,coalesce(b.quantity,0),i.minimum_stock,i.reorder_point,(coalesce(b.quantity,0) <= i.reorder_point)
    from public.catalog_items i left join public.inventory_balances b on b.tenant_id=i.tenant_id and b.branch_id=p_branch_id and b.item_id=i.id
    where i.tenant_id=p_tenant_id and i.item_type='product' and i.status='active'
      and (p_search is null or i.code ilike '%' || btrim(p_search) || '%' or i.name ilike '%' || btrim(p_search) || '%')
    order by i.name,i.id limit p_limit offset p_offset;
end;
$function$;

alter function app_private.assert_operational_permission(uuid,text,uuid) owner to postgres;
alter function app_private.write_operational_audit(text,uuid,uuid,uuid,uuid,jsonb) owner to postgres;
alter function public.operational_list_business_parties(uuid,text,text,text,integer,integer) owner to postgres;
alter function public.operational_create_business_party(uuid,text,text,text,text,text,jsonb,uuid) owner to postgres;
alter function public.operational_create_catalog_item(uuid,text,text,text,text,text,text,text,text,text,uuid,numeric,numeric,numeric,numeric,numeric,numeric,integer,numeric,uuid) owner to postgres;
alter function public.operational_update_business_party(uuid,uuid,text,text,text,jsonb,uuid) owner to postgres;
alter function public.operational_set_business_party_status(uuid,uuid,text,uuid) owner to postgres;
alter function public.operational_update_catalog_item(uuid,uuid,text,text,text,numeric,numeric,numeric,text,uuid) owner to postgres;
alter function public.operational_set_catalog_item_status(uuid,uuid,text,uuid) owner to postgres;
alter function public.operational_record_inventory_movement(uuid,uuid,uuid,text,numeric,uuid,text) owner to postgres;
alter function public.operational_list_catalog_items(uuid,text,text,text,integer,integer) owner to postgres;
alter function public.operational_update_catalog_item_cost(uuid,uuid,numeric,uuid) owner to postgres;
alter function public.operational_list_inventory_balances(uuid,uuid,text,integer,integer) owner to postgres;
revoke all on function app_private.assert_operational_permission(uuid,text,uuid), app_private.write_operational_audit(text,uuid,uuid,uuid,uuid,jsonb) from public,anon,authenticated,service_role;
revoke all on function public.operational_list_business_parties(uuid,text,text,text,integer,integer), public.operational_create_business_party(uuid,text,text,text,text,text,jsonb,uuid), public.operational_create_catalog_item(uuid,text,text,text,text,text,text,text,text,text,uuid,numeric,numeric,numeric,numeric,numeric,numeric,integer,numeric,uuid), public.operational_update_business_party(uuid,uuid,text,text,text,jsonb,uuid), public.operational_set_business_party_status(uuid,uuid,text,uuid), public.operational_update_catalog_item(uuid,uuid,text,text,text,numeric,numeric,numeric,text,uuid), public.operational_set_catalog_item_status(uuid,uuid,text,uuid), public.operational_record_inventory_movement(uuid,uuid,uuid,text,numeric,uuid,text), public.operational_list_catalog_items(uuid,text,text,text,integer,integer), public.operational_update_catalog_item_cost(uuid,uuid,numeric,uuid), public.operational_list_inventory_balances(uuid,uuid,text,integer,integer) from public,anon,authenticated,service_role;
grant execute on function public.operational_list_business_parties(uuid,text,text,text,integer,integer), public.operational_create_business_party(uuid,text,text,text,text,text,jsonb,uuid), public.operational_create_catalog_item(uuid,text,text,text,text,text,text,text,text,text,uuid,numeric,numeric,numeric,numeric,numeric,numeric,integer,numeric,uuid), public.operational_update_business_party(uuid,uuid,text,text,text,jsonb,uuid), public.operational_set_business_party_status(uuid,uuid,text,uuid), public.operational_update_catalog_item(uuid,uuid,text,text,text,numeric,numeric,numeric,text,uuid), public.operational_set_catalog_item_status(uuid,uuid,text,uuid), public.operational_record_inventory_movement(uuid,uuid,uuid,text,numeric,uuid,text), public.operational_list_catalog_items(uuid,text,text,text,integer,integer), public.operational_update_catalog_item_cost(uuid,uuid,numeric,uuid), public.operational_list_inventory_balances(uuid,uuid,text,integer,integer) to authenticated;

commit;
