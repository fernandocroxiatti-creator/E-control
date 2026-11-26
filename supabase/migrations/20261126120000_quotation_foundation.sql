begin;

-- Phase 03: quotations are commercial snapshots only. This migration creates
-- neither inventory reservations nor financial, fiscal, sales, or cash facts.
do $preflight$
begin
  if current_user <> 'postgres' then raise exception 'Apply this migration as postgres'; end if;
  if pg_catalog.to_regclass('public.business_parties') is null
     or pg_catalog.to_regclass('public.catalog_items') is null
     or pg_catalog.to_regprocedure('app_private.assert_operational_permission(uuid,text,uuid)') is null
     or pg_catalog.to_regprocedure('app_private.write_operational_audit(text,uuid,uuid,uuid,uuid,jsonb)') is null then
    raise exception 'Operational authorization and master-data foundations are required';
  end if;
end;
$preflight$;

insert into public.permission_definitions(permission_key,description) values
  ('transaction.quotation.create','Transação ZQT01: criar orçamento por empresa e filial.'),
  ('transaction.quotation.manage','Transação ZQT02: alterar orçamento em rascunho por empresa e filial.'),
  ('transaction.quotation.read','Transação ZQT03: consultar orçamentos por empresa e filial.'),
  ('transaction.quotation.approve','Transação ZQT04: aprovar ou reprovar orçamento por empresa e filial.')
on conflict(permission_key) do nothing;

insert into public.erp_transaction_authorization_catalog(transaction_code,module_code,permission_key) values
  ('ZQT01','BUD','transaction.quotation.create'),
  ('ZQT02','BUD','transaction.quotation.manage'),
  ('ZQT03','BUD','transaction.quotation.read'),
  ('ZQT04','BUD','transaction.quotation.approve')
on conflict(transaction_code) do nothing;

create sequence public.quotation_number_seq;
alter sequence public.quotation_number_seq owner to postgres;
revoke all on sequence public.quotation_number_seq from public,anon,authenticated,service_role;

