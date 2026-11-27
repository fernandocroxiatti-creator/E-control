begin;

-- Sales stock package: only confirmed sales can reserve/fulfil. Every stock
-- fact remains a valued inventory event; no fiscal or financial fact is made.
do $preflight$
begin
  if current_user <> 'postgres' then raise exception 'Apply this migration as postgres'; end if;
  if pg_catalog.to_regclass('public.sales_orders') is null
     or pg_catalog.to_regclass('public.inventory_balances') is null
     or pg_catalog.to_regprocedure('app_private.apply_inventory_valuation_delta(uuid,uuid,uuid,text,numeric,uuid,uuid,text,numeric,uuid)') is null then
    raise exception 'Sales and valued inventory foundations are required';
  end if;
  if pg_catalog.to_regclass('public.sales_order_inventory_reservations') is not null then
    raise exception 'Sales inventory package already exists; inspect before applying';
  end if;
end;
$preflight$;

insert into public.permission_definitions(permission_key,description) values
  ('transaction.sales.inventory.reserve','Transação ZVE05: reservar estoque para pedido de venda confirmado.'),
  ('transaction.sales.inventory.fulfill','Transação ZVE06: baixar estoque na entrega de pedido de venda.'),
  ('transaction.sales.inventory.return','Transação ZVE07: registrar devolução auditável de pedido de venda.')
on conflict(permission_key) do nothing;
insert into public.erp_transaction_authorization_catalog(transaction_code,module_code,permission_key) values
  ('ZVE05','SAL','transaction.sales.inventory.reserve'),
  ('ZVE06','SAL','transaction.sales.inventory.fulfill'),
  ('ZVE07','SAL','transaction.sales.inventory.return')
on conflict(transaction_code) do nothing;

alter table public.inventory_movements drop constraint inventory_movements_movement_type_check;
alter table public.inventory_movements add constraint inventory_movements_movement_type_check check (movement_type in (
  'initial','entry','exit','adjustment_positive','adjustment_negative','transfer_out','transfer_in','physical_count_in','physical_count_out','service_consumption','service_reversal','purchase_receipt','purchase_receipt_reversal','sales_delivery','sales_return'
));
alter table public.sales_orders drop constraint sales_orders_status_check;
alter table public.sales_orders add constraint sales_orders_status_check check(status in ('draft','confirmed','fulfilled','cancelled'));
alter table public.sales_orders drop constraint sales_orders_check;
alter table public.sales_orders add constraint sales_orders_check check(
  (status in ('confirmed','fulfilled') and decided_at is not null and decided_by_user_id is not null)
  or (status in ('draft','cancelled') and (decided_at is null or decided_by_user_id is not null))
);

create table public.sales_order_inventory_reservations (
  id uuid primary key default pg_catalog.gen_random_uuid(), tenant_id uuid not null, sales_order_id uuid not null, item_id uuid not null,
  quantity numeric(18,4) not null check(quantity>0), status text not null check(status in ('reserved','released','fulfilled','returned')),
  reserved_by_user_id uuid not null references auth.users(id) on delete restrict, reserved_at timestamptz not null default pg_catalog.clock_timestamp(),
  fulfilled_movement_id uuid references public.inventory_movements(id) on delete restrict, fulfilled_unit_cost numeric(24,8), fulfilled_value numeric(24,8), fulfilled_at timestamptz,
  returned_movement_id uuid references public.inventory_movements(id) on delete restrict, returned_at timestamptz,
  unique(tenant_id,sales_order_id,item_id), foreign key(tenant_id,sales_order_id) references public.sales_orders(tenant_id,id) on delete restrict,
  foreign key(tenant_id,item_id) references public.catalog_items(tenant_id,id) on delete restrict,
  check((status='reserved' and fulfilled_movement_id is null and returned_movement_id is null) or (status='released' and fulfilled_movement_id is null and returned_movement_id is null) or (status='fulfilled' and fulfilled_movement_id is not null and fulfilled_unit_cost is not null and fulfilled_value is not null and returned_movement_id is null) or (status='returned' and fulfilled_movement_id is not null and returned_movement_id is not null))
);
create table public.sales_order_inventory_requests (
  id uuid primary key default pg_catalog.gen_random_uuid(), tenant_id uuid not null, sales_order_id uuid not null, request_id uuid not null,
  operation text not null check(operation in ('reserve','release','fulfill','return')), actor_user_id uuid not null references auth.users(id) on delete restrict,
  request_payload jsonb not null check(pg_catalog.jsonb_typeof(request_payload)='object'), created_at timestamptz not null default pg_catalog.clock_timestamp(),
  unique(tenant_id,request_id), foreign key(tenant_id,sales_order_id) references public.sales_orders(tenant_id,id) on delete restrict
);
create table public.sales_order_inventory_returns (
  id uuid primary key default pg_catalog.gen_random_uuid(), tenant_id uuid not null, sales_order_id uuid not null, reservation_id uuid not null,
  request_id uuid not null, actor_user_id uuid not null references auth.users(id) on delete restrict, reason text not null check(pg_catalog.length(reason) between 3 and 1000),
  returned_quantity numeric(18,4) not null check(returned_quantity>0), created_at timestamptz not null default pg_catalog.clock_timestamp(),
  unique(tenant_id,request_id), unique(tenant_id,reservation_id), foreign key(tenant_id,sales_order_id) references public.sales_orders(tenant_id,id) on delete restrict,
  foreign key(reservation_id) references public.sales_order_inventory_reservations(id) on delete restrict
);
alter table public.sales_order_inventory_reservations enable row level security; alter table public.sales_order_inventory_reservations force row level security;
alter table public.sales_order_inventory_requests enable row level security; alter table public.sales_order_inventory_requests force row level security;
alter table public.sales_order_inventory_returns enable row level security; alter table public.sales_order_inventory_returns force row level security;
revoke all on table public.sales_order_inventory_reservations,public.sales_order_inventory_requests,public.sales_order_inventory_returns from public,anon,authenticated,service_role;

