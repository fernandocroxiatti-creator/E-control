-- Phase 01: purchase receipts, branch-level moving-average valuation and safe reversals.
-- Prepared locally only. Applying it requires a separate Production authorization.
-- This migration creates no role grant, no company availability and no business data.
begin;

do $preflight$
begin
  if current_user <> 'postgres' then raise exception 'Apply this migration as postgres'; end if;
  if pg_catalog.to_regclass('public.purchase_orders') is null
    or pg_catalog.to_regclass('public.purchase_order_items') is null
    or pg_catalog.to_regclass('public.inventory_balances') is null
    or pg_catalog.to_regclass('public.inventory_movements') is null
    or pg_catalog.to_regclass('public.work_order_part_reservations') is null
    or pg_catalog.to_regprocedure('app_private.assert_operational_permission(uuid,text,uuid)') is null
    or pg_catalog.to_regprocedure('app_private.write_operational_audit(text,uuid,uuid,uuid,uuid,jsonb)') is null then
    raise exception 'Purchase, inventory, work-order and authorization foundations are required';
  end if;
  if pg_catalog.to_regclass('public.purchase_receipts') is not null
    or pg_catalog.to_regprocedure('public.operational_receive_purchase_order(uuid,uuid,jsonb,text,text,uuid)') is not null then
    raise exception 'Purchase receipt valuation objects already exist; inspect before applying';
  end if;
end;
$preflight$;

insert into public.permission_definitions(permission_key,description) values
  ('transaction.purchasing.receipt.manage','Transação ZGR01: registrar, consultar e estornar recebimentos de pedidos de compra.'),
  ('transaction.inventory.valuation.initial','Transação ZIV01: registrar avaliação inicial auditada de estoque legado por filial.')
on conflict(permission_key) do nothing;

insert into public.erp_transaction_authorization_catalog(transaction_code,module_code,permission_key) values
  ('ZGR01','PUR','transaction.purchasing.receipt.manage'),
  ('ZIV01','INV','transaction.inventory.valuation.initial')
on conflict(transaction_code) do nothing;

alter table public.purchase_orders drop constraint purchase_orders_status_check;
alter table public.purchase_orders add constraint purchase_orders_status_check
  check(status in ('draft','submitted','partially_received','received','cancelled'));

alter table public.inventory_balances
  add column valuation_status text not null default 'pending'
    check(valuation_status in ('pending','valued')),
  add column stock_value numeric(24,8),
  add column average_unit_cost numeric(24,8),
  add column valuation_updated_at timestamptz;
alter table public.inventory_balances add constraint inventory_balances_valuation_check check (
  (valuation_status='pending' and stock_value is null and average_unit_cost is null)
  or (valuation_status='valued' and stock_value is not null and stock_value >= 0 and average_unit_cost is not null and average_unit_cost >= 0)
);

alter table public.inventory_movements
  add column unit_cost_applied numeric(24,8),
  add column value_delta numeric(24,8),
  add column stock_value_after numeric(24,8),
  add column average_unit_cost_after numeric(24,8),
  add column source_document_id uuid;
alter table public.inventory_movements drop constraint inventory_movements_movement_type_check;
alter table public.inventory_movements add constraint inventory_movements_movement_type_check check (
  movement_type in ('initial','entry','exit','adjustment_positive','adjustment_negative',
    'transfer_out','transfer_in','physical_count_in','physical_count_out',
    'service_consumption','service_reversal','purchase_receipt','purchase_receipt_reversal')
);

alter table public.inventory_transfers
  add column unit_cost numeric(24,8),
  add column total_value numeric(24,8);
alter table public.work_order_part_reservations
  add column consumed_unit_cost numeric(24,8),
  add column consumed_value numeric(24,8);

-- The receipt line is tenant-scoped. The published purchase-item table has a
-- primary key on id, but needs this composite candidate key before a tenant
-- foreign key can prove an item cannot be attached across companies.
do $purchase_item_key$
begin
  if not exists (
    select 1 from pg_catalog.pg_constraint
    where conrelid='public.purchase_order_items'::regclass
      and contype='u' and conkey=array[
        (select attnum from pg_catalog.pg_attribute where attrelid='public.purchase_order_items'::regclass and attname='tenant_id' and not attisdropped),
        (select attnum from pg_catalog.pg_attribute where attrelid='public.purchase_order_items'::regclass and attname='id' and not attisdropped)
      ]
  ) then
    alter table public.purchase_order_items add constraint purchase_order_items_tenant_id_id_key unique(tenant_id,id);
  end if;
end;
$purchase_item_key$;

create table public.inventory_valuation_events (
  id uuid primary key default pg_catalog.gen_random_uuid(),
  tenant_id uuid not null references public.companies(id) on delete restrict,
  branch_id uuid not null,
  item_id uuid not null,
  event_type text not null check(event_type='initial_valuation'),
  quantity_at_valuation numeric(18,4) not null check(quantity_at_valuation>0),
  unit_cost numeric(24,8) not null check(unit_cost>=0),
  stock_value numeric(24,8) not null check(stock_value>=0),
  reason text not null check(pg_catalog.length(pg_catalog.btrim(reason)) between 1 and 1000),
  request_id uuid not null,
  created_by_user_id uuid not null references auth.users(id) on delete restrict,
  created_at timestamptz not null default pg_catalog.clock_timestamp(),
  unique(tenant_id,id),
  unique(tenant_id,request_id),
  foreign key(tenant_id,branch_id) references public.branches(tenant_id,id) on delete restrict,
  foreign key(tenant_id,item_id) references public.catalog_items(tenant_id,id) on delete restrict
);

create table public.purchase_receipt_counters (
  tenant_id uuid primary key references public.companies(id) on delete restrict,
  last_number bigint not null default 0 check(last_number>=0)
);

create table public.purchase_receipts (
  id uuid primary key default pg_catalog.gen_random_uuid(),
  tenant_id uuid not null references public.companies(id) on delete restrict,
  branch_id uuid not null,
  purchase_order_id uuid not null,
  receipt_number bigint not null,
  status text not null default 'posted' check(status in ('posted','partially_reversed','reversed')),
  document_number text check(document_number is null or pg_catalog.length(pg_catalog.btrim(document_number))<=120),
  notes text check(notes is null or pg_catalog.length(pg_catalog.btrim(notes))<=1000),
  request_payload jsonb not null check(pg_catalog.jsonb_typeof(request_payload)='object'),
  request_id uuid not null,
  created_by_user_id uuid not null references auth.users(id) on delete restrict,
  created_at timestamptz not null default pg_catalog.clock_timestamp(),
  reversed_at timestamptz,
  unique(tenant_id,id),
  unique(tenant_id,receipt_number),
  unique(tenant_id,request_id),
  foreign key(tenant_id,branch_id) references public.branches(tenant_id,id) on delete restrict,
  foreign key(tenant_id,purchase_order_id) references public.purchase_orders(tenant_id,id) on delete restrict
);

create table public.purchase_receipt_items (
  id uuid primary key default pg_catalog.gen_random_uuid(),
  tenant_id uuid not null,
  purchase_receipt_id uuid not null,
  purchase_order_item_id uuid not null,
  item_id uuid not null,
  received_quantity numeric(18,4) not null check(received_quantity>0),
  effective_unit_cost numeric(24,8) not null check(effective_unit_cost>=0),
  received_value numeric(24,8) not null check(received_value>=0),
  variance_reason text,
  inventory_movement_id uuid not null,
  created_at timestamptz not null default pg_catalog.clock_timestamp(),
  unique(purchase_receipt_id,purchase_order_item_id),
  unique(tenant_id,id),
  foreign key(tenant_id,purchase_receipt_id) references public.purchase_receipts(tenant_id,id) on delete restrict,
  foreign key(tenant_id,purchase_order_item_id) references public.purchase_order_items(tenant_id,id) on delete restrict,
  foreign key(tenant_id,item_id) references public.catalog_items(tenant_id,id) on delete restrict,
  foreign key(inventory_movement_id) references public.inventory_movements(id) on delete restrict
);

create table public.purchase_receipt_reversals (
  id uuid primary key default pg_catalog.gen_random_uuid(),
  tenant_id uuid not null references public.companies(id) on delete restrict,
  branch_id uuid not null,
  purchase_receipt_id uuid not null,
  reason text not null check(pg_catalog.length(pg_catalog.btrim(reason)) between 1 and 1000),
  request_payload jsonb not null check(pg_catalog.jsonb_typeof(request_payload)='object'),
  request_id uuid not null,
  created_by_user_id uuid not null references auth.users(id) on delete restrict,
  created_at timestamptz not null default pg_catalog.clock_timestamp(),
  unique(tenant_id,id),
  unique(tenant_id,request_id),
  foreign key(tenant_id,branch_id) references public.branches(tenant_id,id) on delete restrict,
  foreign key(tenant_id,purchase_receipt_id) references public.purchase_receipts(tenant_id,id) on delete restrict
);