create table public.quotations (
  id uuid primary key default pg_catalog.gen_random_uuid(),
  tenant_id uuid not null references public.companies(id) on delete restrict,
  branch_id uuid not null,
  quotation_number bigint not null default nextval('public.quotation_number_seq'),
  customer_id uuid not null,
  status text not null default 'draft' check(status in ('draft','approved','rejected','cancelled')),
  valid_until date,
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
  unique(tenant_id,id), unique(tenant_id,quotation_number), unique(tenant_id,request_id),
  foreign key(tenant_id,branch_id) references public.branches(tenant_id,id) on delete restrict,
  foreign key(tenant_id,customer_id) references public.business_parties(tenant_id,id) on delete restrict,
  check((status in ('approved','rejected') and decided_at is not null and decided_by_user_id is not null) or (status in ('draft','cancelled') and decided_at is null and decided_by_user_id is null))
);
create table public.quotation_lines (
  id uuid primary key default pg_catalog.gen_random_uuid(),
  tenant_id uuid not null,
  quotation_id uuid not null,
  line_number integer not null check(line_number > 0),
  item_id uuid not null,
  item_type text not null check(item_type in ('product','service')),
  item_code text not null,
  item_name text not null,
  unit_of_measure text not null,
  quantity numeric(18,4) not null check(quantity > 0),
  unit_cost_snapshot numeric(24,8) not null check(unit_cost_snapshot >= 0),
  unit_price numeric(24,8) not null check(unit_price >= 0),
  discount_percent numeric(9,4) not null default 0 check(discount_percent >= 0 and discount_percent <= 100),
  line_subtotal numeric(24,8) not null check(line_subtotal >= 0),
  line_discount numeric(24,8) not null check(line_discount >= 0),
  line_total numeric(24,8) not null check(line_total >= 0),
  unique(tenant_id,quotation_id,line_number),
  foreign key(tenant_id,quotation_id) references public.quotations(tenant_id,id) on delete restrict,
  foreign key(tenant_id,item_id) references public.catalog_items(tenant_id,id) on delete restrict
);
create table public.quotation_events (
  id uuid primary key default pg_catalog.gen_random_uuid(), tenant_id uuid not null, branch_id uuid not null,
  quotation_id uuid not null, event_key text not null check(event_key ~ '^[a-z0-9._-]{3,100}$'),
  actor_user_id uuid not null references auth.users(id) on delete restrict, details jsonb not null default '{}'::jsonb check(pg_catalog.jsonb_typeof(details)='object'),
  created_at timestamptz not null default pg_catalog.clock_timestamp(),
  foreign key(tenant_id,quotation_id) references public.quotations(tenant_id,id) on delete restrict
);
create table public.quotation_change_requests (
  id uuid primary key default pg_catalog.gen_random_uuid(),
  tenant_id uuid not null,
  quotation_id uuid not null,
  request_id uuid not null,
  actor_user_id uuid not null references auth.users(id) on delete restrict,
  request_payload jsonb not null check(pg_catalog.jsonb_typeof(request_payload)='object'),
  created_at timestamptz not null default pg_catalog.clock_timestamp(),
  unique(tenant_id,request_id),
  foreign key(tenant_id,quotation_id) references public.quotations(tenant_id,id) on delete restrict
);
create table public.quotation_decisions (
  id uuid primary key default pg_catalog.gen_random_uuid(),
  tenant_id uuid not null,
  quotation_id uuid not null,
  request_id uuid not null,
  decision text not null check(decision in ('approved','rejected')),
  reason text not null check(pg_catalog.length(reason) between 3 and 1000),
  actor_user_id uuid not null references auth.users(id) on delete restrict,
  decided_at timestamptz not null default pg_catalog.clock_timestamp(),
  unique(tenant_id,quotation_id),
  unique(tenant_id,request_id),
  foreign key(tenant_id,quotation_id) references public.quotations(tenant_id,id) on delete restrict
);
create table public.quotation_work_order_conversions (
  id uuid primary key default pg_catalog.gen_random_uuid(),
  tenant_id uuid not null,
  quotation_id uuid not null,
  work_order_id uuid not null,
  request_id uuid not null,
  actor_user_id uuid not null references auth.users(id) on delete restrict,
  created_at timestamptz not null default pg_catalog.clock_timestamp(),
  unique(tenant_id,quotation_id),
  unique(tenant_id,request_id),
  unique(tenant_id,work_order_id),
  foreign key(tenant_id,quotation_id) references public.quotations(tenant_id,id) on delete restrict,
  foreign key(tenant_id,work_order_id) references public.work_orders(tenant_id,id) on delete restrict
);
create index quotations_branch_lookup_idx on public.quotations(tenant_id,branch_id,status,created_at desc);
create index quotation_lines_lookup_idx on public.quotation_lines(tenant_id,quotation_id,line_number);

alter table public.quotations enable row level security; alter table public.quotations force row level security;
alter table public.quotation_lines enable row level security; alter table public.quotation_lines force row level security;
alter table public.quotation_events enable row level security; alter table public.quotation_events force row level security;
alter table public.quotation_change_requests enable row level security; alter table public.quotation_change_requests force row level security;
alter table public.quotation_decisions enable row level security; alter table public.quotation_decisions force row level security;
alter table public.quotation_work_order_conversions enable row level security; alter table public.quotation_work_order_conversions force row level security;
revoke all on table public.quotations,public.quotation_lines,public.quotation_events,public.quotation_change_requests,public.quotation_decisions,public.quotation_work_order_conversions from public,anon,authenticated,service_role;

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
    when p_permission_key in ('transaction.inventory.stock.read','transaction.inventory.stock.move') then array['MIGO']
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
    else null end;
  if required_codes is null then raise exception 'Operational permission is not mapped to an approved transaction' using errcode='42501'; end if;
  select count(distinct c.transaction_code) into ready_count from public.erp_transaction_authorization_catalog c join public.permission_definitions p on p.permission_key=c.permission_key and p.approval_state='approved' join public.company_module_availability m on m.tenant_id=p_tenant_id and m.module_code=c.module_code and m.enabled join public.company_transaction_availability t on t.tenant_id=p_tenant_id and t.transaction_code=c.transaction_code and t.enabled where c.transaction_code=any(required_codes) and c.approval_state='approved';
  if ready_count<>cardinality(required_codes) then raise exception 'Operational transaction is not approved or available for this company' using errcode='42501'; end if;
  return actor_id;
