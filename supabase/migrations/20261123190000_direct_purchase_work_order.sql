begin;

-- Phase 02: a direct purchase is an auditable O.S. cost fact. It is deliberately
-- not an inventory receipt, balance movement, reservation or financial posting.
do $preflight$
begin
  if current_user <> 'postgres' then raise exception 'Apply this migration as postgres'; end if;
  if pg_catalog.to_regclass('public.work_orders') is null
     or pg_catalog.to_regclass('public.work_order_events') is null
     or pg_catalog.to_regprocedure('app_private.assert_operational_permission(uuid,text,uuid)') is null
     or pg_catalog.to_regprocedure('app_private.write_operational_audit(text,uuid,uuid,uuid,uuid,jsonb)') is null then
    raise exception 'Work-order authorization foundation is required';
  end if;
end;
$preflight$;

alter table public.work_orders
  add column if not exists direct_purchase_total numeric(24,8) not null default 0
  check (direct_purchase_total >= 0);

create table public.work_order_direct_purchases (
  id uuid primary key default pg_catalog.gen_random_uuid(),
  tenant_id uuid not null references public.companies(id) on delete restrict,
  branch_id uuid not null,
  work_order_id uuid not null,
  supplier_id uuid,
  item_id uuid,
  item_description text not null check (pg_catalog.length(pg_catalog.btrim(item_description)) between 1 and 500),
  quantity numeric(18,4) not null check (quantity > 0),
  unit_cost numeric(24,8) not null check (unit_cost >= 0),
  total_cost numeric(24,8) not null check (total_cost >= 0),
  acquisition_source text not null check (pg_catalog.length(pg_catalog.btrim(acquisition_source)) between 1 and 80),
  document_reference text,
  notes text,
  request_payload jsonb not null check (pg_catalog.jsonb_typeof(request_payload)='object'),
  request_id uuid not null,
  created_by_user_id uuid not null references auth.users(id) on delete restrict,
  created_at timestamptz not null default pg_catalog.clock_timestamp(),
  unique (tenant_id,id),
  unique (tenant_id,request_id),
  foreign key (tenant_id,branch_id) references public.branches(tenant_id,id) on delete restrict,
  foreign key (tenant_id,work_order_id) references public.work_orders(tenant_id,id) on delete restrict,
  foreign key (tenant_id,supplier_id) references public.business_parties(tenant_id,id) on delete restrict,
  foreign key (tenant_id,item_id) references public.catalog_items(tenant_id,id) on delete restrict
);
create index work_order_direct_purchases_branch_order_idx on public.work_order_direct_purchases(tenant_id,branch_id,work_order_id,created_at desc);

alter table public.work_order_direct_purchases owner to postgres;
alter table public.work_order_direct_purchases enable row level security;
alter table public.work_order_direct_purchases force row level security;
revoke all on table public.work_order_direct_purchases from public, anon, authenticated, service_role;

create function public.operational_record_work_order_direct_purchase(
  p_tenant_id uuid,
  p_work_order_id uuid,
  p_supplier_id uuid,
  p_item_id uuid,
  p_item_description text,
  p_quantity numeric,
  p_unit_cost numeric,
  p_acquisition_source text,
  p_document_reference text,
  p_notes text,
  p_request_id uuid
)
returns uuid
language plpgsql volatile security definer
set search_path = '' set row_security = off
as $fn$
declare
  actor uuid;
  branch uuid;
  current_status text;
  direct_purchase_id uuid;
  existing public.work_order_direct_purchases%rowtype;
  normalized_description text := pg_catalog.btrim(coalesce(p_item_description,''));
  normalized_source text := pg_catalog.btrim(coalesce(p_acquisition_source,''));
  normalized_reference text := nullif(pg_catalog.btrim(coalesce(p_document_reference,'')), '');
  normalized_notes text := nullif(pg_catalog.btrim(coalesce(p_notes,'')), '');
  normalized_payload jsonb;
  calculated_total numeric(24,8);