create table public.purchase_receipt_reversal_items (
  id uuid primary key default pg_catalog.gen_random_uuid(),
  tenant_id uuid not null,
  purchase_receipt_reversal_id uuid not null,
  purchase_receipt_item_id uuid not null,
  item_id uuid not null,
  reversed_quantity numeric(18,4) not null check(reversed_quantity>0),
  unit_cost numeric(24,8) not null check(unit_cost>=0),
  reversed_value numeric(24,8) not null check(reversed_value>=0),
  inventory_movement_id uuid not null,
  created_at timestamptz not null default pg_catalog.clock_timestamp(),
  unique(purchase_receipt_reversal_id,purchase_receipt_item_id),
  foreign key(tenant_id,purchase_receipt_reversal_id) references public.purchase_receipt_reversals(tenant_id,id) on delete restrict,
  foreign key(tenant_id,purchase_receipt_item_id) references public.purchase_receipt_items(tenant_id,id) on delete restrict,
  foreign key(tenant_id,item_id) references public.catalog_items(tenant_id,id) on delete restrict,
  foreign key(inventory_movement_id) references public.inventory_movements(id) on delete restrict
);

create index purchase_receipts_order_idx on public.purchase_receipts(tenant_id,purchase_order_id,created_at desc);
create index purchase_receipt_items_order_item_idx on public.purchase_receipt_items(tenant_id,purchase_order_item_id);
create index purchase_receipt_reversal_items_receipt_item_idx on public.purchase_receipt_reversal_items(tenant_id,purchase_receipt_item_id);
create index inventory_valuation_events_lookup_idx on public.inventory_valuation_events(tenant_id,branch_id,item_id,created_at desc);

alter table public.inventory_valuation_events enable row level security;
alter table public.inventory_valuation_events force row level security;
alter table public.purchase_receipt_counters enable row level security;
alter table public.purchase_receipt_counters force row level security;
alter table public.purchase_receipts enable row level security;
alter table public.purchase_receipts force row level security;
alter table public.purchase_receipt_items enable row level security;
alter table public.purchase_receipt_items force row level security;
alter table public.purchase_receipt_reversals enable row level security;
alter table public.purchase_receipt_reversals force row level security;
alter table public.purchase_receipt_reversal_items enable row level security;
alter table public.purchase_receipt_reversal_items force row level security;
revoke all on table public.inventory_valuation_events,public.purchase_receipt_counters,public.purchase_receipts,public.purchase_receipt_items,public.purchase_receipt_reversals,public.purchase_receipt_reversal_items from public,anon,authenticated,service_role;

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
    else null end;
  if required_codes is null then raise exception 'Operational permission is not mapped to an approved transaction' using errcode='42501'; end if;
  select count(distinct c.transaction_code) into ready_count from public.erp_transaction_authorization_catalog c join public.permission_definitions p on p.permission_key=c.permission_key and p.approval_state='approved' join public.company_module_availability m on m.tenant_id=p_tenant_id and m.module_code=c.module_code and m.enabled join public.company_transaction_availability t on t.tenant_id=p_tenant_id and t.transaction_code=c.transaction_code and t.enabled where c.transaction_code=any(required_codes) and c.approval_state='approved';
  if ready_count<>cardinality(required_codes) then raise exception 'Operational transaction is not approved or available for this company' using errcode='42501'; end if;
  return actor_id;
end;
$fn$;

create function app_private.next_purchase_receipt_number(p_tenant_id uuid)
returns bigint language plpgsql volatile security definer set search_path='' set row_security=off as $fn$
declare result bigint;
begin
  insert into public.purchase_receipt_counters(tenant_id,last_number) values(p_tenant_id,1)
  on conflict(tenant_id) do update set last_number=public.purchase_receipt_counters.last_number+1
  returning last_number into result;
  return result;
end;
$fn$;

-- Global inventory-lock protocol for Phase 01.
-- 1) request/document idempotency locks; 2) inventory advisory locks ordered by
-- (tenant, branch, item); 3) document rows; 4) inventory balance rows.  A
-- routine that affects more than one item must acquire every inventory lock in
-- this exact sorted order before it locks any corresponding balance row.
create function app_private.lock_inventory_position(p_tenant_id uuid,p_branch_id uuid,p_item_id uuid)
returns void language plpgsql volatile security definer set search_path='' set row_security=off as $fn$
begin
  if p_tenant_id is null or p_branch_id is null or p_item_id is null then
    raise exception 'Inventory lock identity is required' using errcode='22023';
  end if;
  perform pg_catalog.pg_advisory_xact_lock(pg_catalog.hashtextextended('inventory:'||p_tenant_id::text||':'||p_branch_id::text||':'||p_item_id::text,0));
end;
$fn$;

-- D05 deliberately fails closed.  Inventory is valued by moving average rather
-- than by lot, so a later outbound event cannot be attributed safely to one
-- receipt.  Once a later outbound event or an active O.S. reservation exists,
-- a receipt reversal is refused instead of silently changing the valuation of
-- facts that may already have consumed the received stock.
create function app_private.assert_purchase_receipt_reversal_traceability(
  p_tenant_id uuid,p_branch_id uuid,p_purchase_receipt_id uuid,p_item_id uuid
)
returns void language plpgsql volatile security definer set search_path='' set row_security=off as $fn$
declare receipt_created_at timestamptz;
begin
  select created_at into receipt_created_at
    from public.purchase_receipts
   where tenant_id=p_tenant_id and id=p_purchase_receipt_id;
  if not found then
    raise exception 'Purchase receipt traceability source was not found' using errcode='P0002';
  end if;

  if exists(
    select 1
      from public.work_order_part_reservations reservation
      join public.work_orders work_order on work_order.id=reservation.work_order_id
     where reservation.tenant_id=p_tenant_id
       and reservation.item_id=p_item_id
       and reservation.status='reserved'
       and work_order.branch_id=p_branch_id
  ) then
    raise exception 'Receipt reversal is blocked by an active work-order reservation; release or consume it through the authorized flow first'
      using errcode='55000';
  end if;

  if exists(
    select 1
      from public.inventory_movements movement
     where movement.tenant_id=p_tenant_id
       and movement.branch_id=p_branch_id
       and movement.item_id=p_item_id
       and movement.created_at>receipt_created_at
       and movement.movement_type in (
         'exit','adjustment_negative','transfer_out','physical_count_out','service_consumption'
       )
  ) then
    raise exception 'Receipt reversal is blocked because a later outbound inventory event makes its quantity and value untraceable'
      using errcode='55000';
  end if;
end;
$fn$;

create function app_private.apply_inventory_valuation_delta(
  p_tenant_id uuid,p_branch_id uuid,p_item_id uuid,p_movement_type text,p_quantity numeric,
  p_request_id uuid,p_actor_id uuid,p_reference text default null,p_unit_cost numeric default null,
  p_source_document_id uuid default null
)
returns table(movement_id uuid,balance_after numeric,stock_value_after numeric,average_unit_cost_after numeric,applied_unit_cost numeric,applied_value numeric)
language plpgsql volatile security definer set search_path='' set row_security=off as $fn$
declare balance public.inventory_balances%rowtype; delta numeric; new_quantity numeric; new_value numeric; inbound boolean; selected_cost numeric; selected_value numeric; existing public.inventory_movements%rowtype;
begin
  if p_quantity is null or p_quantity<=0 or p_request_id is null or p_movement_type not in ('initial','entry','exit','adjustment_positive','adjustment_negative','transfer_out','transfer_in','physical_count_in','physical_count_out','service_consumption','service_reversal','purchase_receipt','purchase_receipt_reversal') then raise exception 'Invalid inventory valuation delta' using errcode='22023'; end if;
  if p_unit_cost is not null and p_unit_cost<0 then raise exception 'Invalid inventory unit cost' using errcode='22023'; end if;
  perform app_private.lock_inventory_position(p_tenant_id,p_branch_id,p_item_id);
  select * into existing from public.inventory_movements where tenant_id=p_tenant_id and request_id=p_request_id;
  if found then
    if existing.branch_id<>p_branch_id or existing.item_id<>p_item_id or existing.movement_type<>p_movement_type or existing.quantity<>p_quantity then raise exception 'Inventory request identifier belongs to a different payload' using errcode='23505'; end if;
    return query select existing.id,existing.balance_after,existing.stock_value_after,existing.average_unit_cost_after,existing.unit_cost_applied,existing.value_delta; return;
  end if;
  if not exists(select 1 from public.catalog_items where tenant_id=p_tenant_id and id=p_item_id and item_type='product' and status='active') or not exists(select 1 from public.branches where tenant_id=p_tenant_id and id=p_branch_id and status='active') then raise exception 'Active branch and product in this company are required' using errcode='23503'; end if;
  insert into public.inventory_balances(tenant_id,branch_id,item_id,quantity) values(p_tenant_id,p_branch_id,p_item_id,0) on conflict do nothing;
  select * into balance from public.inventory_balances where tenant_id=p_tenant_id and branch_id=p_branch_id and item_id=p_item_id for update;
  inbound:=p_movement_type in ('initial','entry','adjustment_positive','transfer_in','physical_count_in','service_reversal','purchase_receipt');
  delta:=case when inbound then p_quantity else -p_quantity end;
  new_quantity:=balance.quantity+delta;
  if new_quantity<0 then raise exception 'Negative inventory is not allowed' using errcode='23514'; end if;
  if balance.valuation_status='pending' and not (inbound and balance.quantity=0 and p_unit_cost is not null) then raise exception 'Initial inventory valuation is required before this movement' using errcode='55000'; end if;
  if inbound then
    selected_cost:=coalesce(p_unit_cost,balance.average_unit_cost);
    if selected_cost is null then raise exception 'An explicit unit cost is required for the first valued inbound movement' using errcode='22023'; end if;
    selected_value:=pg_catalog.round(p_quantity*selected_cost,8);
    new_value:=pg_catalog.round(coalesce(balance.stock_value,0)+selected_value,8);
  else
    selected_cost:=case when p_movement_type='purchase_receipt_reversal' then p_unit_cost else balance.average_unit_cost end;
    if selected_cost is null then raise exception 'Valued stock is required before an outbound movement' using errcode='55000'; end if;
    selected_value:=pg_catalog.round(p_quantity*selected_cost,8);
    if coalesce(balance.stock_value,0)<selected_value then raise exception 'Insufficient valued inventory for this reversal or outbound movement' using errcode='23514'; end if;
    new_value:=pg_catalog.round(balance.stock_value-selected_value,8);
  end if;
  if new_quantity=0 then
    update public.inventory_balances set quantity=0,valuation_status='valued',stock_value=0,average_unit_cost=0,valuation_updated_at=pg_catalog.clock_timestamp(),updated_at=pg_catalog.clock_timestamp() where tenant_id=p_tenant_id and branch_id=p_branch_id and item_id=p_item_id;
  else
    update public.inventory_balances set quantity=new_quantity,valuation_status='valued',stock_value=new_value,average_unit_cost=pg_catalog.round(new_value/new_quantity,8),valuation_updated_at=pg_catalog.clock_timestamp(),updated_at=pg_catalog.clock_timestamp() where tenant_id=p_tenant_id and branch_id=p_branch_id and item_id=p_item_id;
  end if;
  select * into balance from public.inventory_balances where tenant_id=p_tenant_id and branch_id=p_branch_id and item_id=p_item_id;
  insert into public.inventory_movements(tenant_id,branch_id,item_id,movement_type,quantity,balance_after,reference_note,request_id,created_by_user_id,unit_cost_applied,value_delta,stock_value_after,average_unit_cost_after,source_document_id)
  values(p_tenant_id,p_branch_id,p_item_id,p_movement_type,p_quantity,balance.quantity,nullif(pg_catalog.btrim(p_reference),''),p_request_id,p_actor_id,selected_cost,case when inbound then selected_value else -selected_value end,balance.stock_value,balance.average_unit_cost,p_source_document_id)
  returning id into movement_id;
  balance_after:=balance.quantity; stock_value_after:=balance.stock_value; average_unit_cost_after:=balance.average_unit_cost; applied_unit_cost:=selected_cost; applied_value:=selected_value; return next;
