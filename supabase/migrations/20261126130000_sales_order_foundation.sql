begin;

-- Phase 04: sales orders are commercial commitments only.  Inventory, fiscal,
-- receivable, cash and payment facts remain outside this package.
do $preflight$
begin
  if current_user <> 'postgres' then raise exception 'Apply this migration as postgres'; end if;
  if pg_catalog.to_regclass('public.quotations') is null
     or pg_catalog.to_regclass('public.quotation_lines') is null
     or pg_catalog.to_regprocedure('app_private.assert_operational_permission(uuid,text,uuid)') is null
     or pg_catalog.to_regprocedure('app_private.write_operational_audit(text,uuid,uuid,uuid,uuid,jsonb)') is null then
    raise exception 'Quotation and operational authorization foundations are required';
  end if;
  if pg_catalog.to_regclass('public.sales_orders') is not null then
    raise exception 'Sales-order foundation already exists; inspect before applying';
  end if;
end;
$preflight$;

insert into public.permission_definitions(permission_key,description) values
  ('transaction.sales.order.create','Transação ZVE01: criar pedido de venda por empresa e filial.'),
  ('transaction.sales.order.manage','Transação ZVE02: alterar pedido de venda em rascunho por empresa e filial.'),
  ('transaction.sales.order.read','Transação ZVE03: consultar pedidos de venda por empresa e filial.'),
  ('transaction.sales.order.decide','Transação ZVE04: confirmar ou cancelar pedido de venda por empresa e filial.')
on conflict(permission_key) do nothing;

insert into public.erp_transaction_authorization_catalog(transaction_code,module_code,permission_key) values
  ('ZVE01','SAL','transaction.sales.order.create'),
  ('ZVE02','SAL','transaction.sales.order.manage'),
  ('ZVE03','SAL','transaction.sales.order.read'),
  ('ZVE04','SAL','transaction.sales.order.decide')
on conflict(transaction_code) do nothing;

create sequence public.sales_order_number_seq;
alter sequence public.sales_order_number_seq owner to postgres;
revoke all on sequence public.sales_order_number_seq from public,anon,authenticated,service_role;