end;
$fn$;
alter function app_private.assert_operational_permission(uuid,text,uuid) owner to postgres;
revoke all on function app_private.assert_operational_permission(uuid,text,uuid) from public,anon,authenticated,service_role;

create function public.operational_create_quotation(p_tenant_id uuid,p_branch_id uuid,p_customer_id uuid,p_valid_until date,p_notes text,p_lines jsonb,p_request_id uuid)
returns uuid language plpgsql volatile security definer set search_path='' set row_security=off as $fn$
declare actor uuid; quote_id uuid; existing public.quotations%rowtype; row jsonb; line_no integer:=0; item public.catalog_items%rowtype; qty numeric; price numeric; discount numeric; v_subtotal numeric:=0; v_discount_total numeric:=0; payload jsonb; normalized_notes text:=nullif(pg_catalog.btrim(coalesce(p_notes,'')), '');
begin
  if p_tenant_id is null or p_branch_id is null or p_customer_id is null or p_request_id is null or pg_catalog.jsonb_typeof(p_lines) <> 'array' or pg_catalog.jsonb_array_length(p_lines) not between 1 and 100 or (p_valid_until is not null and p_valid_until < current_date) then raise exception 'Valid quotation data is required' using errcode='22023'; end if;
  actor:=app_private.assert_operational_permission(p_tenant_id,'transaction.quotation.create',p_branch_id);
  if not exists(select 1 from public.branches where tenant_id=p_tenant_id and id=p_branch_id and status='active') or not exists(select 1 from public.business_parties where tenant_id=p_tenant_id and id=p_customer_id and party_type in ('customer','both') and status='active') then raise exception 'Active branch and customer are required' using errcode='23503'; end if;
  payload:=pg_catalog.jsonb_build_object('branch_id',p_branch_id,'customer_id',p_customer_id,'valid_until',p_valid_until,'notes',normalized_notes,'lines',p_lines);
  perform pg_catalog.pg_advisory_xact_lock(pg_catalog.hashtextextended('quotation:'||p_tenant_id::text||':'||p_request_id::text,0));
  select * into existing from public.quotations where tenant_id=p_tenant_id and request_id=p_request_id;
  if found then if existing.request_payload is distinct from payload or existing.created_by_user_id is distinct from actor then raise exception 'Quotation request identifier belongs to a different payload' using errcode='23505'; end if; return existing.id; end if;
  insert into public.quotations(tenant_id,branch_id,customer_id,valid_until,notes,request_payload,request_id,created_by_user_id) values(p_tenant_id,p_branch_id,p_customer_id,p_valid_until,normalized_notes,payload,p_request_id,actor) returning id into quote_id;
  for row in select value from pg_catalog.jsonb_array_elements(p_lines) loop
    line_no:=line_no+1; qty:=(row->>'quantity')::numeric; price:=(row->>'unit_price')::numeric; discount:=coalesce((row->>'discount_percent')::numeric,0);
    if (row->>'item_id') !~* '^[0-9a-f-]{36}$' or qty is null or qty<=0 or qty<>pg_catalog.round(qty,4) or price is null or price<0 or price<>pg_catalog.round(price,8) or discount<0 or discount>100 or discount<>pg_catalog.round(discount,4) then raise exception 'Invalid quotation line' using errcode='22023'; end if;
    select * into item from public.catalog_items where tenant_id=p_tenant_id and id=(row->>'item_id')::uuid and status='active'; if not found then raise exception 'Active item in this company is required' using errcode='23503'; end if;
    insert into public.quotation_lines(tenant_id,quotation_id,line_number,item_id,item_type,item_code,item_name,unit_of_measure,quantity,unit_cost_snapshot,unit_price,discount_percent,line_subtotal,line_discount,line_total)
    values(p_tenant_id,quote_id,line_no,item.id,item.item_type,item.code,item.name,item.unit_of_measure,qty,item.current_cost,price,discount,pg_catalog.round(qty*price,8),pg_catalog.round(qty*price*discount/100,8),pg_catalog.round(qty*price*(1-discount/100),8));
  end loop;
  select coalesce(sum(line_subtotal),0),coalesce(sum(line_discount),0) into v_subtotal,v_discount_total from public.quotation_lines where tenant_id=p_tenant_id and quotation_id=quote_id;
  update public.quotations q set subtotal=v_subtotal,discount_total=v_discount_total,total_amount=v_subtotal-v_discount_total where q.tenant_id=p_tenant_id and q.id=quote_id;
  insert into public.quotation_events(tenant_id,branch_id,quotation_id,event_key,actor_user_id,details) values(p_tenant_id,p_branch_id,quote_id,'quotation.created',actor,pg_catalog.jsonb_build_object('line_count',line_no));
  perform app_private.write_operational_audit('quotation.created',p_tenant_id,p_branch_id,quote_id,actor,pg_catalog.jsonb_build_object('line_count',line_no)); return quote_id;