end;
$fn$;

create or replace function app_private.apply_inventory_delta(p_tenant_id uuid,p_branch_id uuid,p_item_id uuid,p_movement_type text,p_quantity numeric,p_request_id uuid,p_actor_id uuid,p_reference text default null)
returns table(movement_id uuid,balance_after numeric)
language plpgsql volatile security definer set search_path='' set row_security=off as $fn$
declare result record;
begin
  select * into result from app_private.apply_inventory_valuation_delta(p_tenant_id,p_branch_id,p_item_id,p_movement_type,p_quantity,p_request_id,p_actor_id,p_reference,null,null);
  movement_id:=result.movement_id; balance_after:=result.balance_after; return next;
end;
$fn$;

create or replace function public.operational_record_inventory_movement(p_tenant_id uuid,p_branch_id uuid,p_item_id uuid,p_movement_type text,p_quantity numeric,p_request_id uuid,p_reference_note text default null)
returns table(movement_id uuid,balance_after numeric)
language plpgsql volatile security definer set search_path='' set row_security=off as $fn$
declare actor uuid; result record;
begin
  actor:=app_private.assert_operational_permission(p_tenant_id,'transaction.inventory.stock.move',p_branch_id);
  if p_movement_type not in ('initial','entry','exit','adjustment_positive','adjustment_negative') then raise exception 'Invalid inventory movement request' using errcode='22023'; end if;
  select * into result from app_private.apply_inventory_valuation_delta(p_tenant_id,p_branch_id,p_item_id,p_movement_type,p_quantity,p_request_id,actor,p_reference_note,null,null);
  perform app_private.write_operational_audit('inventory.movement.recorded',p_tenant_id,p_branch_id,result.movement_id,actor,pg_catalog.jsonb_build_object('item_id',p_item_id,'movement_type',p_movement_type,'quantity',p_quantity,'balance_after',result.balance_after));
  movement_id:=result.movement_id; balance_after:=result.balance_after; return next;
end;
$fn$;

create function public.operational_record_inventory_movement_valued(p_tenant_id uuid,p_branch_id uuid,p_item_id uuid,p_movement_type text,p_quantity numeric,p_unit_cost numeric,p_request_id uuid,p_reference_note text default null)
returns table(movement_id uuid,balance_after numeric,stock_value_after numeric,average_unit_cost_after numeric)
language plpgsql volatile security definer set search_path='' set row_security=off as $fn$
declare actor uuid; result record;
begin
  actor:=app_private.assert_operational_permission(p_tenant_id,'transaction.inventory.stock.move',p_branch_id);
  if p_movement_type not in ('initial','entry','exit','adjustment_positive','adjustment_negative') then raise exception 'Invalid valued inventory movement request' using errcode='22023'; end if;
  if p_movement_type in ('initial','entry','adjustment_positive') and p_unit_cost is null then raise exception 'Unit cost is required for a valued inbound movement' using errcode='22023'; end if;
  if p_movement_type in ('exit','adjustment_negative') and p_unit_cost is not null then raise exception 'Outbound movements always use the branch moving average cost' using errcode='22023'; end if;
  select * into result from app_private.apply_inventory_valuation_delta(p_tenant_id,p_branch_id,p_item_id,p_movement_type,p_quantity,p_request_id,actor,p_reference_note,p_unit_cost,null);
  perform app_private.write_operational_audit('inventory.movement.recorded',p_tenant_id,p_branch_id,result.movement_id,actor,pg_catalog.jsonb_build_object('item_id',p_item_id,'movement_type',p_movement_type,'quantity',p_quantity,'unit_cost',result.applied_unit_cost,'value',result.applied_value));
  movement_id:=result.movement_id; balance_after:=result.balance_after; stock_value_after:=result.stock_value_after; average_unit_cost_after:=result.average_unit_cost_after; return next;
end;
$fn$;

-- A count line is a physical snapshot, not permission to overwrite movements
-- committed after it was counted.  Acquire the same per-balance advisory lock
-- used by receipts, transfers and O.S. consumption *before* touching the row.
-- This both avoids a row-lock/advisory-lock inversion and makes an obsolete
-- count fail closed, so it must be counted again against the current stock.
create or replace function public.operational_post_inventory_count(p_tenant_id uuid,p_session_id uuid)
returns text language plpgsql volatile security definer set search_path='' set row_security=off as $fn$
declare actor uuid; branch uuid; line record; difference numeric; current_quantity numeric;
begin
  select branch_id into branch from public.inventory_count_sessions where tenant_id=p_tenant_id and id=p_session_id and status='open';
  if not found then return 'unchanged'; end if;
  actor:=app_private.assert_operational_permission(p_tenant_id,'transaction.inventory.physical.adjust',branch);
  for line in select distinct item_id from public.inventory_count_lines where tenant_id=p_tenant_id and session_id=p_session_id order by item_id loop
    perform app_private.lock_inventory_position(p_tenant_id,branch,line.item_id);
  end loop;
  select branch_id into branch from public.inventory_count_sessions where tenant_id=p_tenant_id and id=p_session_id and status='open' for update;
  if not found then return 'unchanged'; end if;
  for line in select * from public.inventory_count_lines where tenant_id=p_tenant_id and session_id=p_session_id order by item_id loop
    perform app_private.lock_inventory_position(p_tenant_id,branch,line.item_id);
    select quantity into current_quantity from public.inventory_balances where tenant_id=p_tenant_id and branch_id=branch and item_id=line.item_id for update;
    current_quantity:=coalesce(current_quantity,0);
    if current_quantity<>line.recorded_quantity then
      raise exception 'Inventory count is stale; recount before posting' using errcode='40001';
    end if;
    difference:=line.counted_quantity-current_quantity;
    if difference<>0 then
      perform * from app_private.apply_inventory_delta(p_tenant_id,branch,line.item_id,
        case when difference>0 then 'physical_count_in' else 'physical_count_out' end,
        abs(difference),pg_catalog.gen_random_uuid(),actor,'Inventory count '||p_session_id::text);
    end if;
  end loop;
  update public.inventory_count_sessions set status='posted',posted_at=pg_catalog.clock_timestamp(),posted_by_user_id=actor where id=p_session_id;
  perform app_private.write_operational_audit('inventory.count.posted',p_tenant_id,branch,p_session_id,actor,'{}');
  return 'posted';
end;
$fn$;