create table public.sales_orders (
  id uuid primary key default pg_catalog.gen_random_uuid(),
  tenant_id uuid not null references public.companies(id) on delete restrict,
  branch_id uuid not null,
  sales_order_number bigint not null default nextval('public.sales_order_number_seq'),
  customer_id uuid not null,
  source_quotation_id uuid,
  status text not null default 'draft' check(status in ('draft','confirmed','cancelled')),
  notes text,
  subtotal numeric(24,8) not null default 0 check(subtotal >= 0),
  discount_total numeric(24,8) not null default 0 check(discount_total >= 0),
  total_amount numeric(24,8) not null default 0 check(total_amount >= 0),
  request_payload jsonb not null check(pg_catalog.jsonb_typeof(request_payload)='object'),
  request_id uuid not null,
  created_by_user_id uuid not null references auth.users(id) on delete restrict,
  decided_by_user_id uuid references auth.users(id) on delete restrict,
  decision_reason text,
  decided_at timestamptz,
  created_at timestamptz not null default pg_catalog.clock_timestamp(),
  updated_at timestamptz not null default pg_catalog.clock_timestamp(),
  unique(tenant_id,id), unique(tenant_id,sales_order_number), unique(tenant_id,request_id),
  foreign key(tenant_id,branch_id) references public.branches(tenant_id,id) on delete restrict,
  foreign key(tenant_id,customer_id) references public.business_parties(tenant_id,id) on delete restrict,
  foreign key(tenant_id,source_quotation_id) references public.quotations(tenant_id,id) on delete restrict,
  check((status='confirmed' and decided_at is not null and decided_by_user_id is not null)
     or (status in ('draft','cancelled') and (decided_at is null or decided_by_user_id is not null)))
);
create table public.sales_order_lines (
  id uuid primary key default pg_catalog.gen_random_uuid(),
  tenant_id uuid not null,
  sales_order_id uuid not null,
  line_number integer not null check(line_number > 0),
  item_id uuid not null,
  item_type text not null check(item_type in ('product','service')),
  item_code text not null,
  item_name text not null,
  unit_of_measure text not null,
  quantity numeric(18,4) not null check(quantity > 0),
  unit_cost_snapshot numeric(24,8) not null check(unit_cost_snapshot >= 0),
  unit_price numeric(24,8) not null check(unit_price >= 0),
  discount_percent numeric(9,4) not null default 0 check(discount_percent between 0 and 100),
  line_subtotal numeric(24,8) not null check(line_subtotal >= 0),
  line_discount numeric(24,8) not null check(line_discount >= 0),
  line_total numeric(24,8) not null check(line_total >= 0),
  unique(tenant_id,sales_order_id,line_number),
  foreign key(tenant_id,sales_order_id) references public.sales_orders(tenant_id,id) on delete restrict,
  foreign key(tenant_id,item_id) references public.catalog_items(tenant_id,id) on delete restrict
);
create table public.sales_order_events (
  id uuid primary key default pg_catalog.gen_random_uuid(),
  tenant_id uuid not null, branch_id uuid not null, sales_order_id uuid not null,
  event_key text not null check(event_key ~ '^[a-z0-9._-]{3,100}$'),
  actor_user_id uuid not null references auth.users(id) on delete restrict,
  details jsonb not null default '{}'::jsonb check(pg_catalog.jsonb_typeof(details)='object'),
  created_at timestamptz not null default pg_catalog.clock_timestamp(),
  foreign key(tenant_id,sales_order_id) references public.sales_orders(tenant_id,id) on delete restrict
);
create table public.sales_order_mutation_requests (
  id uuid primary key default pg_catalog.gen_random_uuid(), tenant_id uuid not null, sales_order_id uuid not null,
  request_id uuid not null, operation text not null check(operation in ('update','decision','quotation_conversion')),
  actor_user_id uuid not null references auth.users(id) on delete restrict,
  request_payload jsonb not null check(pg_catalog.jsonb_typeof(request_payload)='object'), created_at timestamptz not null default pg_catalog.clock_timestamp(),
  unique(tenant_id,request_id), foreign key(tenant_id,sales_order_id) references public.sales_orders(tenant_id,id) on delete restrict
);
create table public.quotation_sales_order_conversions (
  id uuid primary key default pg_catalog.gen_random_uuid(), tenant_id uuid not null, quotation_id uuid not null,
  sales_order_id uuid not null, request_id uuid not null, actor_user_id uuid not null references auth.users(id) on delete restrict,
  created_at timestamptz not null default pg_catalog.clock_timestamp(),
  unique(tenant_id,quotation_id), unique(tenant_id,sales_order_id), unique(tenant_id,request_id),
  foreign key(tenant_id,quotation_id) references public.quotations(tenant_id,id) on delete restrict,
  foreign key(tenant_id,sales_order_id) references public.sales_orders(tenant_id,id) on delete restrict
);
create index sales_orders_branch_lookup_idx on public.sales_orders(tenant_id,branch_id,status,created_at desc);
create index sales_order_lines_lookup_idx on public.sales_order_lines(tenant_id,sales_order_id,line_number);

alter table public.sales_orders enable row level security; alter table public.sales_orders force row level security;
alter table public.sales_order_lines enable row level security; alter table public.sales_order_lines force row level security;
alter table public.sales_order_events enable row level security; alter table public.sales_order_events force row level security;
alter table public.sales_order_mutation_requests enable row level security; alter table public.sales_order_mutation_requests force row level security;
alter table public.quotation_sales_order_conversions enable row level security; alter table public.quotation_sales_order_conversions force row level security;
revoke all on table public.sales_orders,public.sales_order_lines,public.sales_order_events,public.sales_order_mutation_requests,public.quotation_sales_order_conversions from public,anon,authenticated,service_role;