-- Extends the immutable ledger vocabulary without changing valuation math.
create or replace function app_private.apply_inventory_valuation_delta(p_tenant_id uuid,p_branch_id uuid,p_item_id uuid,p_movement_type text,p_quantity numeric,p_request_id uuid,p_actor_id uuid,p_reference text default null,p_unit_cost numeric default null,p_source_document_id uuid default null)
returns table(movement_id uuid,balance_after numeric,stock_value_after numeric,average_unit_cost_after numeric,applied_unit_cost numeric,applied_value numeric)
language plpgsql volatile security definer set search_path='' set row_security=off as $fn$
declare balance public.inventory_balances%rowtype; delta numeric; new_quantity numeric; new_value numeric; inbound boolean; selected_cost numeric; selected_value numeric; normalized_reference text; input_cost_mode text; existing public.inventory_movements%rowtype;
begin
  if p_quantity is null or p_quantity<=0 or p_request_id is null or p_movement_type not in ('initial','entry','exit','adjustment_positive','adjustment_negative','transfer_out','transfer_in','physical_count_in','physical_count_out','service_consumption','service_reversal','purchase_receipt','purchase_receipt_reversal','sales_delivery','sales_return') then raise exception 'Invalid inventory valuation delta' using errcode='22023'; end if;
  if p_quantity<>pg_catalog.round(p_quantity,4) then raise exception 'Inventory quantity precision exceeds four decimal places' using errcode='22023'; end if;
  if p_unit_cost is not null and (p_unit_cost<0 or p_unit_cost<>pg_catalog.round(p_unit_cost,8)) then raise exception 'Invalid inventory unit cost precision' using errcode='22023'; end if;
  inbound:=p_movement_type in ('initial','entry','adjustment_positive','transfer_in','physical_count_in','service_reversal','purchase_receipt','sales_return'); normalized_reference:=nullif(pg_catalog.btrim(p_reference),''); input_cost_mode:=case when p_unit_cost is null then 'derived' else 'explicit' end;
  perform pg_catalog.pg_advisory_xact_lock(pg_catalog.hashtextextended('inventory-request:'||p_tenant_id::text||':'||p_request_id::text,0)); perform app_private.lock_inventory_position(p_tenant_id,p_branch_id,p_item_id);
  select * into existing from public.inventory_movements where tenant_id=p_tenant_id and request_id=p_request_id;
  if found then
    if existing.branch_id is distinct from p_branch_id or existing.item_id is distinct from p_item_id or existing.movement_type is distinct from p_movement_type or existing.quantity is distinct from p_quantity or existing.reference_note is distinct from normalized_reference or existing.source_document_id is distinct from p_source_document_id or existing.created_by_user_id is distinct from p_actor_id or existing.unit_cost_input_mode is distinct from input_cost_mode or (input_cost_mode='explicit' and existing.unit_cost_applied is distinct from p_unit_cost) then raise exception 'Inventory request identifier belongs to a different payload' using errcode='23505'; end if;
    return query select existing.id,existing.balance_after,existing.stock_value_after,existing.average_unit_cost_after,existing.unit_cost_applied,existing.value_delta; return;
  end if;
  if not exists(select 1 from public.catalog_items where tenant_id=p_tenant_id and id=p_item_id and item_type='product' and status='active') or not exists(select 1 from public.branches where tenant_id=p_tenant_id and id=p_branch_id and status='active') then raise exception 'Active branch and product in this company are required' using errcode='23503'; end if;
  insert into public.inventory_balances(tenant_id,branch_id,item_id,quantity) values(p_tenant_id,p_branch_id,p_item_id,0) on conflict do nothing; select * into balance from public.inventory_balances where tenant_id=p_tenant_id and branch_id=p_branch_id and item_id=p_item_id for update;
  delta:=case when inbound then p_quantity else -p_quantity end; new_quantity:=balance.quantity+delta; if new_quantity<0 then raise exception 'Negative inventory is not allowed' using errcode='23514'; end if;
  if balance.valuation_status='pending' and not (inbound and balance.quantity=0 and p_unit_cost is not null) then raise exception 'Initial inventory valuation is required before this movement' using errcode='55000'; end if;
  if inbound then selected_cost:=coalesce(p_unit_cost,balance.average_unit_cost); if selected_cost is null then raise exception 'An explicit unit cost is required for the first valued inbound movement' using errcode='22023'; end if; selected_value:=pg_catalog.round(p_quantity*selected_cost,8); new_value:=pg_catalog.round(coalesce(balance.stock_value,0)+selected_value,8);
  else selected_cost:=case when p_movement_type in ('purchase_receipt_reversal','sales_return') then p_unit_cost else balance.average_unit_cost end; if selected_cost is null then raise exception 'Valued stock is required before an outbound movement' using errcode='55000'; end if; selected_value:=pg_catalog.round(p_quantity*selected_cost,8); if coalesce(balance.stock_value,0)<selected_value then raise exception 'Insufficient valued inventory for this reversal or outbound movement' using errcode='23514'; end if; new_value:=pg_catalog.round(balance.stock_value-selected_value,8); end if;
  if new_quantity=0 then update public.inventory_balances set quantity=0,valuation_status='valued',stock_value=0,average_unit_cost=0,valuation_updated_at=pg_catalog.clock_timestamp(),updated_at=pg_catalog.clock_timestamp() where tenant_id=p_tenant_id and branch_id=p_branch_id and item_id=p_item_id;
  else update public.inventory_balances set quantity=new_quantity,valuation_status='valued',stock_value=new_value,average_unit_cost=pg_catalog.round(new_value/new_quantity,8),valuation_updated_at=pg_catalog.clock_timestamp(),updated_at=pg_catalog.clock_timestamp() where tenant_id=p_tenant_id and branch_id=p_branch_id and item_id=p_item_id; end if;
  select * into balance from public.inventory_balances where tenant_id=p_tenant_id and branch_id=p_branch_id and item_id=p_item_id;
  insert into public.inventory_movements(tenant_id,branch_id,item_id,movement_type,quantity,balance_after,reference_note,request_id,created_by_user_id,unit_cost_applied,unit_cost_input_mode,value_delta,stock_value_after,average_unit_cost_after,source_document_id) values(p_tenant_id,p_branch_id,p_item_id,p_movement_type,p_quantity,balance.quantity,normalized_reference,p_request_id,p_actor_id,selected_cost,input_cost_mode,case when inbound then selected_value else -selected_value end,balance.stock_value,balance.average_unit_cost,p_source_document_id) returning id into movement_id;
  balance_after:=balance.quantity; stock_value_after:=balance.stock_value; average_unit_cost_after:=balance.average_unit_cost; applied_unit_cost:=selected_cost; applied_value:=selected_value; return next;