create or replace function public.operational_create_inventory_transfer(p_tenant_id uuid,p_source_branch_id uuid,p_destination_branch_id uuid,p_item_id uuid,p_quantity numeric,p_reference_note text,p_request_id uuid)
returns uuid language plpgsql volatile security definer set search_path='' set row_security=off as $fn$
declare actor uuid; transfer_id uuid; origin_result record; destination_result record;
begin
  actor:=app_private.assert_operational_permission(p_tenant_id,'transaction.inventory.transfer',p_source_branch_id);
  if not app_private.can_access_branch(p_tenant_id,p_destination_branch_id) or not exists(select 1 from public.branches where tenant_id=p_tenant_id and id in (p_source_branch_id,p_destination_branch_id) and status='active' group by tenant_id having count(*)=2) or p_source_branch_id=p_destination_branch_id or p_item_id is null or p_quantity is null or p_quantity<=0 or p_request_id is null then raise exception 'Invalid or unauthorized inventory transfer' using errcode='42501'; end if;
  perform pg_catalog.pg_advisory_xact_lock(pg_catalog.hashtextextended('inventory-transfer:'||p_tenant_id::text||':'||p_request_id::text,0));
  select id into transfer_id from public.inventory_transfers where tenant_id=p_tenant_id and request_id=p_request_id;
  if found then return transfer_id; end if;
  if not exists(select 1 from public.catalog_items where tenant_id=p_tenant_id and id=p_item_id and item_type='product' and status='active') then raise exception 'Active product in this company required' using errcode='23503'; end if;
  perform app_private.lock_inventory_position(p_tenant_id,least(p_source_branch_id,p_destination_branch_id),p_item_id);
  perform app_private.lock_inventory_position(p_tenant_id,greatest(p_source_branch_id,p_destination_branch_id),p_item_id);
  insert into public.inventory_transfers(tenant_id,source_branch_id,destination_branch_id,item_id,quantity,request_id,reference_note,created_by_user_id) values(p_tenant_id,p_source_branch_id,p_destination_branch_id,p_item_id,p_quantity,p_request_id,nullif(pg_catalog.btrim(p_reference_note),''),actor) returning id into transfer_id;
  select * into origin_result from app_private.apply_inventory_valuation_delta(p_tenant_id,p_source_branch_id,p_item_id,'transfer_out',p_quantity,pg_catalog.gen_random_uuid(),actor,'Transfer '||transfer_id::text,null,transfer_id);
  select * into destination_result from app_private.apply_inventory_valuation_delta(p_tenant_id,p_destination_branch_id,p_item_id,'transfer_in',p_quantity,pg_catalog.gen_random_uuid(),actor,'Transfer '||transfer_id::text,origin_result.applied_unit_cost,transfer_id);
  update public.inventory_transfers set unit_cost=origin_result.applied_unit_cost,total_value=origin_result.applied_value where id=transfer_id;
  perform app_private.write_operational_audit('inventory.transfer.created',p_tenant_id,p_source_branch_id,transfer_id,actor,pg_catalog.jsonb_build_object('destination_branch_id',p_destination_branch_id,'item_id',p_item_id,'quantity',p_quantity,'unit_cost',origin_result.applied_unit_cost,'total_value',origin_result.applied_value));
  return transfer_id;
end;
$fn$;

-- Reservations do not alter a balance, but they lock its availability.  They
-- therefore participate in the same inventory-first protocol as consumption
-- and receipt reversal; otherwise reserve × close can form a document/stock
-- lock cycle.
create or replace function public.operational_reserve_work_order_parts(p_tenant_id uuid,p_work_order_id uuid)
returns text language plpgsql volatile security definer set search_path='' set row_security=off as $fn$
declare actor uuid; branch uuid; line record; available numeric; order_status text;
begin
  select branch_id,status into branch,order_status from public.work_orders
   where tenant_id=p_tenant_id and id=p_work_order_id;
  if not found or order_status not in ('open','in_progress') then raise exception 'Reservable work order not found' using errcode='P0002'; end if;
  actor:=app_private.assert_operational_permission(p_tenant_id,'transaction.service_order.update',branch);
  for line in select distinct item_id from public.work_order_lines where tenant_id=p_tenant_id and work_order_id=p_work_order_id and line_type='part' order by item_id loop
    perform app_private.lock_inventory_position(p_tenant_id,branch,line.item_id);
  end loop;
  select status into order_status from public.work_orders where tenant_id=p_tenant_id and id=p_work_order_id for update;
  if order_status not in ('open','in_progress') then raise exception 'Reservable work order not found' using errcode='P0002'; end if;
  for line in select item_id,quantity from public.work_order_lines where tenant_id=p_tenant_id and work_order_id=p_work_order_id and line_type='part' order by item_id loop
    select coalesce(balance.quantity,0)-coalesce((select sum(reservation.quantity) from public.work_order_part_reservations reservation join public.work_orders work_order on work_order.id=reservation.work_order_id where reservation.tenant_id=p_tenant_id and reservation.item_id=line.item_id and reservation.status='reserved' and work_order.branch_id=branch and reservation.work_order_id<>p_work_order_id),0) into available from public.inventory_balances balance where balance.tenant_id=p_tenant_id and balance.branch_id=branch and balance.item_id=line.item_id;
    if coalesce(available,0)<line.quantity then raise exception 'Insufficient available inventory for work order reservation' using errcode='23514'; end if;
    insert into public.work_order_part_reservations(tenant_id,work_order_id,item_id,quantity,status,reserved_by_user_id) values(p_tenant_id,p_work_order_id,line.item_id,line.quantity,'reserved',actor) on conflict(work_order_id,item_id) do update set quantity=excluded.quantity,status='reserved',reserved_by_user_id=excluded.reserved_by_user_id,reserved_at=pg_catalog.clock_timestamp(),consumed_at=null;
  end loop;
  update public.work_orders set status='in_progress',updated_at=pg_catalog.clock_timestamp() where id=p_work_order_id;
  insert into public.work_order_events(tenant_id,work_order_id,event_key,actor_user_id) values(p_tenant_id,p_work_order_id,'work_order.parts_reserved',actor);
  perform app_private.write_operational_audit('work_order.parts_reserved',p_tenant_id,branch,p_work_order_id,actor,'{}');
  return 'reserved';
end;
$fn$;

create or replace function public.operational_close_work_order(p_tenant_id uuid,p_work_order_id uuid)
returns text language plpgsql volatile security definer set search_path='' set row_security=off as $fn$
declare actor uuid; branch uuid; line record; result record; order_status text;
begin
  select branch_id,status into branch,order_status from public.work_orders where tenant_id=p_tenant_id and id=p_work_order_id; if not found then raise exception 'Work order not found' using errcode='P0002'; end if;
  actor:=app_private.assert_operational_permission(p_tenant_id,'transaction.service_order.close',branch);
  if order_status='closed' then return 'closed'; end if;
  if order_status not in ('in_progress','open') then raise exception 'Only open or in-progress work orders may close' using errcode='22023'; end if;
  for line in select distinct item_id from public.work_order_part_reservations where tenant_id=p_tenant_id and work_order_id=p_work_order_id and status='reserved' order by item_id loop
    perform app_private.lock_inventory_position(p_tenant_id,branch,line.item_id);
  end loop;
  select status into order_status from public.work_orders where tenant_id=p_tenant_id and id=p_work_order_id for update;
  if order_status='closed' then return 'closed'; end if;
  if order_status not in ('in_progress','open') then raise exception 'Only open or in-progress work orders may close' using errcode='22023'; end if;
  if exists(select 1 from public.work_order_lines l where l.tenant_id=p_tenant_id and l.work_order_id=p_work_order_id and l.line_type='part' and not exists(select 1 from public.work_order_part_reservations r where r.work_order_id=p_work_order_id and r.item_id=l.item_id and r.status='reserved')) then raise exception 'Parts must be reserved before closing the work order' using errcode='23514'; end if;
  for line in select * from public.work_order_part_reservations where tenant_id=p_tenant_id and work_order_id=p_work_order_id and status='reserved' order by item_id for update loop
    select * into result from app_private.apply_inventory_valuation_delta(p_tenant_id,branch,line.item_id,'service_consumption',line.quantity,pg_catalog.gen_random_uuid(),actor,'Work order '||p_work_order_id::text,null,p_work_order_id);
    update public.work_order_part_reservations set status='consumed',consumed_at=pg_catalog.clock_timestamp(),consumed_unit_cost=result.applied_unit_cost,consumed_value=result.applied_value where work_order_id=p_work_order_id and item_id=line.item_id;
  end loop;
  update public.work_orders set status='closed',closed_at=pg_catalog.clock_timestamp(),closed_by_user_id=actor,updated_at=pg_catalog.clock_timestamp() where id=p_work_order_id;
  insert into public.work_order_events(tenant_id,work_order_id,event_key,actor_user_id) values(p_tenant_id,p_work_order_id,'work_order.closed',actor);
  perform app_private.write_operational_audit('work_order.closed',p_tenant_id,branch,p_work_order_id,actor,'{}'); return 'closed';
end;
$fn$;