-- Keep one canonical permission gateway. This preserves every prior mapping
-- and adds only the four sales transactions introduced above.
create or replace function app_private.assert_operational_permission(p_tenant_id uuid,p_permission_key text,p_branch_id uuid default null)
returns uuid language plpgsql stable security definer set search_path='' set row_security=off as $fn$
declare actor_id uuid; required_codes text[]; ready_count integer;
begin
  if coalesce(auth.role(),'')<>'authenticated' or auth.uid() is null then raise exception 'Authenticated session required' using errcode='42501'; end if;
  actor_id:=auth.uid();
  if p_tenant_id is null or p_permission_key is null or not exists(select 1 from public.companies where id=p_tenant_id and status='active') or not app_private.is_active_company_member(p_tenant_id) or (p_branch_id is not null and not app_private.can_access_branch(p_tenant_id,p_branch_id)) or not app_private.has_tenant_permission(p_tenant_id,p_permission_key,p_branch_id) or not exists(select 1 from public.permission_definitions where permission_key=p_permission_key and approval_state='approved') then raise exception 'Operational permission denied' using errcode='42501'; end if;
  required_codes:=case
    when p_permission_key in ('transaction.masterdata.party.read','transaction.masterdata.party.manage') then array['BP01']
    when p_permission_key='transaction.masterdata.catalog.read' then array['MM01','SV01']
    when p_permission_key='transaction.masterdata.catalog.product.manage' then array['MM01']
    when p_permission_key='transaction.masterdata.catalog.service.manage' then array['SV01']
    when p_permission_key='transaction.inventory.stock.read' then array['MIGO']
    when p_permission_key='transaction.purchasing.purchase_order.read' then array['ME23N']
    when p_permission_key='transaction.purchasing.purchase_order.create' then array['ME21N']
    when p_permission_key='transaction.masterdata.catalog.product.update' then array['MM02']
    when p_permission_key='transaction.masterdata.catalog.product.read' then array['MM03']
    when p_permission_key='transaction.inventory.balance.read' then array['MB52']
    when p_permission_key='transaction.inventory.history.read' then array['MB51']
    when p_permission_key='transaction.inventory.physical.create' then array['MI01']
    when p_permission_key='transaction.inventory.physical.count' then array['MI04']
    when p_permission_key='transaction.inventory.physical.adjust' then array['MI07']
    when p_permission_key='transaction.inventory.transfer' then array['ZTR01']
    when p_permission_key='transaction.service_order.create' then array['ZOS01']
    when p_permission_key='transaction.service_order.update' then array['ZOS02']
    when p_permission_key='transaction.service_order.read' then array['ZOS03']
    when p_permission_key='transaction.service_order.close' then array['ZOS04']
    when p_permission_key='transaction.purchasing.receipt.manage' then array['ZGR01']
    when p_permission_key='transaction.inventory.valuation.initial' then array['ZIV01']
    when p_permission_key='transaction.quotation.create' then array['ZQT01']
    when p_permission_key='transaction.quotation.manage' then array['ZQT02']
    when p_permission_key='transaction.quotation.read' then array['ZQT03']
    when p_permission_key='transaction.quotation.approve' then array['ZQT04']
    when p_permission_key='transaction.sales.order.create' then array['ZVE01']
    when p_permission_key='transaction.sales.order.manage' then array['ZVE02']
    when p_permission_key='transaction.sales.order.read' then array['ZVE03']
    when p_permission_key='transaction.sales.order.decide' then array['ZVE04']
    else null end;
  if required_codes is null then raise exception 'Operational permission is not mapped to an approved transaction' using errcode='42501'; end if;
  select count(distinct c.transaction_code) into ready_count from public.erp_transaction_authorization_catalog c join public.permission_definitions p on p.permission_key=c.permission_key and p.approval_state='approved' join public.company_module_availability m on m.tenant_id=p_tenant_id and m.module_code=c.module_code and m.enabled join public.company_transaction_availability t on t.tenant_id=p_tenant_id and t.transaction_code=c.transaction_code and t.enabled where c.transaction_code=any(required_codes) and c.approval_state='approved';
  if ready_count<>cardinality(required_codes) then raise exception 'Operational transaction is not approved or available for this company' using errcode='42501'; end if;
  return actor_id;
end;
$fn$;
alter function app_private.assert_operational_permission(uuid,text,uuid) owner to postgres;
revoke all on function app_private.assert_operational_permission(uuid,text,uuid) from public,anon,authenticated,service_role;