begin
  if p_tenant_id is null or p_work_order_id is null or p_request_id is null
     or p_quantity is null or p_quantity <= 0 or p_unit_cost is null or p_unit_cost < 0
     or p_quantity <> pg_catalog.round(p_quantity,4) or p_unit_cost <> pg_catalog.round(p_unit_cost,8)
     or pg_catalog.length(normalized_description) not between 1 and 500
     or pg_catalog.length(normalized_source) not between 1 and 80
     or (normalized_notes is not null and pg_catalog.length(normalized_notes)>1000)
     or (normalized_reference is not null and pg_catalog.length(normalized_reference)>120) then
    raise exception 'Valid direct-purchase quantity, cost, description and source are required' using errcode='22023';
  end if;
  calculated_total := pg_catalog.round(p_quantity * p_unit_cost,8);
  normalized_payload := pg_catalog.jsonb_build_object(
    'work_order_id',p_work_order_id,'supplier_id',p_supplier_id,'item_id',p_item_id,
    'item_description',normalized_description,'quantity',p_quantity,'unit_cost',p_unit_cost,
    'acquisition_source',normalized_source,'document_reference',normalized_reference,'notes',normalized_notes
  );
  select branch_id,status into branch,current_status from public.work_orders
    where tenant_id=p_tenant_id and id=p_work_order_id for update;
  if not found then raise exception 'Open work order in this company is required' using errcode='P0002'; end if;
  actor := app_private.assert_operational_permission(p_tenant_id,'transaction.service_order.update',branch);
  perform pg_catalog.pg_advisory_xact_lock(pg_catalog.hashtextextended('work-order-direct-purchase:'||p_tenant_id::text||':'||p_request_id::text,0));
  select * into existing from public.work_order_direct_purchases where tenant_id=p_tenant_id and request_id=p_request_id;
  if found then
    if existing.request_payload is distinct from normalized_payload
       or existing.work_order_id is distinct from p_work_order_id
       or existing.created_by_user_id is distinct from actor then
      raise exception 'Direct-purchase request identifier belongs to a different payload' using errcode='23505';
    end if;
    return existing.id;
  end if;
  if current_status not in ('open','in_progress') then raise exception 'Direct purchases are blocked after work-order closing' using errcode='55000'; end if;
  if not exists(select 1 from public.branches where tenant_id=p_tenant_id and id=branch and status='active') then raise exception 'Active work-order branch is required' using errcode='23503'; end if;
  if p_supplier_id is not null and not exists(select 1 from public.business_parties where tenant_id=p_tenant_id and id=p_supplier_id and party_type in ('supplier','both') and status='active') then raise exception 'Active supplier in this company is required' using errcode='23503'; end if;
  if p_item_id is not null and not exists(select 1 from public.catalog_items where tenant_id=p_tenant_id and id=p_item_id and status='active') then raise exception 'Active catalog item in this company is required' using errcode='23503'; end if;
  insert into public.work_order_direct_purchases(tenant_id,branch_id,work_order_id,supplier_id,item_id,item_description,quantity,unit_cost,total_cost,acquisition_source,document_reference,notes,request_payload,request_id,created_by_user_id)
  values(p_tenant_id,branch,p_work_order_id,p_supplier_id,p_item_id,normalized_description,p_quantity,p_unit_cost,calculated_total,normalized_source,normalized_reference,normalized_notes,normalized_payload,p_request_id,actor)
  returning id into direct_purchase_id;
  update public.work_orders set direct_purchase_total=direct_purchase_total+calculated_total,updated_at=pg_catalog.clock_timestamp()
    where tenant_id=p_tenant_id and id=p_work_order_id;
  insert into public.work_order_events(tenant_id,work_order_id,event_key,actor_user_id,details)
  values(p_tenant_id,p_work_order_id,'work_order.direct_purchase.recorded',actor,pg_catalog.jsonb_build_object('direct_purchase_id',direct_purchase_id,'quantity',p_quantity,'unit_cost',p_unit_cost,'total_cost',calculated_total));
  perform app_private.write_operational_audit('work_order.direct_purchase.recorded',p_tenant_id,branch,direct_purchase_id,actor,pg_catalog.jsonb_build_object('work_order_id',p_work_order_id,'item_id',p_item_id,'supplier_id',p_supplier_id,'quantity',p_quantity,'unit_cost',p_unit_cost,'total_cost',calculated_total));
  return direct_purchase_id;
end;
$fn$;