end;$fn$;

create or replace function app_private.assert_operational_permission(p_tenant_id uuid,p_permission_key text,p_branch_id uuid default null)
returns uuid language plpgsql stable security definer set search_path='' set row_security=off as $fn$
declare actor_id uuid; required_codes text[]; ready_count integer;
begin
  if coalesce(auth.role(),'')<>'authenticated' or auth.uid() is null then raise exception 'Authenticated session required' using errcode='42501'; end if; actor_id:=auth.uid();
  if p_tenant_id is null or p_permission_key is null or not exists(select 1 from public.companies where id=p_tenant_id and status='active') or not app_private.is_active_company_member(p_tenant_id) or (p_branch_id is not null and not app_private.can_access_branch(p_tenant_id,p_branch_id)) or not app_private.has_tenant_permission(p_tenant_id,p_permission_key,p_branch_id) or not exists(select 1 from public.permission_definitions where permission_key=p_permission_key and approval_state='approved') then raise exception 'Operational permission denied' using errcode='42501'; end if;
  required_codes:=case
    when p_permission_key in ('transaction.masterdata.party.read','transaction.masterdata.party.manage') then array['BP01'] when p_permission_key='transaction.masterdata.catalog.read' then array['MM01','SV01'] when p_permission_key='transaction.masterdata.catalog.product.manage' then array['MM01'] when p_permission_key='transaction.masterdata.catalog.service.manage' then array['SV01'] when p_permission_key='transaction.inventory.stock.read' then array['MIGO'] when p_permission_key='transaction.purchasing.purchase_order.read' then array['ME23N'] when p_permission_key='transaction.purchasing.purchase_order.create' then array['ME21N'] when p_permission_key='transaction.masterdata.catalog.product.update' then array['MM02'] when p_permission_key='transaction.masterdata.catalog.product.read' then array['MM03'] when p_permission_key='transaction.inventory.balance.read' then array['MB52'] when p_permission_key='transaction.inventory.history.read' then array['MB51'] when p_permission_key='transaction.inventory.physical.create' then array['MI01'] when p_permission_key='transaction.inventory.physical.count' then array['MI04'] when p_permission_key='transaction.inventory.physical.adjust' then array['MI07'] when p_permission_key='transaction.inventory.transfer' then array['ZTR01'] when p_permission_key='transaction.service_order.create' then array['ZOS01'] when p_permission_key='transaction.service_order.update' then array['ZOS02'] when p_permission_key='transaction.service_order.read' then array['ZOS03'] when p_permission_key='transaction.service_order.close' then array['ZOS04'] when p_permission_key='transaction.purchasing.receipt.manage' then array['ZGR01'] when p_permission_key='transaction.inventory.valuation.initial' then array['ZIV01'] when p_permission_key='transaction.quotation.create' then array['ZQT01'] when p_permission_key='transaction.quotation.manage' then array['ZQT02'] when p_permission_key='transaction.quotation.read' then array['ZQT03'] when p_permission_key='transaction.quotation.approve' then array['ZQT04'] when p_permission_key='transaction.sales.order.create' then array['ZVE01'] when p_permission_key='transaction.sales.order.manage' then array['ZVE02'] when p_permission_key='transaction.sales.order.read' then array['ZVE03'] when p_permission_key='transaction.sales.order.decide' then array['ZVE04'] when p_permission_key='transaction.sales.inventory.reserve' then array['ZVE05'] when p_permission_key='transaction.sales.inventory.fulfill' then array['ZVE06'] when p_permission_key='transaction.sales.inventory.return' then array['ZVE07'] else null end;
  if required_codes is null then raise exception 'Operational permission is not mapped to an approved transaction' using errcode='42501'; end if;
  select count(distinct c.transaction_code) into ready_count from public.erp_transaction_authorization_catalog c join public.permission_definitions p on p.permission_key=c.permission_key and p.approval_state='approved' join public.company_module_availability m on m.tenant_id=p_tenant_id and m.module_code=c.module_code and m.enabled join public.company_transaction_availability t on t.tenant_id=p_tenant_id and t.transaction_code=c.transaction_code and t.enabled where c.transaction_code=any(required_codes) and c.approval_state='approved';
  if ready_count<>cardinality(required_codes) then raise exception 'Operational transaction is not approved or available for this company' using errcode='42501'; end if; return actor_id;