create or replace function public.operational_reverse_work_order_consumption(p_tenant_id uuid,p_work_order_id uuid)
returns text language plpgsql volatile security definer set search_path='' set row_security=off as $fn$
declare actor uuid; branch uuid; line record; order_status text;
begin
  select branch_id,status into branch,order_status from public.work_orders where tenant_id=p_tenant_id and id=p_work_order_id; if not found then raise exception 'Work order not found' using errcode='P0002'; end if;
  actor:=app_private.assert_operational_permission(p_tenant_id,'transaction.service_order.close',branch);
  if order_status='reversed' then return 'reversed'; end if;
  if order_status<>'closed' then raise exception 'Closed work order not found' using errcode='P0002'; end if;
  for line in select distinct item_id from public.work_order_part_reservations where tenant_id=p_tenant_id and work_order_id=p_work_order_id and status='consumed' order by item_id loop
    perform app_private.lock_inventory_position(p_tenant_id,branch,line.item_id);
  end loop;
  select status into order_status from public.work_orders where tenant_id=p_tenant_id and id=p_work_order_id for update;
  if order_status='reversed' then return 'reversed'; end if;
  if order_status<>'closed' then raise exception 'Closed work order not found' using errcode='P0002'; end if;
  for line in select * from public.work_order_part_reservations where tenant_id=p_tenant_id and work_order_id=p_work_order_id and status='consumed' order by item_id for update loop
    if line.consumed_unit_cost is null then raise exception 'Legacy work-order consumption cannot be reversed through valued inventory without controlled correction' using errcode='55000'; end if;
    perform * from app_private.apply_inventory_valuation_delta(p_tenant_id,branch,line.item_id,'service_reversal',line.quantity,pg_catalog.gen_random_uuid(),actor,'Work order reversal '||p_work_order_id::text,line.consumed_unit_cost,p_work_order_id);
    update public.work_order_part_reservations set status='reversed' where work_order_id=p_work_order_id and item_id=line.item_id;
  end loop;
  update public.work_orders set status='reversed',updated_at=pg_catalog.clock_timestamp() where id=p_work_order_id;
  insert into public.work_order_events(tenant_id,work_order_id,event_key,actor_user_id) values(p_tenant_id,p_work_order_id,'work_order.reversed',actor);
  perform app_private.write_operational_audit('work_order.reversed',p_tenant_id,branch,p_work_order_id,actor,'{}'); return 'reversed';
end;
$fn$;

create function public.operational_submit_purchase_order(p_tenant_id uuid,p_purchase_order_id uuid,p_request_id uuid)
returns text language plpgsql volatile security definer set search_path='' set row_security=off as $fn$
declare actor uuid; branch uuid; existing_order_id uuid;
begin
  select branch_id into branch from public.purchase_orders where tenant_id=p_tenant_id and id=p_purchase_order_id for update;
  if not found then raise exception 'Purchase order not found' using errcode='P0002'; end if;
  actor:=app_private.assert_operational_permission(p_tenant_id,'transaction.purchasing.purchase_order.create',branch);
  if p_request_id is null then raise exception 'Request identifier is required' using errcode='22023'; end if;
  perform pg_catalog.pg_advisory_xact_lock(pg_catalog.hashtextextended('purchase-order-submit:'||p_tenant_id::text||':'||p_request_id::text,0));
  select purchase_order_id into existing_order_id from app_private.purchase_order_update_requests where tenant_id=p_tenant_id and request_id=p_request_id;
  if found then
    if existing_order_id<>p_purchase_order_id then raise exception 'Purchase-order request identifier belongs to another order' using errcode='23505'; end if;
    return 'submitted';
  end if;
  if (select status from public.purchase_orders where id=p_purchase_order_id)='submitted' then return 'submitted'; end if;
  if (select status from public.purchase_orders where id=p_purchase_order_id)<>'draft' then raise exception 'Only draft purchase orders may be submitted' using errcode='55000'; end if;
  update public.purchase_orders set status='submitted',updated_at=pg_catalog.clock_timestamp() where tenant_id=p_tenant_id and id=p_purchase_order_id;
  insert into app_private.purchase_order_update_requests(tenant_id,purchase_order_id,request_id) values(p_tenant_id,p_purchase_order_id,p_request_id);
  perform app_private.write_operational_audit('purchase_order.submitted',p_tenant_id,branch,p_purchase_order_id,actor,pg_catalog.jsonb_build_object('request_id',p_request_id));
  return 'submitted';
end;
$fn$;

create function public.operational_receive_purchase_order(p_tenant_id uuid,p_purchase_order_id uuid,p_lines jsonb,p_document_number text,p_notes text,p_request_id uuid)
returns uuid language plpgsql volatile security definer set search_path='' set row_security=off as $fn$
declare actor uuid; branch uuid; order_status text; receipt_id uuid; receipt_number bigint; payload jsonb; existing_payload jsonb; line record; order_line record; prior_received numeric; result record; line_count integer; inserted_count integer; all_received boolean;
begin
  if p_purchase_order_id is null or p_request_id is null or p_lines is null or pg_catalog.jsonb_typeof(p_lines)<>'array' or pg_catalog.jsonb_array_length(p_lines) not between 1 and 100 or pg_catalog.length(pg_catalog.btrim(coalesce(p_document_number,'')))>120 or pg_catalog.length(pg_catalog.btrim(coalesce(p_notes,'')))>1000 then raise exception 'Invalid purchase receipt request' using errcode='22023'; end if;
  payload:=pg_catalog.jsonb_build_object('purchase_order_id',p_purchase_order_id,'document_number',nullif(pg_catalog.btrim(p_document_number),''),'notes',nullif(pg_catalog.btrim(p_notes),''),'lines',p_lines);
  perform pg_catalog.pg_advisory_xact_lock(pg_catalog.hashtextextended('purchase-receipt:'||p_tenant_id::text||':'||p_request_id::text,0));
  select id,request_payload into receipt_id,existing_payload from public.purchase_receipts where tenant_id=p_tenant_id and request_id=p_request_id;
  if found then
    if existing_payload is distinct from payload then raise exception 'Purchase receipt request identifier belongs to a different payload' using errcode='23505'; end if;
    return receipt_id;
  end if;
  -- Read only enough document data to establish the authorized branch.  The
  -- actual document row is locked only after every affected inventory position
  -- is locked in the global (tenant, branch, item) order below.
  select branch_id,status into branch,order_status from public.purchase_orders where tenant_id=p_tenant_id and id=p_purchase_order_id;
  if not found then raise exception 'Purchase order not found' using errcode='P0002'; end if;
  actor:=app_private.assert_operational_permission(p_tenant_id,'transaction.purchasing.receipt.manage',branch);
  if order_status not in ('submitted','partially_received') then raise exception 'Only submitted purchase orders may be received' using errcode='55000'; end if;
  select count(*),count(distinct x.purchase_order_item_id) into line_count,inserted_count from pg_catalog.jsonb_to_recordset(p_lines) as x(purchase_order_item_id uuid,quantity numeric,effective_unit_cost numeric,variance_reason text);
  if line_count<>pg_catalog.jsonb_array_length(p_lines) or line_count<>inserted_count or exists(select 1 from pg_catalog.jsonb_to_recordset(p_lines) as x(purchase_order_item_id uuid,quantity numeric,effective_unit_cost numeric,variance_reason text) where x.purchase_order_item_id is null or x.quantity is null or x.quantity<=0 or x.effective_unit_cost is null or x.effective_unit_cost<0 or (x.variance_reason is not null and pg_catalog.length(pg_catalog.btrim(x.variance_reason))>1000)) then raise exception 'Invalid purchase receipt lines' using errcode='22023'; end if;
  select count(*) into inserted_count
    from pg_catalog.jsonb_to_recordset(p_lines) as x(purchase_order_item_id uuid,quantity numeric,effective_unit_cost numeric,variance_reason text)
    join public.purchase_order_items order_item
      on order_item.tenant_id=p_tenant_id
     and order_item.purchase_order_id=p_purchase_order_id
     and order_item.id=x.purchase_order_item_id;
  if inserted_count<>line_count then raise exception 'Receipt line does not belong to this purchase order' using errcode='23503'; end if;
  for line in
    select distinct order_item.item_id
      from pg_catalog.jsonb_to_recordset(p_lines) as x(purchase_order_item_id uuid,quantity numeric,effective_unit_cost numeric,variance_reason text)
      join public.purchase_order_items order_item
        on order_item.tenant_id=p_tenant_id
       and order_item.purchase_order_id=p_purchase_order_id
       and order_item.id=x.purchase_order_item_id
     order by order_item.item_id
  loop
    perform app_private.lock_inventory_position(p_tenant_id,branch,line.item_id);
  end loop;
  select status into order_status from public.purchase_orders
   where tenant_id=p_tenant_id and id=p_purchase_order_id for update;
  if order_status not in ('submitted','partially_received') then raise exception 'Only submitted purchase orders may be received' using errcode='55000'; end if;
  receipt_number:=app_private.next_purchase_receipt_number(p_tenant_id);
  insert into public.purchase_receipts(tenant_id,branch_id,purchase_order_id,receipt_number,document_number,notes,request_payload,request_id,created_by_user_id) values(p_tenant_id,branch,p_purchase_order_id,receipt_number,nullif(pg_catalog.btrim(p_document_number),''),nullif(pg_catalog.btrim(p_notes),''),payload,p_request_id,actor) returning id into receipt_id;
  for line in
    select x.*
      from pg_catalog.jsonb_to_recordset(p_lines) as x(purchase_order_item_id uuid,quantity numeric,effective_unit_cost numeric,variance_reason text)
      join public.purchase_order_items order_item
        on order_item.tenant_id=p_tenant_id
       and order_item.purchase_order_id=p_purchase_order_id
       and order_item.id=x.purchase_order_item_id
     order by order_item.item_id,order_item.id
  loop
    select * into order_line from public.purchase_order_items where tenant_id=p_tenant_id and purchase_order_id=p_purchase_order_id and id=line.purchase_order_item_id for update;
    if not found then raise exception 'Receipt line does not belong to this purchase order' using errcode='23503'; end if;
    if pg_catalog.round(line.effective_unit_cost,8)<>pg_catalog.round(order_line.unit_price,8) and pg_catalog.length(pg_catalog.btrim(coalesce(line.variance_reason,'')))=0 then raise exception 'A justification is required when the effective receipt cost differs from the purchase order' using errcode='22023'; end if;
    select coalesce(sum(item.received_quantity),0)-coalesce((select sum(reversed.reversed_quantity) from public.purchase_receipt_reversal_items reversed join public.purchase_receipt_items source_item on source_item.id=reversed.purchase_receipt_item_id where source_item.tenant_id=p_tenant_id and source_item.purchase_order_item_id=order_line.id),0) into prior_received from public.purchase_receipt_items item join public.purchase_receipts receipt on receipt.id=item.purchase_receipt_id where item.tenant_id=p_tenant_id and item.purchase_order_item_id=order_line.id and receipt.status in ('posted','partially_reversed','reversed');
    if prior_received+line.quantity>order_line.quantity then raise exception 'Receipt quantity exceeds the remaining quantity of the purchase-order item' using errcode='23514'; end if;
    select * into result from app_private.apply_inventory_valuation_delta(p_tenant_id,branch,order_line.item_id,'purchase_receipt',line.quantity,pg_catalog.gen_random_uuid(),actor,'Purchase receipt '||receipt_id::text,line.effective_unit_cost,receipt_id);
    insert into public.purchase_receipt_items(tenant_id,purchase_receipt_id,purchase_order_item_id,item_id,received_quantity,effective_unit_cost,received_value,variance_reason,inventory_movement_id) values(p_tenant_id,receipt_id,order_line.id,order_line.item_id,line.quantity,result.applied_unit_cost,result.applied_value,nullif(pg_catalog.btrim(line.variance_reason),''),result.movement_id);
  end loop;
  select bool_and(coalesce(received.net_quantity,0)>=order_item.quantity) into all_received from public.purchase_order_items order_item left join lateral (select coalesce(sum(receipt_item.received_quantity),0)-coalesce((select sum(reversal_item.reversed_quantity) from public.purchase_receipt_reversal_items reversal_item join public.purchase_receipt_items reversal_source on reversal_source.id=reversal_item.purchase_receipt_item_id where reversal_source.purchase_order_item_id=order_item.id),0) as net_quantity from public.purchase_receipt_items receipt_item where receipt_item.purchase_order_item_id=order_item.id) received on true where order_item.tenant_id=p_tenant_id and order_item.purchase_order_id=p_purchase_order_id;
  update public.purchase_orders set status=case when all_received then 'received' else 'partially_received' end,updated_at=pg_catalog.clock_timestamp() where tenant_id=p_tenant_id and id=p_purchase_order_id;
  perform app_private.write_operational_audit('purchase_receipt.created',p_tenant_id,branch,receipt_id,actor,pg_catalog.jsonb_build_object('purchase_order_id',p_purchase_order_id,'receipt_number',receipt_number,'request_id',p_request_id));
  return receipt_id;