end;$fn$;

alter function public.operational_create_quotation(uuid,uuid,uuid,date,text,jsonb,uuid) owner to postgres;
revoke all on function public.operational_create_quotation(uuid,uuid,uuid,date,text,jsonb,uuid) from public,anon,authenticated,service_role;
grant execute on function public.operational_create_quotation(uuid,uuid,uuid,date,text,jsonb,uuid) to authenticated;

create function public.operational_update_quotation(p_tenant_id uuid,p_quotation_id uuid,p_customer_id uuid,p_valid_until date,p_notes text,p_lines jsonb,p_request_id uuid)
returns uuid language plpgsql volatile security definer set search_path='' set row_security=off as $fn$
declare actor uuid; quote public.quotations%rowtype; existing public.quotation_change_requests%rowtype; row jsonb; line_no integer:=0; item public.catalog_items%rowtype; qty numeric; price numeric; discount numeric; v_subtotal numeric:=0; v_discount_total numeric:=0; payload jsonb; normalized_notes text:=nullif(pg_catalog.btrim(coalesce(p_notes,'')), '');
begin
  if p_tenant_id is null or p_quotation_id is null or p_customer_id is null or p_request_id is null or pg_catalog.jsonb_typeof(p_lines) <> 'array' or pg_catalog.jsonb_array_length(p_lines) not between 1 and 100 or (p_valid_until is not null and p_valid_until < current_date) then raise exception 'Valid quotation data is required' using errcode='22023'; end if;
  select * into quote from public.quotations where tenant_id=p_tenant_id and id=p_quotation_id for update;
  if not found then raise exception 'Quotation not found in this company' using errcode='P0002'; end if;
  actor:=app_private.assert_operational_permission(p_tenant_id,'transaction.quotation.manage',quote.branch_id);
  payload:=pg_catalog.jsonb_build_object('customer_id',p_customer_id,'valid_until',p_valid_until,'notes',normalized_notes,'lines',p_lines);
  select * into existing from public.quotation_change_requests where tenant_id=p_tenant_id and request_id=p_request_id;
  if found then
    if existing.quotation_id is distinct from p_quotation_id or existing.request_payload is distinct from payload or existing.actor_user_id is distinct from actor then raise exception 'Quotation change request identifier belongs to a different payload' using errcode='23505'; end if;
    return p_quotation_id;
  end if;
  if quote.status <> 'draft' then raise exception 'Only draft quotations may be changed' using errcode='55000'; end if;
  if not exists(select 1 from public.business_parties where tenant_id=p_tenant_id and id=p_customer_id and party_type in ('customer','both') and status='active') then raise exception 'Active customer in this company is required' using errcode='23503'; end if;
  delete from public.quotation_lines where tenant_id=p_tenant_id and quotation_id=p_quotation_id;
  for row in select value from pg_catalog.jsonb_array_elements(p_lines) loop
    line_no:=line_no+1; qty:=(row->>'quantity')::numeric; price:=(row->>'unit_price')::numeric; discount:=coalesce((row->>'discount_percent')::numeric,0);
    if (row->>'item_id') !~* '^[0-9a-f-]{36}$' or qty is null or qty<=0 or qty<>pg_catalog.round(qty,4) or price is null or price<0 or price<>pg_catalog.round(price,8) or discount<0 or discount>100 or discount<>pg_catalog.round(discount,4) then raise exception 'Invalid quotation line' using errcode='22023'; end if;
    select * into item from public.catalog_items where tenant_id=p_tenant_id and id=(row->>'item_id')::uuid and status='active'; if not found then raise exception 'Active item in this company is required' using errcode='23503'; end if;
    insert into public.quotation_lines(tenant_id,quotation_id,line_number,item_id,item_type,item_code,item_name,unit_of_measure,quantity,unit_cost_snapshot,unit_price,discount_percent,line_subtotal,line_discount,line_total)
    values(p_tenant_id,p_quotation_id,line_no,item.id,item.item_type,item.code,item.name,item.unit_of_measure,qty,item.current_cost,price,discount,pg_catalog.round(qty*price,8),pg_catalog.round(qty*price*discount/100,8),pg_catalog.round(qty*price*(1-discount/100),8));
  end loop;
  select coalesce(sum(line_subtotal),0),coalesce(sum(line_discount),0) into v_subtotal,v_discount_total from public.quotation_lines where tenant_id=p_tenant_id and quotation_id=p_quotation_id;
  update public.quotations set customer_id=p_customer_id,valid_until=p_valid_until,notes=normalized_notes,subtotal=v_subtotal,discount_total=v_discount_total,total_amount=v_subtotal-v_discount_total,updated_at=pg_catalog.clock_timestamp() where tenant_id=p_tenant_id and id=p_quotation_id;
  insert into public.quotation_change_requests(tenant_id,quotation_id,request_id,actor_user_id,request_payload) values(p_tenant_id,p_quotation_id,p_request_id,actor,payload);
  insert into public.quotation_events(tenant_id,branch_id,quotation_id,event_key,actor_user_id,details) values(p_tenant_id,quote.branch_id,p_quotation_id,'quotation.updated',actor,pg_catalog.jsonb_build_object('line_count',line_no,'request_id',p_request_id));
  perform app_private.write_operational_audit('quotation.updated',p_tenant_id,quote.branch_id,p_quotation_id,actor,pg_catalog.jsonb_build_object('line_count',line_no));
  return p_quotation_id;