end;$fn$;

create function public.operational_reserve_sales_order_inventory(p_tenant_id uuid,p_sales_order_id uuid,p_request_id uuid)
returns text language plpgsql volatile security definer set search_path='' set row_security=off as $fn$
declare actor uuid; sale public.sales_orders%rowtype; line record; available numeric; existing public.sales_order_inventory_requests%rowtype;
begin
  if p_tenant_id is null or p_sales_order_id is null or p_request_id is null then raise exception 'Sales reservation request is required' using errcode='22023'; end if;
  select * into sale from public.sales_orders where tenant_id=p_tenant_id and id=p_sales_order_id; if not found then raise exception 'Sales order not found' using errcode='P0002'; end if;
  actor:=app_private.assert_operational_permission(p_tenant_id,'transaction.sales.inventory.reserve',sale.branch_id); perform pg_catalog.pg_advisory_xact_lock(pg_catalog.hashtextextended('sales-reserve:'||p_tenant_id::text||':'||p_request_id::text,0));
  select * into existing from public.sales_order_inventory_requests where tenant_id=p_tenant_id and request_id=p_request_id; if found then if existing.sales_order_id<>p_sales_order_id or existing.operation<>'reserve' or existing.actor_user_id<>actor then raise exception 'Sales reservation request identifier belongs to a different payload' using errcode='23505'; end if; return 'reserved'; end if;
  for line in select item_id,sum(quantity) quantity from public.sales_order_lines where tenant_id=p_tenant_id and sales_order_id=p_sales_order_id and item_type='product' group by item_id order by item_id loop perform app_private.lock_inventory_position(p_tenant_id,sale.branch_id,line.item_id); end loop;
  select * into sale from public.sales_orders where tenant_id=p_tenant_id and id=p_sales_order_id for update; if sale.status<>'confirmed' then raise exception 'Only confirmed sales orders may reserve stock' using errcode='55000'; end if;
  for line in select item_id,sum(quantity) quantity from public.sales_order_lines where tenant_id=p_tenant_id and sales_order_id=p_sales_order_id and item_type='product' group by item_id order by item_id loop
    select coalesce(b.quantity,0)-coalesce((select sum(r.quantity) from public.sales_order_inventory_reservations r join public.sales_orders s on s.id=r.sales_order_id where r.tenant_id=p_tenant_id and r.item_id=line.item_id and r.status='reserved' and s.branch_id=sale.branch_id and r.sales_order_id<>p_sales_order_id),0)-coalesce((select sum(r.quantity) from public.work_order_part_reservations r join public.work_orders o on o.id=r.work_order_id where r.tenant_id=p_tenant_id and r.item_id=line.item_id and r.status='reserved' and o.branch_id=sale.branch_id),0) into available from public.inventory_balances b where b.tenant_id=p_tenant_id and b.branch_id=sale.branch_id and b.item_id=line.item_id;
    if coalesce(available,0)<line.quantity then raise exception 'Insufficient available inventory for sales reservation' using errcode='23514'; end if;
    insert into public.sales_order_inventory_reservations(tenant_id,sales_order_id,item_id,quantity,status,reserved_by_user_id) values(p_tenant_id,p_sales_order_id,line.item_id,line.quantity,'reserved',actor) on conflict(tenant_id,sales_order_id,item_id) do update set quantity=excluded.quantity,status='reserved',reserved_by_user_id=excluded.reserved_by_user_id,reserved_at=pg_catalog.clock_timestamp(),fulfilled_movement_id=null,fulfilled_unit_cost=null,fulfilled_value=null,fulfilled_at=null,returned_movement_id=null,returned_at=null;
  end loop;
  insert into public.sales_order_inventory_requests(tenant_id,sales_order_id,request_id,operation,actor_user_id,request_payload) values(p_tenant_id,p_sales_order_id,p_request_id,'reserve',actor,'{}'); insert into public.sales_order_events(tenant_id,branch_id,sales_order_id,event_key,actor_user_id,details) values(p_tenant_id,sale.branch_id,p_sales_order_id,'sales_order.inventory_reserved',actor,'{}'); perform app_private.write_operational_audit('sales_order.inventory_reserved',p_tenant_id,sale.branch_id,p_sales_order_id,actor,'{}'); return 'reserved';