create function public.operational_create_sales_order(p_tenant_id uuid,p_branch_id uuid,p_customer_id uuid,p_notes text,p_lines jsonb,p_request_id uuid)
returns uuid language plpgsql volatile security definer set search_path='' set row_security=off as $fn$
declare actor uuid; order_id uuid; existing public.sales_orders%rowtype; row jsonb; item public.catalog_items%rowtype; n integer:=0; qty numeric; price numeric; discount numeric; v_subtotal numeric:=0; v_discount_total numeric:=0; normalized_notes text:=nullif(pg_catalog.btrim(coalesce(p_notes,'')), ''); payload jsonb;
begin
  if p_tenant_id is null or p_branch_id is null or p_customer_id is null or p_request_id is null or pg_catalog.jsonb_typeof(p_lines)<>'array' or pg_catalog.jsonb_array_length(p_lines) not between 1 and 100 then raise exception 'Valid sales-order data is required' using errcode='22023'; end if;
  actor:=app_private.assert_operational_permission(p_tenant_id,'transaction.sales.order.create',p_branch_id);
  if not exists(select 1 from public.branches where tenant_id=p_tenant_id and id=p_branch_id and status='active') or not exists(select 1 from public.business_parties where tenant_id=p_tenant_id and id=p_customer_id and party_type in ('customer','both') and status='active') then raise exception 'Active branch and customer are required' using errcode='23503'; end if;
  payload:=pg_catalog.jsonb_build_object('branch_id',p_branch_id,'customer_id',p_customer_id,'notes',normalized_notes,'lines',p_lines);
  perform pg_catalog.pg_advisory_xact_lock(pg_catalog.hashtextextended('sales-order:'||p_tenant_id::text||':'||p_request_id::text,0));
  select * into existing from public.sales_orders where tenant_id=p_tenant_id and request_id=p_request_id;
  if found then if existing.request_payload is distinct from payload or existing.created_by_user_id is distinct from actor then raise exception 'Sales-order request identifier belongs to a different payload' using errcode='23505'; end if; return existing.id; end if;
  insert into public.sales_orders(tenant_id,branch_id,customer_id,notes,request_payload,request_id,created_by_user_id) values(p_tenant_id,p_branch_id,p_customer_id,normalized_notes,payload,p_request_id,actor) returning id into order_id;
  for row in select value from pg_catalog.jsonb_array_elements(p_lines) loop
    n:=n+1; qty:=(row->>'quantity')::numeric; price:=(row->>'unit_price')::numeric; discount:=coalesce((row->>'discount_percent')::numeric,0);
    if (row->>'item_id') !~* '^[0-9a-f-]{36}$' or qty is null or qty<=0 or qty<>pg_catalog.round(qty,4) or price is null or price<0 or price<>pg_catalog.round(price,8) or discount<0 or discount>100 or discount<>pg_catalog.round(discount,4) then raise exception 'Invalid sales-order line' using errcode='22023'; end if;
    select * into item from public.catalog_items where tenant_id=p_tenant_id and id=(row->>'item_id')::uuid and status='active';
    if not found then raise exception 'Active catalog item required' using errcode='23503'; end if;
    insert into public.sales_order_lines(tenant_id,sales_order_id,line_number,item_id,item_type,item_code,item_name,unit_of_measure,quantity,unit_cost_snapshot,unit_price,discount_percent,line_subtotal,line_discount,line_total) values(p_tenant_id,order_id,n,item.id,item.item_type,item.code,item.name,item.unit_of_measure,qty,item.current_cost,price,discount,pg_catalog.round(qty*price,8),pg_catalog.round(qty*price*discount/100,8),pg_catalog.round(qty*price*(100-discount)/100,8));
  end loop;
  select coalesce(sum(line_subtotal),0),coalesce(sum(line_discount),0) into v_subtotal,v_discount_total from public.sales_order_lines where tenant_id=p_tenant_id and sales_order_id=order_id;
  update public.sales_orders set subtotal=v_subtotal,discount_total=v_discount_total,total_amount=v_subtotal-v_discount_total where tenant_id=p_tenant_id and id=order_id;
  insert into public.sales_order_events(tenant_id,branch_id,sales_order_id,event_key,actor_user_id,details) values(p_tenant_id,p_branch_id,order_id,'sales_order.created',actor,pg_catalog.jsonb_build_object('request_id',p_request_id,'line_count',n));
  perform app_private.write_operational_audit('sales_order.created',p_tenant_id,p_branch_id,order_id,actor,pg_catalog.jsonb_build_object('request_id',p_request_id,'line_count',n));
  return order_id;