end;$fn$;

create function public.operational_get_quotation_detail(p_tenant_id uuid,p_quotation_id uuid)
returns jsonb language plpgsql stable security definer set search_path='' set row_security=off as $fn$
declare quote public.quotations%rowtype;
begin
  select * into quote from public.quotations where tenant_id=p_tenant_id and id=p_quotation_id;
  if not found then raise exception 'Quotation not found in this company' using errcode='P0002'; end if;
  perform app_private.assert_operational_permission(p_tenant_id,'transaction.quotation.read',quote.branch_id);
  return pg_catalog.jsonb_build_object(
    'id',quote.id,'quotation_number',quote.quotation_number,'branch_id',quote.branch_id,'customer_id',quote.customer_id,'status',quote.status,'valid_until',quote.valid_until,'notes',quote.notes,'subtotal',quote.subtotal,'discount_total',quote.discount_total,'total_amount',quote.total_amount,'created_at',quote.created_at,'updated_at',quote.updated_at,
    'lines',coalesce((select pg_catalog.jsonb_agg(pg_catalog.jsonb_build_object('id',l.id,'line_number',l.line_number,'item_id',l.item_id,'item_type',l.item_type,'item_code',l.item_code,'item_name',l.item_name,'unit_of_measure',l.unit_of_measure,'quantity',l.quantity,'unit_cost_snapshot',l.unit_cost_snapshot,'unit_price',l.unit_price,'discount_percent',l.discount_percent,'line_subtotal',l.line_subtotal,'line_discount',l.line_discount,'line_total',l.line_total) order by l.line_number) from public.quotation_lines l where l.tenant_id=p_tenant_id and l.quotation_id=quote.id),'[]'::jsonb),
    'events',coalesce((select pg_catalog.jsonb_agg(pg_catalog.jsonb_build_object('event_key',e.event_key,'details',e.details,'created_at',e.created_at) order by e.created_at,e.id) from public.quotation_events e where e.tenant_id=p_tenant_id and e.quotation_id=quote.id),'[]'::jsonb)
  );
end;$fn$;