end;$fn$;

create function public.operational_fulfill_sales_order(p_tenant_id uuid,p_sales_order_id uuid,p_request_id uuid)
returns text language plpgsql volatile security definer set search_path='' set row_security=off as $fn$
declare actor uuid; sale public.sales_orders%rowtype; reservation record; existing public.sales_order_inventory_requests%rowtype; result record;
begin
  if p_tenant_id is null or p_sales_order_id is null or p_request_id is null then raise exception 'Sales fulfilment request is required' using errcode='22023'; end if; select * into sale from public.sales_orders where tenant_id=p_tenant_id and id=p_sales_order_id; if not found then raise exception 'Sales order not found' using errcode='P0002'; end if;
  actor:=app_private.assert_operational_permission(p_tenant_id,'transaction.sales.inventory.fulfill',sale.branch_id); perform pg_catalog.pg_advisory_xact_lock(pg_catalog.hashtextextended('sales-fulfil:'||p_tenant_id::text||':'||p_request_id::text,0)); select * into existing from public.sales_order_inventory_requests where tenant_id=p_tenant_id and request_id=p_request_id; if found then if existing.sales_order_id<>p_sales_order_id or existing.operation<>'fulfill' or existing.actor_user_id<>actor then raise exception 'Sales fulfilment request identifier belongs to a different payload' using errcode='23505'; end if; return 'fulfilled'; end if;
  for reservation in select item_id from public.sales_order_inventory_reservations where tenant_id=p_tenant_id and sales_order_id=p_sales_order_id and status='reserved' order by item_id loop perform app_private.lock_inventory_position(p_tenant_id,sale.branch_id,reservation.item_id); end loop;
  select * into sale from public.sales_orders where tenant_id=p_tenant_id and id=p_sales_order_id for update; if sale.status<>'confirmed' then raise exception 'Only confirmed sales orders may be fulfilled' using errcode='55000'; end if;
  if not exists(select 1 from public.sales_order_inventory_reservations where tenant_id=p_tenant_id and sales_order_id=p_sales_order_id and status='reserved') and exists(select 1 from public.sales_order_lines where tenant_id=p_tenant_id and sales_order_id=p_sales_order_id and item_type='product') then raise exception 'Product lines must be reserved before fulfilment' using errcode='23514'; end if;
  for reservation in select * from public.sales_order_inventory_reservations where tenant_id=p_tenant_id and sales_order_id=p_sales_order_id and status='reserved' order by item_id for update loop
    select * into result from app_private.apply_inventory_valuation_delta(p_tenant_id,sale.branch_id,reservation.item_id,'sales_delivery',reservation.quantity,pg_catalog.gen_random_uuid(),actor,'Sales delivery '||p_sales_order_id::text,null,p_sales_order_id);
    update public.sales_order_inventory_reservations set status='fulfilled',fulfilled_movement_id=result.movement_id,fulfilled_unit_cost=result.applied_unit_cost,fulfilled_value=result.applied_value,fulfilled_at=pg_catalog.clock_timestamp() where id=reservation.id;
  end loop;
  update public.sales_orders set status='fulfilled',updated_at=pg_catalog.clock_timestamp() where tenant_id=p_tenant_id and id=p_sales_order_id; insert into public.sales_order_inventory_requests(tenant_id,sales_order_id,request_id,operation,actor_user_id,request_payload) values(p_tenant_id,p_sales_order_id,p_request_id,'fulfill',actor,'{}'); insert into public.sales_order_events(tenant_id,branch_id,sales_order_id,event_key,actor_user_id,details) values(p_tenant_id,sale.branch_id,p_sales_order_id,'sales_order.fulfilled',actor,'{}'); perform app_private.write_operational_audit('sales_order.fulfilled',p_tenant_id,sale.branch_id,p_sales_order_id,actor,'{}'); return 'fulfilled';