end;$fn$;

create function public.operational_update_sales_order(p_tenant_id uuid,p_sales_order_id uuid,p_customer_id uuid,p_notes text,p_lines jsonb,p_request_id uuid)
returns uuid language plpgsql volatile security definer set search_path='' set row_security=off as $fn$
declare actor uuid; sale public.sales_orders%rowtype; existing public.sales_order_mutation_requests%rowtype; row jsonb; item public.catalog_items%rowtype; n integer:=0; qty numeric; price numeric; discount numeric; v_subtotal numeric:=0; v_discounts numeric:=0; normalized_notes text:=nullif(pg_catalog.btrim(coalesce(p_notes,'')), ''); payload jsonb;
begin
  if p_tenant_id is null or p_sales_order_id is null or p_customer_id is null or p_request_id is null or pg_catalog.jsonb_typeof(p_lines)<>'array' or pg_catalog.jsonb_array_length(p_lines) not between 1 and 100 then raise exception 'Valid sales-order update data is required' using errcode='22023'; end if;
  select * into sale from public.sales_orders where tenant_id=p_tenant_id and id=p_sales_order_id; if not found then raise exception 'Sales order not found in this company' using errcode='P0002'; end if;
  actor:=app_private.assert_operational_permission(p_tenant_id,'transaction.sales.order.manage',sale.branch_id);
  payload:=pg_catalog.jsonb_build_object('customer_id',p_customer_id,'notes',normalized_notes,'lines',p_lines);
  perform pg_catalog.pg_advisory_xact_lock(pg_catalog.hashtextextended('sales-order-update:'||p_tenant_id::text||':'||p_request_id::text,0));
  select * into existing from public.sales_order_mutation_requests where tenant_id=p_tenant_id and request_id=p_request_id;
  if found then if existing.sales_order_id is distinct from p_sales_order_id or existing.operation<>'update' or existing.request_payload is distinct from payload or existing.actor_user_id is distinct from actor then raise exception 'Sales-order request identifier belongs to a different payload' using errcode='23505'; end if; return p_sales_order_id; end if;
  select * into sale from public.sales_orders where tenant_id=p_tenant_id and id=p_sales_order_id for update;
  if sale.status<>'draft' or sale.source_quotation_id is not null then raise exception 'Only independent draft sales orders may be edited' using errcode='55000'; end if;
  if not exists(select 1 from public.business_parties where tenant_id=p_tenant_id and id=p_customer_id and party_type in ('customer','both') and status='active') then raise exception 'Active customer required' using errcode='23503'; end if;
  delete from public.sales_order_lines where tenant_id=p_tenant_id and sales_order_id=p_sales_order_id;
  for row in select value from pg_catalog.jsonb_array_elements(p_lines) loop
    n:=n+1; qty:=(row->>'quantity')::numeric; price:=(row->>'unit_price')::numeric; discount:=coalesce((row->>'discount_percent')::numeric,0);
    if (row->>'item_id') !~* '^[0-9a-f-]{36}$' or qty is null or qty<=0 or qty<>pg_catalog.round(qty,4) or price is null or price<0 or price<>pg_catalog.round(price,8) or discount<0 or discount>100 or discount<>pg_catalog.round(discount,4) then raise exception 'Invalid sales-order line' using errcode='22023'; end if;
    select * into item from public.catalog_items where tenant_id=p_tenant_id and id=(row->>'item_id')::uuid and status='active'; if not found then raise exception 'Active catalog item required' using errcode='23503'; end if;
    insert into public.sales_order_lines(tenant_id,sales_order_id,line_number,item_id,item_type,item_code,item_name,unit_of_measure,quantity,unit_cost_snapshot,unit_price,discount_percent,line_subtotal,line_discount,line_total) values(p_tenant_id,p_sales_order_id,n,item.id,item.item_type,item.code,item.name,item.unit_of_measure,qty,item.current_cost,price,discount,pg_catalog.round(qty*price,8),pg_catalog.round(qty*price*discount/100,8),pg_catalog.round(qty*price*(100-discount)/100,8));
  end loop;
  select coalesce(sum(line_subtotal),0),coalesce(sum(line_discount),0) into v_subtotal,v_discounts from public.sales_order_lines where tenant_id=p_tenant_id and sales_order_id=p_sales_order_id;
  update public.sales_orders set customer_id=p_customer_id,notes=normalized_notes,subtotal=v_subtotal,discount_total=v_discounts,total_amount=v_subtotal-v_discounts,updated_at=pg_catalog.clock_timestamp() where tenant_id=p_tenant_id and id=p_sales_order_id;
  insert into public.sales_order_mutation_requests(tenant_id,sales_order_id,request_id,operation,actor_user_id,request_payload) values(p_tenant_id,p_sales_order_id,p_request_id,'update',actor,payload);
  insert into public.sales_order_events(tenant_id,branch_id,sales_order_id,event_key,actor_user_id,details) values(p_tenant_id,sale.branch_id,p_sales_order_id,'sales_order.updated',actor,pg_catalog.jsonb_build_object('request_id',p_request_id,'line_count',n));
  perform app_private.write_operational_audit('sales_order.updated',p_tenant_id,sale.branch_id,p_sales_order_id,actor,pg_catalog.jsonb_build_object('request_id',p_request_id,'line_count',n));
  return p_sales_order_id;