create function public.operational_decide_quotation(p_tenant_id uuid,p_quotation_id uuid,p_decision text,p_reason text,p_request_id uuid)
returns text language plpgsql volatile security definer set search_path='' set row_security=off as $fn$
declare actor uuid; quote public.quotations%rowtype; existing public.quotation_decisions%rowtype; normalized_reason text:=pg_catalog.btrim(coalesce(p_reason,'')); event_key text;
begin
  if p_tenant_id is null or p_quotation_id is null or p_request_id is null or p_decision not in ('approved','rejected') or pg_catalog.length(normalized_reason) not between 3 and 1000 then raise exception 'Valid quotation decision and justification are required' using errcode='22023'; end if;
  select * into quote from public.quotations where tenant_id=p_tenant_id and id=p_quotation_id for update;
  if not found then raise exception 'Quotation not found in this company' using errcode='P0002'; end if;
  actor:=app_private.assert_operational_permission(p_tenant_id,'transaction.quotation.approve',quote.branch_id);
  select * into existing from public.quotation_decisions where tenant_id=p_tenant_id and request_id=p_request_id;
  if found then
    if existing.quotation_id is distinct from p_quotation_id or existing.decision is distinct from p_decision or existing.reason is distinct from normalized_reason or existing.actor_user_id is distinct from actor then
      raise exception 'Quotation decision request identifier belongs to a different payload' using errcode='23505';
    end if;
    return existing.decision;
  end if;
  if quote.status <> 'draft' then raise exception 'Only draft quotations may be decided' using errcode='55000'; end if;
  update public.quotations set status=p_decision,decision_reason=normalized_reason,decided_by_user_id=actor,decided_at=pg_catalog.clock_timestamp(),updated_at=pg_catalog.clock_timestamp() where tenant_id=p_tenant_id and id=p_quotation_id;
  event_key:=case when p_decision='approved' then 'quotation.approved' else 'quotation.rejected' end;
  insert into public.quotation_decisions(tenant_id,quotation_id,request_id,decision,reason,actor_user_id) values(p_tenant_id,p_quotation_id,p_request_id,p_decision,normalized_reason,actor);
  insert into public.quotation_events(tenant_id,branch_id,quotation_id,event_key,actor_user_id,details) values(p_tenant_id,quote.branch_id,p_quotation_id,event_key,actor,pg_catalog.jsonb_build_object('reason',normalized_reason,'request_id',p_request_id));
  perform app_private.write_operational_audit(event_key,p_tenant_id,quote.branch_id,p_quotation_id,actor,pg_catalog.jsonb_build_object('reason',normalized_reason));
  return p_decision;
end;$fn$;

create function public.operational_list_quotations(p_tenant_id uuid,p_branch_id uuid,p_status text default null,p_limit integer default 50,p_offset integer default 0)
returns table(quotation_id uuid,quotation_number bigint,customer_name text,status text,valid_until date,subtotal numeric,discount_total numeric,total_amount numeric,created_at timestamptz,updated_at timestamptz)
language plpgsql stable security definer set search_path='' set row_security=off as $fn$
begin
  perform app_private.assert_operational_permission(p_tenant_id,'transaction.quotation.read',p_branch_id);
  if p_limit not between 1 and 100 or p_offset<0 or (p_status is not null and p_status not in ('draft','approved','rejected','cancelled')) then raise exception 'Invalid quotation listing request' using errcode='22023'; end if;
  return query select q.id,q.quotation_number,c.legal_name,q.status,q.valid_until,q.subtotal,q.discount_total,q.total_amount,q.created_at,q.updated_at from public.quotations q join public.business_parties c on c.tenant_id=q.tenant_id and c.id=q.customer_id where q.tenant_id=p_tenant_id and q.branch_id=p_branch_id and (p_status is null or q.status=p_status) order by q.created_at desc,q.id desc limit p_limit offset p_offset;
end;$fn$;