end;
$fn$;

create function public.operational_reverse_purchase_receipt(p_tenant_id uuid,p_purchase_receipt_id uuid,p_lines jsonb,p_reason text,p_request_id uuid)
returns uuid language plpgsql volatile security definer set search_path='' set row_security=off as $fn$
declare actor uuid; branch uuid; receipt_order uuid; reversal_id uuid; payload jsonb; existing_payload jsonb; line record; receipt_line record; already_reversed numeric; available_unreserved numeric; result record; line_count integer; inserted_count integer; receipt_remaining boolean; all_received boolean;
begin
  if p_purchase_receipt_id is null or p_request_id is null or p_lines is null or pg_catalog.jsonb_typeof(p_lines)<>'array' or pg_catalog.jsonb_array_length(p_lines) not between 1 and 100 or pg_catalog.length(pg_catalog.btrim(coalesce(p_reason,''))) not between 1 and 1000 then raise exception 'Invalid receipt reversal request' using errcode='22023'; end if;
  payload:=pg_catalog.jsonb_build_object('purchase_receipt_id',p_purchase_receipt_id,'reason',pg_catalog.btrim(p_reason),'lines',p_lines);
  perform pg_catalog.pg_advisory_xact_lock(pg_catalog.hashtextextended('purchase-receipt-reversal:'||p_tenant_id::text||':'||p_request_id::text,0));
  select id,request_payload into reversal_id,existing_payload from public.purchase_receipt_reversals where tenant_id=p_tenant_id and request_id=p_request_id;
  if found then
    if existing_payload is distinct from payload then raise exception 'Purchase receipt reversal request identifier belongs to a different payload' using errcode='23505'; end if;
    return reversal_id;
  end if;
  -- Establish authorization without locking the receipt.  We must obtain every
  -- stock-position advisory lock first, otherwise a reversal can deadlock with
  -- receipt, transfer, count or O.S. consumption paths that use inventory-first.
  select branch_id,purchase_order_id into branch,receipt_order from public.purchase_receipts where tenant_id=p_tenant_id and id=p_purchase_receipt_id and status in ('posted','partially_reversed');
  if not found then raise exception 'Posted purchase receipt not found' using errcode='P0002'; end if;
  actor:=app_private.assert_operational_permission(p_tenant_id,'transaction.purchasing.receipt.manage',branch);
  select count(*),count(distinct x.purchase_receipt_item_id) into line_count,inserted_count from pg_catalog.jsonb_to_recordset(p_lines) as x(purchase_receipt_item_id uuid,quantity numeric);
  if line_count<>pg_catalog.jsonb_array_length(p_lines) or line_count<>inserted_count or exists(select 1 from pg_catalog.jsonb_to_recordset(p_lines) as x(purchase_receipt_item_id uuid,quantity numeric) where x.purchase_receipt_item_id is null or x.quantity is null or x.quantity<=0) then raise exception 'Invalid receipt reversal lines' using errcode='22023'; end if;
  select count(*) into inserted_count
    from pg_catalog.jsonb_to_recordset(p_lines) as x(purchase_receipt_item_id uuid,quantity numeric)
    join public.purchase_receipt_items receipt_item
      on receipt_item.tenant_id=p_tenant_id
     and receipt_item.purchase_receipt_id=p_purchase_receipt_id
     and receipt_item.id=x.purchase_receipt_item_id;
  if inserted_count<>line_count then raise exception 'Receipt reversal item does not belong to this receipt' using errcode='23503'; end if;
  for line in
    select distinct receipt_item.item_id
      from pg_catalog.jsonb_to_recordset(p_lines) as x(purchase_receipt_item_id uuid,quantity numeric)
      join public.purchase_receipt_items receipt_item
        on receipt_item.tenant_id=p_tenant_id
       and receipt_item.purchase_receipt_id=p_purchase_receipt_id
       and receipt_item.id=x.purchase_receipt_item_id
     order by receipt_item.item_id
  loop
    perform app_private.lock_inventory_position(p_tenant_id,branch,line.item_id);
  end loop;
  select purchase_order_id into receipt_order from public.purchase_receipts
   where tenant_id=p_tenant_id and id=p_purchase_receipt_id and status in ('posted','partially_reversed') for update;
  if not found then raise exception 'Posted purchase receipt not found' using errcode='P0002'; end if;
  insert into public.purchase_receipt_reversals(tenant_id,branch_id,purchase_receipt_id,reason,request_payload,request_id,created_by_user_id) values(p_tenant_id,branch,p_purchase_receipt_id,pg_catalog.btrim(p_reason),payload,p_request_id,actor) returning id into reversal_id;
  for line in
    select x.*
      from pg_catalog.jsonb_to_recordset(p_lines) as x(purchase_receipt_item_id uuid,quantity numeric)
      join public.purchase_receipt_items receipt_item
        on receipt_item.tenant_id=p_tenant_id
       and receipt_item.purchase_receipt_id=p_purchase_receipt_id
       and receipt_item.id=x.purchase_receipt_item_id
     order by receipt_item.item_id,receipt_item.id
  loop
    select * into receipt_line from public.purchase_receipt_items where tenant_id=p_tenant_id and id=line.purchase_receipt_item_id and purchase_receipt_id=p_purchase_receipt_id for update;
    if not found then raise exception 'Receipt reversal item does not belong to this receipt' using errcode='23503'; end if;
    select coalesce(sum(reversed_quantity),0) into already_reversed from public.purchase_receipt_reversal_items where tenant_id=p_tenant_id and purchase_receipt_item_id=receipt_line.id;
    if already_reversed+line.quantity>receipt_line.received_quantity then raise exception 'Receipt reversal quantity exceeds the available received quantity' using errcode='23514'; end if;
    perform app_private.assert_purchase_receipt_reversal_traceability(p_tenant_id,branch,p_purchase_receipt_id,receipt_line.item_id);
    select coalesce(balance.quantity,0)-coalesce((select sum(reservation.quantity) from public.work_order_part_reservations reservation join public.work_orders work_order on work_order.id=reservation.work_order_id where reservation.tenant_id=p_tenant_id and reservation.item_id=receipt_line.item_id and reservation.status='reserved' and work_order.branch_id=branch),0) into available_unreserved from public.inventory_balances balance where balance.tenant_id=p_tenant_id and balance.branch_id=branch and balance.item_id=receipt_line.item_id for update;
    if coalesce(available_unreserved,0)<line.quantity then raise exception 'Receipt reversal would violate reserved or unavailable inventory' using errcode='23514'; end if;
    select * into result from app_private.apply_inventory_valuation_delta(p_tenant_id,branch,receipt_line.item_id,'purchase_receipt_reversal',line.quantity,pg_catalog.gen_random_uuid(),actor,'Purchase receipt reversal '||reversal_id::text,receipt_line.effective_unit_cost,reversal_id);
    insert into public.purchase_receipt_reversal_items(tenant_id,purchase_receipt_reversal_id,purchase_receipt_item_id,item_id,reversed_quantity,unit_cost,reversed_value,inventory_movement_id) values(p_tenant_id,reversal_id,receipt_line.id,receipt_line.item_id,line.quantity,receipt_line.effective_unit_cost,result.applied_value,result.movement_id);
  end loop;
  select exists(select 1 from public.purchase_receipt_items item where item.purchase_receipt_id=p_purchase_receipt_id and item.received_quantity>coalesce((select sum(reversed_quantity) from public.purchase_receipt_reversal_items reversed where reversed.purchase_receipt_item_id=item.id),0)) into receipt_remaining;
  update public.purchase_receipts set status=case when receipt_remaining then 'partially_reversed' else 'reversed' end,reversed_at=case when receipt_remaining then null else pg_catalog.clock_timestamp() end where id=p_purchase_receipt_id;
  select bool_and(coalesce(received.net_quantity,0)>=order_item.quantity) into all_received from public.purchase_order_items order_item left join lateral (select coalesce(sum(receipt_item.received_quantity),0)-coalesce((select sum(reversal_item.reversed_quantity) from public.purchase_receipt_reversal_items reversal_item join public.purchase_receipt_items reversal_source on reversal_source.id=reversal_item.purchase_receipt_item_id where reversal_source.purchase_order_item_id=order_item.id),0) as net_quantity from public.purchase_receipt_items receipt_item where receipt_item.purchase_order_item_id=order_item.id) received on true where order_item.tenant_id=p_tenant_id and order_item.purchase_order_id=receipt_order;
  update public.purchase_orders set status=case when all_received then 'received' when exists(select 1 from public.purchase_receipt_items item where item.purchase_order_item_id in (select id from public.purchase_order_items where purchase_order_id=receipt_order)) then 'partially_received' else 'submitted' end,updated_at=pg_catalog.clock_timestamp() where tenant_id=p_tenant_id and id=receipt_order;
  perform app_private.write_operational_audit('purchase_receipt.reversed',p_tenant_id,branch,reversal_id,actor,pg_catalog.jsonb_build_object('purchase_receipt_id',p_purchase_receipt_id,'request_id',p_request_id));
  return reversal_id;