end;$fn$;

create function public.operational_decide_sales_order(p_tenant_id uuid,p_sales_order_id uuid,p_decision text,p_reason text,p_request_id uuid)
returns text language plpgsql volatile security definer set search_path='' set row_security=off as $fn$
declare actor uuid; sale public.sales_orders%rowtype; existing public.sales_order_mutation_requests%rowtype; normalized_reason text:=nullif(pg_catalog.btrim(coalesce(p_reason,'')), ''); payload jsonb; event_key text;
begin
  if p_tenant_id is null or p_sales_order_id is null or p_request_id is null or p_decision not in ('confirmed','cancelled') or pg_catalog.length(normalized_reason) not between 3 and 1000 then raise exception 'Valid sales-order decision and reason are required' using errcode='22023'; end if;
  select * into sale from public.sales_orders where tenant_id=p_tenant_id and id=p_sales_order_id for update; if not found then raise exception 'Sales order not found in this company' using errcode='P0002'; end if;
  actor:=app_private.assert_operational_permission(p_tenant_id,'transaction.sales.order.decide',sale.branch_id);
  payload:=pg_catalog.jsonb_build_object('decision',p_decision,'reason',normalized_reason);
  perform pg_catalog.pg_advisory_xact_lock(pg_catalog.hashtextextended('sales-order-decision:'||p_tenant_id::text||':'||p_request_id::text,0));
  select * into existing from public.sales_order_mutation_requests where tenant_id=p_tenant_id and request_id=p_request_id;
  if found then if existing.sales_order_id is distinct from p_sales_order_id or existing.operation<>'decision' or existing.request_payload is distinct from payload or existing.actor_user_id is distinct from actor then raise exception 'Sales-order request identifier belongs to a different payload' using errcode='23505'; end if; return p_decision; end if;
  if sale.status<>'draft' then raise exception 'Only draft sales orders may be decided' using errcode='55000'; end if;
  update public.sales_orders set status=p_decision,decision_reason=normalized_reason,decided_by_user_id=actor,decided_at=pg_catalog.clock_timestamp(),updated_at=pg_catalog.clock_timestamp() where tenant_id=p_tenant_id and id=p_sales_order_id;
  insert into public.sales_order_mutation_requests(tenant_id,sales_order_id,request_id,operation,actor_user_id,request_payload) values(p_tenant_id,p_sales_order_id,p_request_id,'decision',actor,payload);
  event_key:=case when p_decision='confirmed' then 'sales_order.confirmed' else 'sales_order.cancelled' end;
  insert into public.sales_order_events(tenant_id,branch_id,sales_order_id,event_key,actor_user_id,details) values(p_tenant_id,sale.branch_id,p_sales_order_id,event_key,actor,pg_catalog.jsonb_build_object('reason',normalized_reason));
  perform app_private.write_operational_audit(event_key,p_tenant_id,sale.branch_id,p_sales_order_id,actor,pg_catalog.jsonb_build_object('reason',normalized_reason));
  return p_decision;