end;$fn$;

-- Cancelling a confirmed sale releases only a reservation. It never fabricates
-- a stock movement, and cannot be used after delivery.
create function public.operational_release_sales_order_inventory(p_tenant_id uuid,p_sales_order_id uuid,p_reason text,p_request_id uuid)
returns text language plpgsql volatile security definer set search_path='' set row_security=off as $fn$
declare actor uuid; sale public.sales_orders%rowtype; reservation record; existing public.sales_order_inventory_requests%rowtype; normalized_reason text;
begin
  normalized_reason:=nullif(pg_catalog.btrim(p_reason),'');
  if p_tenant_id is null or p_sales_order_id is null or p_request_id is null or normalized_reason is null or pg_catalog.length(normalized_reason)>1000 then raise exception 'Sales cancellation reason and request are required' using errcode='22023'; end if;
  select * into sale from public.sales_orders where tenant_id=p_tenant_id and id=p_sales_order_id; if not found then raise exception 'Sales order not found' using errcode='P0002'; end if;
  actor:=app_private.assert_operational_permission(p_tenant_id,'transaction.sales.inventory.reserve',sale.branch_id);
  perform pg_catalog.pg_advisory_xact_lock(pg_catalog.hashtextextended('sales-release:'||p_tenant_id::text||':'||p_request_id::text,0));
  select * into existing from public.sales_order_inventory_requests where tenant_id=p_tenant_id and request_id=p_request_id;
  if found then
    if existing.sales_order_id<>p_sales_order_id or existing.operation<>'release' or existing.actor_user_id<>actor or existing.request_payload is distinct from pg_catalog.jsonb_build_object('reason',normalized_reason) then raise exception 'Sales release request identifier belongs to a different payload' using errcode='23505'; end if;
    return 'released';
  end if;
  for reservation in select item_id from public.sales_order_inventory_reservations where tenant_id=p_tenant_id and sales_order_id=p_sales_order_id and status='reserved' order by item_id loop perform app_private.lock_inventory_position(p_tenant_id,sale.branch_id,reservation.item_id); end loop;
  select * into sale from public.sales_orders where tenant_id=p_tenant_id and id=p_sales_order_id for update;
  if sale.status<>'confirmed' then raise exception 'Only confirmed undelivered sales orders may be cancelled' using errcode='55000'; end if;
  if exists(select 1 from public.sales_order_inventory_reservations where tenant_id=p_tenant_id and sales_order_id=p_sales_order_id and status='fulfilled') then raise exception 'Delivered sales orders require a return, not reservation release' using errcode='55000'; end if;
  update public.sales_order_inventory_reservations set status='released' where tenant_id=p_tenant_id and sales_order_id=p_sales_order_id and status='reserved';
  update public.sales_orders set status='cancelled',decision_reason=normalized_reason,updated_at=pg_catalog.clock_timestamp() where tenant_id=p_tenant_id and id=p_sales_order_id;
  insert into public.sales_order_inventory_requests(tenant_id,sales_order_id,request_id,operation,actor_user_id,request_payload) values(p_tenant_id,p_sales_order_id,p_request_id,'release',actor,pg_catalog.jsonb_build_object('reason',normalized_reason));
  insert into public.sales_order_events(tenant_id,branch_id,sales_order_id,event_key,actor_user_id,details) values(p_tenant_id,sale.branch_id,p_sales_order_id,'sales_order.inventory_released',actor,pg_catalog.jsonb_build_object('reason',normalized_reason));
  perform app_private.write_operational_audit('sales_order.inventory_released',p_tenant_id,sale.branch_id,p_sales_order_id,actor,pg_catalog.jsonb_build_object('reason',normalized_reason));
  return 'released';