end;
$fn$;

create function public.operational_record_initial_inventory_valuation(p_tenant_id uuid,p_branch_id uuid,p_item_id uuid,p_unit_cost numeric,p_reason text,p_request_id uuid)
returns uuid language plpgsql volatile security definer set search_path='' set row_security=off as $fn$
declare actor uuid; balance public.inventory_balances%rowtype; event_id uuid; total_value numeric;
begin
  actor:=app_private.assert_operational_permission(p_tenant_id,'transaction.inventory.valuation.initial',p_branch_id);
  if p_item_id is null or p_request_id is null or p_unit_cost is null or p_unit_cost<0 or pg_catalog.length(pg_catalog.btrim(coalesce(p_reason,''))) not between 1 and 1000 then raise exception 'Invalid initial inventory valuation request' using errcode='22023'; end if;
  perform pg_catalog.pg_advisory_xact_lock(pg_catalog.hashtextextended('inventory-valuation:'||p_tenant_id::text||':'||p_branch_id::text||':'||p_item_id::text,0));
  select id into event_id from public.inventory_valuation_events where tenant_id=p_tenant_id and request_id=p_request_id;
  if found then return event_id; end if;
  perform app_private.lock_inventory_position(p_tenant_id,p_branch_id,p_item_id);
  insert into public.inventory_balances(tenant_id,branch_id,item_id,quantity) values(p_tenant_id,p_branch_id,p_item_id,0) on conflict do nothing;
  select * into balance from public.inventory_balances where tenant_id=p_tenant_id and branch_id=p_branch_id and item_id=p_item_id for update;
  if balance.valuation_status<>'pending' or balance.quantity<=0 then raise exception 'Only pending nonzero legacy stock may receive an initial valuation' using errcode='55000'; end if;
  total_value:=pg_catalog.round(balance.quantity*p_unit_cost,8);
  update public.inventory_balances set valuation_status='valued',stock_value=total_value,average_unit_cost=pg_catalog.round(p_unit_cost,8),valuation_updated_at=pg_catalog.clock_timestamp(),updated_at=pg_catalog.clock_timestamp() where tenant_id=p_tenant_id and branch_id=p_branch_id and item_id=p_item_id;
  insert into public.inventory_valuation_events(tenant_id,branch_id,item_id,event_type,quantity_at_valuation,unit_cost,stock_value,reason,request_id,created_by_user_id) values(p_tenant_id,p_branch_id,p_item_id,'initial_valuation',balance.quantity,pg_catalog.round(p_unit_cost,8),total_value,pg_catalog.btrim(p_reason),p_request_id,actor) returning id into event_id;
  perform app_private.write_operational_audit('inventory.initial_valuation.recorded',p_tenant_id,p_branch_id,event_id,actor,pg_catalog.jsonb_build_object('item_id',p_item_id,'quantity',balance.quantity,'unit_cost',p_unit_cost,'stock_value',total_value));
  return event_id;
end;
$fn$;

create function public.operational_list_purchase_receiving(p_tenant_id uuid,p_branch_id uuid,p_limit integer default 50,p_offset integer default 0)
returns table(purchase_order_id uuid,order_number bigint,status text,supplier_name text,items jsonb,created_at timestamptz,updated_at timestamptz)
language plpgsql stable security definer set search_path='' set row_security=off as $fn$
begin
  perform app_private.assert_operational_permission(p_tenant_id,'transaction.purchasing.receipt.manage',p_branch_id);
  if p_limit not between 1 and 100 or p_offset<0 then raise exception 'Invalid purchase receiving listing request' using errcode='22023'; end if;
  return query select purchase_order.id,purchase_order.order_number,purchase_order.status,supplier.legal_name,coalesce((select pg_catalog.jsonb_agg(pg_catalog.jsonb_build_object('purchase_order_item_id',order_item.id,'item_id',order_item.item_id,'item_code',catalog.code,'item_name',catalog.name,'ordered_quantity',order_item.quantity,'received_quantity',coalesce(received.quantity,0),'pending_quantity',order_item.quantity-coalesce(received.quantity,0),'ordered_unit_price',order_item.unit_price) order by order_item.line_number) from public.purchase_order_items order_item join public.catalog_items catalog on catalog.tenant_id=order_item.tenant_id and catalog.id=order_item.item_id left join lateral (select coalesce(sum(receipt_item.received_quantity),0)-coalesce((select sum(reversal_item.reversed_quantity) from public.purchase_receipt_reversal_items reversal_item join public.purchase_receipt_items reversal_source on reversal_source.id=reversal_item.purchase_receipt_item_id where reversal_source.purchase_order_item_id=order_item.id),0) as quantity from public.purchase_receipt_items receipt_item where receipt_item.purchase_order_item_id=order_item.id) received on true where order_item.tenant_id=p_tenant_id and order_item.purchase_order_id=purchase_order.id),'[]'::jsonb),purchase_order.created_at,purchase_order.updated_at from public.purchase_orders purchase_order join public.business_parties supplier on supplier.tenant_id=purchase_order.tenant_id and supplier.id=purchase_order.supplier_id where purchase_order.tenant_id=p_tenant_id and purchase_order.branch_id=p_branch_id and purchase_order.status in ('submitted','partially_received','received') order by purchase_order.updated_at desc,purchase_order.id desc limit p_limit offset p_offset;
end;
$fn$;

create function public.operational_list_purchase_receipts(p_tenant_id uuid,p_branch_id uuid,p_purchase_order_id uuid default null,p_limit integer default 50,p_offset integer default 0)
returns table(purchase_receipt_id uuid,receipt_number bigint,purchase_order_id uuid,status text,document_number text,notes text,items jsonb,created_at timestamptz)
language plpgsql stable security definer set search_path='' set row_security=off as $fn$
begin
  perform app_private.assert_operational_permission(p_tenant_id,'transaction.purchasing.receipt.manage',p_branch_id);
  if p_limit not between 1 and 100 or p_offset<0 then raise exception 'Invalid purchase receipt listing request' using errcode='22023'; end if;
  return query select receipt.id,receipt.receipt_number,receipt.purchase_order_id,receipt.status,receipt.document_number,receipt.notes,coalesce((select pg_catalog.jsonb_agg(pg_catalog.jsonb_build_object('purchase_receipt_item_id',item.id,'item_id',item.item_id,'received_quantity',item.received_quantity,'effective_unit_cost',item.effective_unit_cost,'received_value',item.received_value,'reversed_quantity',coalesce((select sum(reversal.reversed_quantity) from public.purchase_receipt_reversal_items reversal where reversal.purchase_receipt_item_id=item.id),0),'variance_reason',item.variance_reason) order by item.created_at,item.id) from public.purchase_receipt_items item where item.purchase_receipt_id=receipt.id),'[]'::jsonb),receipt.created_at from public.purchase_receipts receipt where receipt.tenant_id=p_tenant_id and receipt.branch_id=p_branch_id and (p_purchase_order_id is null or receipt.purchase_order_id=p_purchase_order_id) order by receipt.created_at desc,receipt.id desc limit p_limit offset p_offset;