end;$fn$;

create function public.operational_convert_quotation_to_sales_order(p_tenant_id uuid,p_quotation_id uuid,p_request_id uuid)
returns uuid language plpgsql volatile security definer set search_path='' set row_security=off as $fn$
declare actor uuid; quote public.quotations%rowtype; existing public.quotation_sales_order_conversions%rowtype; order_id uuid; n integer:=0; v_subtotal numeric:=0; v_discounts numeric:=0;
begin
  if p_tenant_id is null or p_quotation_id is null or p_request_id is null then raise exception 'Valid quotation conversion data is required' using errcode='22023'; end if;
  select * into quote from public.quotations where tenant_id=p_tenant_id and id=p_quotation_id for update; if not found then raise exception 'Quotation not found in this company' using errcode='P0002'; end if;
  actor:=app_private.assert_operational_permission(p_tenant_id,'transaction.quotation.read',quote.branch_id);
  perform app_private.assert_operational_permission(p_tenant_id,'transaction.sales.order.create',quote.branch_id);
  perform pg_catalog.pg_advisory_xact_lock(pg_catalog.hashtextextended('quotation-sales-order:'||p_tenant_id::text||':'||p_request_id::text,0));
  select * into existing from public.quotation_sales_order_conversions where tenant_id=p_tenant_id and request_id=p_request_id;
  if found then if existing.quotation_id is distinct from p_quotation_id or existing.actor_user_id is distinct from actor then raise exception 'Quotation conversion request identifier belongs to a different payload' using errcode='23505'; end if; return existing.sales_order_id; end if;
  if quote.status<>'approved' or (quote.valid_until is not null and quote.valid_until<current_date) then raise exception 'Only an unexpired approved quotation may be converted' using errcode='55000'; end if;
  if exists(select 1 from public.quotation_sales_order_conversions where tenant_id=p_tenant_id and quotation_id=p_quotation_id) then raise exception 'Quotation has already been converted to a sales order' using errcode='55000'; end if;
  insert into public.sales_orders(tenant_id,branch_id,customer_id,source_quotation_id,notes,request_payload,request_id,created_by_user_id) values(p_tenant_id,quote.branch_id,quote.customer_id,p_quotation_id,quote.notes,pg_catalog.jsonb_build_object('quotation_id',p_quotation_id),p_request_id,actor) returning id into order_id;
  insert into public.sales_order_lines(tenant_id,sales_order_id,line_number,item_id,item_type,item_code,item_name,unit_of_measure,quantity,unit_cost_snapshot,unit_price,discount_percent,line_subtotal,line_discount,line_total)
    select p_tenant_id,order_id,line_number,item_id,item_type,item_code,item_name,unit_of_measure,quantity,unit_cost_snapshot,unit_price,discount_percent,line_subtotal,line_discount,line_total from public.quotation_lines where tenant_id=p_tenant_id and quotation_id=p_quotation_id order by line_number;
  select count(*),coalesce(sum(line_subtotal),0),coalesce(sum(line_discount),0) into n,v_subtotal,v_discounts from public.sales_order_lines where tenant_id=p_tenant_id and sales_order_id=order_id;
  if n=0 then raise exception 'Quotation requires at least one line' using errcode='23514'; end if;
  update public.sales_orders set subtotal=v_subtotal,discount_total=v_discounts,total_amount=v_subtotal-v_discounts where tenant_id=p_tenant_id and id=order_id;
  insert into public.quotation_sales_order_conversions(tenant_id,quotation_id,sales_order_id,request_id,actor_user_id) values(p_tenant_id,p_quotation_id,order_id,p_request_id,actor);
  insert into public.sales_order_mutation_requests(tenant_id,sales_order_id,request_id,operation,actor_user_id,request_payload) values(p_tenant_id,order_id,p_request_id,'quotation_conversion',actor,pg_catalog.jsonb_build_object('quotation_id',p_quotation_id));
  insert into public.sales_order_events(tenant_id,branch_id,sales_order_id,event_key,actor_user_id,details) values(p_tenant_id,quote.branch_id,order_id,'sales_order.created_from_quotation',actor,pg_catalog.jsonb_build_object('quotation_id',p_quotation_id,'line_count',n));
  insert into public.quotation_events(tenant_id,branch_id,quotation_id,event_key,actor_user_id,details) values(p_tenant_id,quote.branch_id,p_quotation_id,'quotation.converted_to_sales_order',actor,pg_catalog.jsonb_build_object('sales_order_id',order_id));
  perform app_private.write_operational_audit('quotation.converted_to_sales_order',p_tenant_id,quote.branch_id,p_quotation_id,actor,pg_catalog.jsonb_build_object('sales_order_id',order_id));
  perform app_private.write_operational_audit('sales_order.created_from_quotation',p_tenant_id,quote.branch_id,order_id,actor,pg_catalog.jsonb_build_object('quotation_id',p_quotation_id));
  return order_id;