create function public.operational_convert_quotation_to_work_order(p_tenant_id uuid,p_quotation_id uuid,p_equipment_description text,p_problem_description text,p_request_id uuid)
returns uuid language plpgsql volatile security definer set search_path='' set row_security=off as $fn$
declare actor uuid; quote public.quotations%rowtype; existing public.quotation_work_order_conversions%rowtype; work_order_id uuid; os_lines jsonb; normalized_equipment text:=nullif(pg_catalog.btrim(coalesce(p_equipment_description,'')), ''); normalized_problem text:=pg_catalog.btrim(coalesce(p_problem_description,''));
begin
  if p_tenant_id is null or p_quotation_id is null or p_request_id is null or pg_catalog.length(normalized_problem) not between 1 and 4000 or (normalized_equipment is not null and pg_catalog.length(normalized_equipment)>500) then raise exception 'Valid conversion data is required' using errcode='22023'; end if;
  select * into quote from public.quotations where tenant_id=p_tenant_id and id=p_quotation_id for update;
  if not found then raise exception 'Quotation not found in this company' using errcode='P0002'; end if;
  actor:=app_private.assert_operational_permission(p_tenant_id,'transaction.quotation.read',quote.branch_id);
  perform app_private.assert_operational_permission(p_tenant_id,'transaction.service_order.create',quote.branch_id);
  perform app_private.assert_operational_permission(p_tenant_id,'transaction.service_order.update',quote.branch_id);
  select * into existing from public.quotation_work_order_conversions where tenant_id=p_tenant_id and request_id=p_request_id;
  if found then
    if existing.quotation_id is distinct from p_quotation_id or existing.actor_user_id is distinct from actor then raise exception 'Quotation conversion request identifier belongs to a different payload' using errcode='23505'; end if;
    return existing.work_order_id;
  end if;
  if quote.status <> 'approved' or (quote.valid_until is not null and quote.valid_until < current_date) then raise exception 'Only an unexpired approved quotation may be converted' using errcode='55000'; end if;
  if exists(select 1 from public.quotation_work_order_conversions where tenant_id=p_tenant_id and quotation_id=p_quotation_id) then raise exception 'Quotation has already been converted to a work order' using errcode='55000'; end if;
  select pg_catalog.jsonb_agg(pg_catalog.jsonb_build_object('line_type',case when l.item_type='product' then 'part' else 'service' end,'item_id',l.item_id,'quantity',l.quantity,'unit_price',l.unit_price,'discount_amount',l.line_discount) order by l.line_number) into os_lines from public.quotation_lines l where l.tenant_id=p_tenant_id and l.quotation_id=p_quotation_id;
  if os_lines is null or pg_catalog.jsonb_array_length(os_lines)=0 then raise exception 'Quotation requires at least one line' using errcode='23514'; end if;
  work_order_id:=public.operational_create_work_order(p_tenant_id,quote.branch_id,quote.customer_id,normalized_equipment,normalized_problem,p_request_id);
  perform public.operational_update_work_order(p_tenant_id,work_order_id,null,os_lines,p_request_id);
  insert into public.quotation_work_order_conversions(tenant_id,quotation_id,work_order_id,request_id,actor_user_id) values(p_tenant_id,p_quotation_id,work_order_id,p_request_id,actor);
  insert into public.quotation_events(tenant_id,branch_id,quotation_id,event_key,actor_user_id,details) values(p_tenant_id,quote.branch_id,p_quotation_id,'quotation.converted_to_work_order',actor,pg_catalog.jsonb_build_object('work_order_id',work_order_id));
  perform app_private.write_operational_audit('quotation.converted_to_work_order',p_tenant_id,quote.branch_id,p_quotation_id,actor,pg_catalog.jsonb_build_object('work_order_id',work_order_id));
  return work_order_id;
end;$fn$;

alter function public.operational_decide_quotation(uuid,uuid,text,text,uuid) owner to postgres;
alter function public.operational_list_quotations(uuid,uuid,text,integer,integer) owner to postgres;
alter function public.operational_update_quotation(uuid,uuid,uuid,date,text,jsonb,uuid) owner to postgres;
alter function public.operational_get_quotation_detail(uuid,uuid) owner to postgres;
alter function public.operational_convert_quotation_to_work_order(uuid,uuid,text,text,uuid) owner to postgres;
revoke all on function public.operational_decide_quotation(uuid,uuid,text,text,uuid),public.operational_list_quotations(uuid,uuid,text,integer,integer),public.operational_update_quotation(uuid,uuid,uuid,date,text,jsonb,uuid),public.operational_get_quotation_detail(uuid,uuid),public.operational_convert_quotation_to_work_order(uuid,uuid,text,text,uuid) from public,anon,authenticated,service_role;
grant execute on function public.operational_decide_quotation(uuid,uuid,text,text,uuid),public.operational_list_quotations(uuid,uuid,text,integer,integer),public.operational_update_quotation(uuid,uuid,uuid,date,text,jsonb,uuid),public.operational_get_quotation_detail(uuid,uuid),public.operational_convert_quotation_to_work_order(uuid,uuid,text,text,uuid) to authenticated;
commit;