end;
$fn$;

create function public.operational_list_inventory_valuation(p_tenant_id uuid,p_branch_id uuid,p_limit integer default 100,p_offset integer default 0)
returns table(item_id uuid,item_code text,item_name text,quantity numeric,valuation_status text,stock_value numeric,average_unit_cost numeric,valuation_updated_at timestamptz)
language plpgsql stable security definer set search_path='' set row_security=off as $fn$
begin
  perform app_private.assert_operational_permission(p_tenant_id,'transaction.inventory.valuation.initial',p_branch_id);
  if p_limit not between 1 and 100 or p_offset<0 then raise exception 'Invalid inventory valuation listing request' using errcode='22023'; end if;
  return query select item.id,item.code,item.name,coalesce(balance.quantity,0),coalesce(balance.valuation_status,'pending'),balance.stock_value,balance.average_unit_cost,balance.valuation_updated_at from public.catalog_items item left join public.inventory_balances balance on balance.tenant_id=item.tenant_id and balance.branch_id=p_branch_id and balance.item_id=item.id where item.tenant_id=p_tenant_id and item.item_type='product' and item.status='active' order by item.code,item.id limit p_limit offset p_offset;
end;
$fn$;

alter function app_private.assert_operational_permission(uuid,text,uuid) owner to postgres;
alter function app_private.next_purchase_receipt_number(uuid) owner to postgres;
alter function app_private.lock_inventory_position(uuid,uuid,uuid) owner to postgres;
alter function app_private.assert_purchase_receipt_reversal_traceability(uuid,uuid,uuid,uuid) owner to postgres;
alter function app_private.apply_inventory_valuation_delta(uuid,uuid,uuid,text,numeric,uuid,uuid,text,numeric,uuid) owner to postgres;
alter function app_private.apply_inventory_delta(uuid,uuid,uuid,text,numeric,uuid,uuid,text) owner to postgres;
alter function public.operational_record_inventory_movement(uuid,uuid,uuid,text,numeric,uuid,text) owner to postgres;
alter function public.operational_record_inventory_movement_valued(uuid,uuid,uuid,text,numeric,numeric,uuid,text) owner to postgres;
alter function public.operational_create_inventory_transfer(uuid,uuid,uuid,uuid,numeric,text,uuid) owner to postgres;
alter function public.operational_post_inventory_count(uuid,uuid) owner to postgres;
alter function public.operational_reserve_work_order_parts(uuid,uuid) owner to postgres;
alter function public.operational_close_work_order(uuid,uuid) owner to postgres;
alter function public.operational_reverse_work_order_consumption(uuid,uuid) owner to postgres;
alter function public.operational_submit_purchase_order(uuid,uuid,uuid) owner to postgres;
alter function public.operational_receive_purchase_order(uuid,uuid,jsonb,text,text,uuid) owner to postgres;
alter function public.operational_reverse_purchase_receipt(uuid,uuid,jsonb,text,uuid) owner to postgres;
alter function public.operational_record_initial_inventory_valuation(uuid,uuid,uuid,numeric,text,uuid) owner to postgres;
alter function public.operational_list_purchase_receiving(uuid,uuid,integer,integer) owner to postgres;
alter function public.operational_list_purchase_receipts(uuid,uuid,uuid,integer,integer) owner to postgres;
alter function public.operational_list_inventory_valuation(uuid,uuid,integer,integer) owner to postgres;

revoke all on function app_private.next_purchase_receipt_number(uuid),app_private.lock_inventory_position(uuid,uuid,uuid),app_private.assert_purchase_receipt_reversal_traceability(uuid,uuid,uuid,uuid),app_private.apply_inventory_valuation_delta(uuid,uuid,uuid,text,numeric,uuid,uuid,text,numeric,uuid) from public,anon,authenticated,service_role;
revoke all on function public.operational_record_inventory_movement_valued(uuid,uuid,uuid,text,numeric,numeric,uuid,text),public.operational_submit_purchase_order(uuid,uuid,uuid),public.operational_receive_purchase_order(uuid,uuid,jsonb,text,text,uuid),public.operational_reverse_purchase_receipt(uuid,uuid,jsonb,text,uuid),public.operational_record_initial_inventory_valuation(uuid,uuid,uuid,numeric,text,uuid),public.operational_list_purchase_receiving(uuid,uuid,integer,integer),public.operational_list_purchase_receipts(uuid,uuid,uuid,integer,integer),public.operational_list_inventory_valuation(uuid,uuid,integer,integer) from public,anon,authenticated,service_role;
grant execute on function public.operational_record_inventory_movement_valued(uuid,uuid,uuid,text,numeric,numeric,uuid,text),public.operational_submit_purchase_order(uuid,uuid,uuid),public.operational_receive_purchase_order(uuid,uuid,jsonb,text,text,uuid),public.operational_reverse_purchase_receipt(uuid,uuid,jsonb,text,uuid),public.operational_record_initial_inventory_valuation(uuid,uuid,uuid,numeric,text,uuid),public.operational_list_purchase_receiving(uuid,uuid,integer,integer),public.operational_list_purchase_receipts(uuid,uuid,uuid,integer,integer),public.operational_list_inventory_valuation(uuid,uuid,integer,integer) to authenticated;

do $verify$
declare routine text; routine_oid oid;
begin
  if exists(select 1 from public.role_permission_grants where permission_key in ('transaction.purchasing.receipt.manage','transaction.inventory.valuation.initial'))
    or exists(select 1 from public.company_transaction_availability where transaction_code in ('ZGR01','ZIV01') and enabled) then
    raise exception 'Phase 01 migration must not grant or enable new operational access';
  end if;
  foreach routine in array array[
    'public.operational_record_inventory_movement_valued(uuid,uuid,uuid,text,numeric,numeric,uuid,text)',
    'public.operational_post_inventory_count(uuid,uuid)',
    'public.operational_submit_purchase_order(uuid,uuid,uuid)',
    'public.operational_receive_purchase_order(uuid,uuid,jsonb,text,text,uuid)',
    'public.operational_reverse_purchase_receipt(uuid,uuid,jsonb,text,uuid)',
    'public.operational_record_initial_inventory_valuation(uuid,uuid,uuid,numeric,text,uuid)',
    'public.operational_list_purchase_receiving(uuid,uuid,integer,integer)',
    'public.operational_list_purchase_receipts(uuid,uuid,uuid,integer,integer)',
    'public.operational_list_inventory_valuation(uuid,uuid,integer,integer)'
  ] loop
    routine_oid:=pg_catalog.to_regprocedure(routine);
    if routine_oid is null or not exists(select 1 from pg_catalog.pg_proc where oid=routine_oid and proowner='postgres'::regrole and prosecdef and 'search_path=""'=any(proconfig) and 'row_security=off'=any(proconfig)) or not pg_catalog.has_function_privilege('authenticated',routine_oid,'execute') or pg_catalog.has_function_privilege('anon',routine_oid,'execute') or pg_catalog.has_function_privilege('service_role',routine_oid,'execute') then raise exception 'Unsafe Phase 01 routine: %',routine; end if;
  end loop;
  foreach routine in array array[
    'app_private.lock_inventory_position(uuid,uuid,uuid)',
    'app_private.assert_purchase_receipt_reversal_traceability(uuid,uuid,uuid,uuid)',
    'app_private.apply_inventory_valuation_delta(uuid,uuid,uuid,text,numeric,uuid,uuid,text,numeric,uuid)'
  ] loop
    routine_oid:=pg_catalog.to_regprocedure(routine);
    if routine_oid is null or not exists(select 1 from pg_catalog.pg_proc where oid=routine_oid and proowner='postgres'::regrole and prosecdef and 'search_path=""'=any(proconfig) and 'row_security=off'=any(proconfig)) or pg_catalog.has_function_privilege('authenticated',routine_oid,'execute') or pg_catalog.has_function_privilege('anon',routine_oid,'execute') or pg_catalog.has_function_privilege('service_role',routine_oid,'execute') then raise exception 'Unsafe internal Phase 01 routine: %',routine; end if;
  end loop;
  if exists(select 1 from pg_catalog.pg_class where oid in ('public.inventory_valuation_events'::regclass,'public.purchase_receipts'::regclass,'public.purchase_receipt_items'::regclass,'public.purchase_receipt_reversals'::regclass,'public.purchase_receipt_reversal_items'::regclass) and (not relrowsecurity or not relforcerowsecurity)) then raise exception 'Phase 01 table lost FORCE RLS'; end if;
end;
$verify$;
commit;