end;$fn$;

create function public.operational_list_sales_orders(p_tenant_id uuid,p_branch_id uuid,p_status text default null,p_limit integer default 50,p_offset integer default 0)
returns table(sales_order_id uuid,sales_order_number bigint,customer_name text,status text,source_quotation_id uuid,subtotal numeric,discount_total numeric,total_amount numeric,created_at timestamptz,updated_at timestamptz)
language plpgsql stable security definer set search_path='' set row_security=off as $fn$
begin
  perform app_private.assert_operational_permission(p_tenant_id,'transaction.sales.order.read',p_branch_id);
  if p_limit not between 1 and 100 or p_offset<0 or (p_status is not null and p_status not in ('draft','confirmed','cancelled')) then raise exception 'Invalid sales-order listing request' using errcode='22023'; end if;
  return query select s.id,s.sales_order_number,c.legal_name,s.status,s.source_quotation_id,s.subtotal,s.discount_total,s.total_amount,s.created_at,s.updated_at from public.sales_orders s join public.business_parties c on c.tenant_id=s.tenant_id and c.id=s.customer_id where s.tenant_id=p_tenant_id and s.branch_id=p_branch_id and (p_status is null or s.status=p_status) order by s.created_at desc,s.id desc limit p_limit offset p_offset;
end;$fn$;

alter function public.operational_create_sales_order(uuid,uuid,uuid,text,jsonb,uuid) owner to postgres;
alter function public.operational_update_sales_order(uuid,uuid,uuid,text,jsonb,uuid) owner to postgres;
alter function public.operational_decide_sales_order(uuid,uuid,text,text,uuid) owner to postgres;
alter function public.operational_convert_quotation_to_sales_order(uuid,uuid,uuid) owner to postgres;
alter function public.operational_list_sales_orders(uuid,uuid,text,integer,integer) owner to postgres;
revoke all on function public.operational_create_sales_order(uuid,uuid,uuid,text,jsonb,uuid),public.operational_update_sales_order(uuid,uuid,uuid,text,jsonb,uuid),public.operational_decide_sales_order(uuid,uuid,text,text,uuid),public.operational_convert_quotation_to_sales_order(uuid,uuid,uuid),public.operational_list_sales_orders(uuid,uuid,text,integer,integer) from public,anon,authenticated,service_role;
grant execute on function public.operational_create_sales_order(uuid,uuid,uuid,text,jsonb,uuid),public.operational_update_sales_order(uuid,uuid,uuid,text,jsonb,uuid),public.operational_decide_sales_order(uuid,uuid,text,text,uuid),public.operational_convert_quotation_to_sales_order(uuid,uuid,uuid),public.operational_list_sales_orders(uuid,uuid,text,integer,integer) to authenticated;
commit;