end;$fn$;

-- A sales return reuses the immutable delivery cost. It fails closed if a
-- later outbound stock fact makes a deterministic reversal unsafe.
create function public.operational_return_sales_order_inventory(p_tenant_id uuid,p_sales_order_id uuid,p_reason text,p_request_id uuid)
returns text language plpgsql volatile security definer set search_path='' set row_security=off as $fn$
declare actor uuid; sale public.sales_orders%rowtype; reservation record; existing public.sales_order_inventory_requests%rowtype; result record; normalized_reason text;
begin
  normalized_reason:=nullif(pg_catalog.btrim(p_reason),'');
  if p_tenant_id is null or p_sales_order_id is null or p_request_id is null or normalized_reason is null or pg_catalog.length(normalized_reason)>1000 then raise exception 'Sales return reason and request are required' using errcode='22023'; end if;
  select * into sale from public.sales_orders where tenant_id=p_tenant_id and id=p_sales_order_id; if not found then raise exception 'Sales order not found' using errcode='P0002'; end if;
  actor:=app_private.assert_operational_permission(p_tenant_id,'transaction.sales.inventory.return',sale.branch_id);
  perform pg_catalog.pg_advisory_xact_lock(pg_catalog.hashtextextended('sales-return:'||p_tenant_id::text||':'||p_request_id::text,0));
  select * into existing from public.sales_order_inventory_requests where tenant_id=p_tenant_id and request_id=p_request_id;
  if found then
    if existing.sales_order_id<>p_sales_order_id or existing.operation<>'return' or existing.actor_user_id<>actor or existing.request_payload is distinct from pg_catalog.jsonb_build_object('reason',normalized_reason) then raise exception 'Sales return request identifier belongs to a different payload' using errcode='23505'; end if;
    return 'returned';
  end if;
  for reservation in select item_id from public.sales_order_inventory_reservations where tenant_id=p_tenant_id and sales_order_id=p_sales_order_id and status='fulfilled' order by item_id loop perform app_private.lock_inventory_position(p_tenant_id,sale.branch_id,reservation.item_id); end loop;
  select * into sale from public.sales_orders where tenant_id=p_tenant_id and id=p_sales_order_id for update;
  if sale.status<>'fulfilled' then raise exception 'Only fulfilled sales orders may be returned' using errcode='55000'; end if;
  if not exists(select 1 from public.sales_order_inventory_reservations where tenant_id=p_tenant_id and sales_order_id=p_sales_order_id and status='fulfilled') then raise exception 'No delivered product stock exists for this sales order' using errcode='55000'; end if;
  for reservation in select * from public.sales_order_inventory_reservations where tenant_id=p_tenant_id and sales_order_id=p_sales_order_id and status='fulfilled' order by item_id for update loop
    if exists(select 1 from public.inventory_movements m where m.tenant_id=p_tenant_id and m.branch_id=sale.branch_id and m.item_id=reservation.item_id and m.created_at>(select d.created_at from public.inventory_movements d where d.id=reservation.fulfilled_movement_id) and m.movement_type in ('exit','adjustment_negative','transfer_out','physical_count_out','service_consumption','sales_delivery')) then raise exception 'Sales return is blocked because a later outbound stock event exists' using errcode='55000'; end if;
    select * into result from app_private.apply_inventory_valuation_delta(p_tenant_id,sale.branch_id,reservation.item_id,'sales_return',reservation.quantity,pg_catalog.gen_random_uuid(),actor,'Sales return '||p_sales_order_id::text,reservation.fulfilled_unit_cost,p_sales_order_id);
    update public.sales_order_inventory_reservations set status='returned',returned_movement_id=result.movement_id,returned_at=pg_catalog.clock_timestamp() where id=reservation.id;
    insert into public.sales_order_inventory_returns(tenant_id,sales_order_id,reservation_id,request_id,actor_user_id,reason,returned_quantity) values(p_tenant_id,p_sales_order_id,reservation.id,p_request_id,actor,normalized_reason,reservation.quantity);
  end loop;
  update public.sales_orders set status='cancelled',decision_reason=normalized_reason,updated_at=pg_catalog.clock_timestamp() where tenant_id=p_tenant_id and id=p_sales_order_id;
  insert into public.sales_order_inventory_requests(tenant_id,sales_order_id,request_id,operation,actor_user_id,request_payload) values(p_tenant_id,p_sales_order_id,p_request_id,'return',actor,pg_catalog.jsonb_build_object('reason',normalized_reason));
  insert into public.sales_order_events(tenant_id,branch_id,sales_order_id,event_key,actor_user_id,details) values(p_tenant_id,sale.branch_id,p_sales_order_id,'sales_order.inventory_returned',actor,pg_catalog.jsonb_build_object('reason',normalized_reason));
  perform app_private.write_operational_audit('sales_order.inventory_returned',p_tenant_id,sale.branch_id,p_sales_order_id,actor,pg_catalog.jsonb_build_object('reason',normalized_reason));
  return 'returned';