create function public.operational_list_work_order_direct_purchases(
  p_tenant_id uuid,p_branch_id uuid,p_work_order_id uuid default null,p_limit integer default 100,p_offset integer default 0
)
returns table(direct_purchase_id uuid,work_order_id uuid,item_id uuid,item_description text,quantity numeric,unit_cost numeric,total_cost numeric,supplier_name text,acquisition_source text,document_reference text,notes text,created_at timestamptz)
language plpgsql stable security definer
set search_path = '' set row_security = off
as $fn$
begin
  perform app_private.assert_operational_permission(p_tenant_id,'transaction.service_order.read',p_branch_id);
  if p_limit not between 1 and 100 or p_offset<0 then raise exception 'Invalid direct-purchase listing request' using errcode='22023'; end if;
  return query
  select dp.id,dp.work_order_id,dp.item_id,dp.item_description,dp.quantity,dp.unit_cost,dp.total_cost,supplier.legal_name,dp.acquisition_source,dp.document_reference,dp.notes,dp.created_at
  from public.work_order_direct_purchases dp
  left join public.business_parties supplier on supplier.tenant_id=dp.tenant_id and supplier.id=dp.supplier_id
  where dp.tenant_id=p_tenant_id and dp.branch_id=p_branch_id and (p_work_order_id is null or dp.work_order_id=p_work_order_id)
  order by dp.created_at desc,dp.id desc limit p_limit offset p_offset;
end;
$fn$;

create function public.operational_list_work_order_direct_purchase_totals(p_tenant_id uuid,p_branch_id uuid)
returns table(work_order_id uuid,total_direct_cost numeric)
language plpgsql stable security definer
set search_path = '' set row_security = off
as $fn$
begin
  perform app_private.assert_operational_permission(p_tenant_id,'transaction.service_order.read',p_branch_id);
  return query
  select o.id,o.direct_purchase_total
    from public.work_orders o
   where o.tenant_id=p_tenant_id and o.branch_id=p_branch_id
   order by o.created_at desc,o.id desc;
end;
$fn$;

create or replace function public.operational_list_work_orders(p_tenant_id uuid,p_branch_id uuid,p_status text default null,p_limit integer default 50,p_offset integer default 0)
returns table(work_order_id uuid,order_number bigint,customer_name text,status text,total_amount numeric,created_at timestamptz,updated_at timestamptz)
language plpgsql stable security definer set search_path='' set row_security=off as $fn$
begin
  perform app_private.assert_operational_permission(p_tenant_id,'transaction.service_order.read',p_branch_id);
  if p_limit not between 1 and 100 or p_offset<0 or (p_status is not null and p_status not in ('open','in_progress','closed','cancelled','reversed')) then raise exception 'Invalid work order listing request' using errcode='22023'; end if;
  return query select o.id,o.order_number,c.legal_name,o.status,o.total_amount,o.created_at,o.updated_at from public.work_orders o join public.business_parties c on c.tenant_id=o.tenant_id and c.id=o.customer_id where o.tenant_id=p_tenant_id and o.branch_id=p_branch_id and (p_status is null or o.status=p_status) order by o.created_at desc,o.id desc limit p_limit offset p_offset;
end;
$fn$;

alter function public.operational_record_work_order_direct_purchase(uuid,uuid,uuid,uuid,text,numeric,numeric,text,text,text,uuid) owner to postgres;
alter function public.operational_list_work_order_direct_purchases(uuid,uuid,uuid,integer,integer) owner to postgres;
alter function public.operational_list_work_order_direct_purchase_totals(uuid,uuid) owner to postgres;
alter function public.operational_list_work_orders(uuid,uuid,text,integer,integer) owner to postgres;
revoke all on function public.operational_record_work_order_direct_purchase(uuid,uuid,uuid,uuid,text,numeric,numeric,text,text,text,uuid),public.operational_list_work_order_direct_purchases(uuid,uuid,uuid,integer,integer),public.operational_list_work_order_direct_purchase_totals(uuid,uuid) from public,anon,authenticated,service_role;
grant execute on function public.operational_record_work_order_direct_purchase(uuid,uuid,uuid,uuid,text,numeric,numeric,text,text,text,uuid),public.operational_list_work_order_direct_purchases(uuid,uuid,uuid,integer,integer),public.operational_list_work_order_direct_purchase_totals(uuid,uuid) to authenticated;

do $verify$
begin
  if pg_catalog.has_table_privilege('authenticated','public.work_order_direct_purchases','select')
     or pg_catalog.has_function_privilege('anon','public.operational_record_work_order_direct_purchase(uuid,uuid,uuid,uuid,text,numeric,numeric,text,text,text,uuid)','execute')
     or pg_catalog.has_function_privilege('service_role','public.operational_record_work_order_direct_purchase(uuid,uuid,uuid,uuid,text,numeric,numeric,text,text,text,uuid)','execute') then
    raise exception 'Direct-purchase access is not closed';
  end if;
end;
$verify$;

commit;