end;$fn$;

alter function app_private.apply_inventory_valuation_delta(uuid,uuid,uuid,text,numeric,uuid,uuid,text,numeric,uuid) owner to postgres;
alter function app_private.assert_operational_permission(uuid,text,uuid) owner to postgres;
alter function public.operational_reserve_sales_order_inventory(uuid,uuid,uuid) owner to postgres;
alter function public.operational_fulfill_sales_order(uuid,uuid,uuid) owner to postgres;
alter function public.operational_release_sales_order_inventory(uuid,uuid,text,uuid) owner to postgres;
alter function public.operational_return_sales_order_inventory(uuid,uuid,text,uuid) owner to postgres;
revoke all on function public.operational_reserve_sales_order_inventory(uuid,uuid,uuid),public.operational_fulfill_sales_order(uuid,uuid,uuid),public.operational_release_sales_order_inventory(uuid,uuid,text,uuid),public.operational_return_sales_order_inventory(uuid,uuid,text,uuid) from public,anon,authenticated,service_role;
grant execute on function public.operational_reserve_sales_order_inventory(uuid,uuid,uuid),public.operational_fulfill_sales_order(uuid,uuid,uuid),public.operational_release_sales_order_inventory(uuid,uuid,text,uuid),public.operational_return_sales_order_inventory(uuid,uuid,text,uuid) to authenticated;
commit;
