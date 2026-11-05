-- Package 04: inventory controls and work orders.
-- All catalog entries start pending_approval. This migration grants no role,
-- enables no company transaction and creates no business data.
begin;

do $preflight$
begin
  if current_user <> 'postgres' then raise exception 'Apply this migration as postgres'; end if;
  if pg_catalog.to_regclass('public.inventory_balances') is null
    or pg_catalog.to_regclass('public.inventory_movements') is null
    or pg_catalog.to_regclass('public.business_parties') is null
    or pg_catalog.to_regclass('public.catalog_items') is null
    or pg_catalog.to_regclass('public.company_transaction_availability') is null
    or pg_catalog.to_regprocedure('app_private.assert_operational_permission(uuid,text,uuid)') is null
    or pg_catalog.to_regprocedure('app_private.write_operational_audit(text,uuid,uuid,uuid,uuid,jsonb)') is null then
    raise exception 'Operational, audit and company-entitlement foundations are required';
  end if;
  if pg_catalog.to_regclass('public.work_orders') is not null
    or pg_catalog.to_regclass('public.inventory_transfers') is not null
    or pg_catalog.to_regprocedure('public.operational_create_work_order(uuid,uuid,uuid,text,text,uuid)') is not null then
    raise exception 'Package 04 objects already exist; inspect before applying';
  end if;
end;
$preflight$;

insert into public.permission_definitions(permission_key,description) values
  ('transaction.masterdata.catalog.product.update','Transação MM02: alterar produtos.'),
  ('transaction.masterdata.catalog.product.read','Transação MM03: consultar produtos.'),
  ('transaction.inventory.balance.read','Transação MB52: consultar saldos por filial.'),
  ('transaction.inventory.history.read','Transação MB51: consultar histórico de estoque.'),
  ('transaction.inventory.physical.create','Transação MI01: iniciar inventário físico.'),
  ('transaction.inventory.physical.count','Transação MI04: registrar contagens de inventário.'),
  ('transaction.inventory.physical.adjust','Transação MI07: aplicar ajustes de inventário.'),
  ('transaction.inventory.transfer','Transação ZTR01: transferir estoque entre filiais.'),
  ('transaction.service_order.create','Transação ZOS01: criar ordem de serviço.'),
  ('transaction.service_order.update','Transação ZOS02: alterar ordem de serviço.'),
  ('transaction.service_order.read','Transação ZOS03: consultar ordem de serviço.'),
  ('transaction.service_order.close','Transação ZOS04: encerrar ou estornar ordem de serviço.')
on conflict(permission_key) do nothing;

insert into public.erp_transaction_authorization_catalog(transaction_code,module_code,permission_key) values
  ('MM02','MDM','transaction.masterdata.catalog.product.update'),
  ('MM03','MDM','transaction.masterdata.catalog.product.read'),
  ('MB52','INV','transaction.inventory.balance.read'),
  ('MB51','INV','transaction.inventory.history.read'),
  ('MI01','INV','transaction.inventory.physical.create'),
  ('MI04','INV','transaction.inventory.physical.count'),
  ('MI07','INV','transaction.inventory.physical.adjust'),
  ('ZTR01','INV','transaction.inventory.transfer'),
  ('ZOS01','SVC','transaction.service_order.create'),
  ('ZOS02','SVC','transaction.service_order.update'),
  ('ZOS03','SVC','transaction.service_order.read'),
  ('ZOS04','SVC','transaction.service_order.close')
on conflict(transaction_code) do nothing;

-- Average cost is deliberately deferred: the established movement contract has
-- no unit-cost field, so populating a balance-level cost here would be fiction.
alter table public.inventory_movements drop constraint inventory_movements_movement_type_check;
alter table public.inventory_movements add constraint inventory_movements_movement_type_check
  check(movement_type in ('initial','entry','exit','adjustment_positive','adjustment_negative','transfer_out','transfer_in','physical_count_in','physical_count_out','service_consumption','service_reversal'));

create table public.inventory_transfers (
  id uuid primary key default pg_catalog.gen_random_uuid(),
  tenant_id uuid not null references public.companies(id) on delete restrict,
  source_branch_id uuid not null,
  destination_branch_id uuid not null,
  item_id uuid not null,
  quantity numeric(18,4) not null check(quantity>0),
  request_id uuid not null,
  reference_note text,
  created_by_user_id uuid not null references auth.users(id) on delete restrict,
  created_at timestamptz not null default pg_catalog.clock_timestamp(),
  unique(tenant_id,request_id),
  check(source_branch_id<>destination_branch_id),
  foreign key(tenant_id,source_branch_id) references public.branches(tenant_id,id) on delete restrict,
  foreign key(tenant_id,destination_branch_id) references public.branches(tenant_id,id) on delete restrict,
  foreign key(tenant_id,item_id) references public.catalog_items(tenant_id,id) on delete restrict
);
create table public.inventory_count_sessions (
  id uuid primary key default pg_catalog.gen_random_uuid(),
  tenant_id uuid not null references public.companies(id) on delete restrict,
  branch_id uuid not null,
  status text not null default 'open' check(status in ('open','posted','cancelled')),
  request_id uuid not null,
  notes text,
  created_by_user_id uuid not null references auth.users(id) on delete restrict,
  posted_by_user_id uuid references auth.users(id) on delete restrict,
  created_at timestamptz not null default pg_catalog.clock_timestamp(),
  posted_at timestamptz,
  unique(tenant_id,id), unique(tenant_id,request_id),
  foreign key(tenant_id,branch_id) references public.branches(tenant_id,id) on delete restrict
);
create table public.inventory_count_lines (
  tenant_id uuid not null,
  session_id uuid not null,
  item_id uuid not null,
  counted_quantity numeric(18,4) not null check(counted_quantity>=0),
  recorded_quantity numeric(18,4) not null check(recorded_quantity>=0),
  counted_by_user_id uuid not null references auth.users(id) on delete restrict,
  counted_at timestamptz not null default pg_catalog.clock_timestamp(),
  primary key(session_id,item_id),
  foreign key(tenant_id,session_id) references public.inventory_count_sessions(tenant_id,id) on delete cascade,
  foreign key(tenant_id,item_id) references public.catalog_items(tenant_id,id) on delete restrict
);
create table public.work_order_counters (
  tenant_id uuid primary key references public.companies(id) on delete restrict,
  last_number bigint not null default 0 check(last_number>=0)
);
create table public.work_orders (
  id uuid primary key default pg_catalog.gen_random_uuid(),
  tenant_id uuid not null references public.companies(id) on delete restrict,
  branch_id uuid not null,
  order_number bigint not null,
  customer_id uuid not null,
  equipment_description text,
  problem_description text not null check(pg_catalog.length(pg_catalog.btrim(problem_description)) between 1 and 4000),
  diagnosis text,
  status text not null default 'open' check(status in ('open','in_progress','closed','cancelled','reversed')),
  service_total numeric(18,4) not null default 0 check(service_total>=0),
  parts_total numeric(18,4) not null default 0 check(parts_total>=0),
  discount_total numeric(18,4) not null default 0 check(discount_total>=0),
  total_amount numeric(18,4) not null default 0 check(total_amount>=0),
  request_id uuid not null,
  created_by_user_id uuid not null references auth.users(id) on delete restrict,
  closed_by_user_id uuid references auth.users(id) on delete restrict,
  created_at timestamptz not null default pg_catalog.clock_timestamp(),
  updated_at timestamptz not null default pg_catalog.clock_timestamp(),
  closed_at timestamptz,
  unique(tenant_id,id), unique(tenant_id,order_number), unique(tenant_id,request_id),
  foreign key(tenant_id,branch_id) references public.branches(tenant_id,id) on delete restrict,
  foreign key(tenant_id,customer_id) references public.business_parties(tenant_id,id) on delete restrict
);
create table public.work_order_lines (
  id uuid primary key default pg_catalog.gen_random_uuid(),
  tenant_id uuid not null,
  work_order_id uuid not null,
  line_number integer not null check(line_number>0),
  line_type text not null check(line_type in ('service','part')),
  item_id uuid not null,
  description text not null check(pg_catalog.length(pg_catalog.btrim(description)) between 1 and 500),
  quantity numeric(18,4) not null check(quantity>0),
  unit_price numeric(18,4) not null check(unit_price>=0),
  discount_amount numeric(18,4) not null default 0 check(discount_amount>=0),
  line_total numeric(18,4) not null check(line_total>=0),
  unique(work_order_id,line_number), unique(work_order_id,item_id,line_type),
  foreign key(tenant_id,work_order_id) references public.work_orders(tenant_id,id) on delete cascade,
  foreign key(tenant_id,item_id) references public.catalog_items(tenant_id,id) on delete restrict
);
create table public.work_order_part_reservations (
  tenant_id uuid not null,
  work_order_id uuid not null,
  item_id uuid not null,
  quantity numeric(18,4) not null check(quantity>0),
  status text not null check(status in ('reserved','released','consumed','reversed')),
  reserved_by_user_id uuid not null references auth.users(id) on delete restrict,
  reserved_at timestamptz not null default pg_catalog.clock_timestamp(),
  consumed_at timestamptz,
  primary key(work_order_id,item_id),
  foreign key(tenant_id,work_order_id) references public.work_orders(tenant_id,id) on delete cascade,
  foreign key(tenant_id,item_id) references public.catalog_items(tenant_id,id) on delete restrict
);
create table public.work_order_events (
  id uuid primary key default pg_catalog.gen_random_uuid(),
  tenant_id uuid not null,
  work_order_id uuid not null,
  event_key text not null,
  actor_user_id uuid not null references auth.users(id) on delete restrict,
  details jsonb not null default '{}'::jsonb check(pg_catalog.jsonb_typeof(details)='object'),
  created_at timestamptz not null default pg_catalog.clock_timestamp(),
  foreign key(tenant_id,work_order_id) references public.work_orders(tenant_id,id) on delete cascade
);
create table app_private.work_order_update_requests (
  tenant_id uuid not null,
  work_order_id uuid not null,
  request_id uuid not null,
  created_at timestamptz not null default pg_catalog.clock_timestamp(),
  primary key(tenant_id,work_order_id,request_id),
  foreign key(tenant_id,work_order_id) references public.work_orders(tenant_id,id) on delete cascade
);
create index inventory_transfers_tenant_created_idx on public.inventory_transfers(tenant_id,created_at desc);
create index inventory_count_sessions_branch_idx on public.inventory_count_sessions(tenant_id,branch_id,status,created_at desc);
create index work_orders_branch_status_idx on public.work_orders(tenant_id,branch_id,status,created_at desc);
create index work_order_events_order_idx on public.work_order_events(tenant_id,work_order_id,created_at desc);

alter table public.inventory_transfers enable row level security; alter table public.inventory_transfers force row level security;
alter table public.inventory_count_sessions enable row level security; alter table public.inventory_count_sessions force row level security;
alter table public.inventory_count_lines enable row level security; alter table public.inventory_count_lines force row level security;
alter table public.work_order_counters enable row level security; alter table public.work_order_counters force row level security;
alter table public.work_orders enable row level security; alter table public.work_orders force row level security;
alter table public.work_order_lines enable row level security; alter table public.work_order_lines force row level security;
alter table public.work_order_part_reservations enable row level security; alter table public.work_order_part_reservations force row level security;
alter table public.work_order_events enable row level security; alter table public.work_order_events force row level security;
alter table app_private.work_order_update_requests enable row level security; alter table app_private.work_order_update_requests force row level security;
revoke all on table public.inventory_transfers,public.inventory_count_sessions,public.inventory_count_lines,public.work_order_counters,public.work_orders,public.work_order_lines,public.work_order_part_reservations,public.work_order_events from public,anon,authenticated,service_role;
revoke all on table app_private.work_order_update_requests from public,anon,authenticated,service_role;

create function app_private.apply_inventory_delta(p_tenant_id uuid,p_branch_id uuid,p_item_id uuid,p_movement_type text,p_quantity numeric,p_request_id uuid,p_actor_id uuid,p_reference text default null)
returns table(movement_id uuid,balance_after numeric)
language plpgsql volatile security definer set search_path='' set row_security=off as $fn$
declare current_quantity numeric; new_quantity numeric; delta numeric; existing_id uuid; existing_balance numeric;
begin
  if p_quantity is null or p_quantity<=0 or p_request_id is null or p_movement_type not in ('transfer_out','transfer_in','physical_count_in','physical_count_out','service_consumption','service_reversal') then raise exception 'Invalid internal inventory delta' using errcode='22023'; end if;
  perform pg_catalog.pg_advisory_xact_lock(pg_catalog.hashtextextended('inventory:'||p_tenant_id::text||':'||p_branch_id::text||':'||p_item_id::text,0));
  select movement.id,movement.balance_after into existing_id,existing_balance from public.inventory_movements movement where movement.tenant_id=p_tenant_id and movement.request_id=p_request_id;
  if found then return query select existing_id,existing_balance; return; end if;
  select quantity into current_quantity from public.inventory_balances where tenant_id=p_tenant_id and branch_id=p_branch_id and item_id=p_item_id for update;
  current_quantity:=coalesce(current_quantity,0);
  delta:=case when p_movement_type in ('transfer_in','physical_count_in','service_reversal') then p_quantity else -p_quantity end;
  new_quantity:=current_quantity+delta;
  if new_quantity<0 then raise exception 'Negative inventory is not allowed' using errcode='23514'; end if;
  insert into public.inventory_balances(tenant_id,branch_id,item_id,quantity) values(p_tenant_id,p_branch_id,p_item_id,new_quantity)
    on conflict(tenant_id,branch_id,item_id) do update set quantity=excluded.quantity,updated_at=pg_catalog.clock_timestamp();
  insert into public.inventory_movements(tenant_id,branch_id,item_id,movement_type,quantity,balance_after,reference_note,request_id,created_by_user_id)
    values(p_tenant_id,p_branch_id,p_item_id,p_movement_type,p_quantity,new_quantity,nullif(pg_catalog.btrim(p_reference),''),p_request_id,p_actor_id)
    returning inventory_movements.id,inventory_movements.balance_after into movement_id,balance_after;
  return next;
end;
$fn$;

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
    else null end;
  if required_codes is null then raise exception 'Operational permission is not mapped to an approved transaction' using errcode='42501'; end if;
  select count(distinct c.transaction_code) into ready_count from public.erp_transaction_authorization_catalog c join public.permission_definitions p on p.permission_key=c.permission_key and p.approval_state='approved' join public.company_module_availability m on m.tenant_id=p_tenant_id and m.module_code=c.module_code and m.enabled join public.company_transaction_availability t on t.tenant_id=p_tenant_id and t.transaction_code=c.transaction_code and t.enabled where c.transaction_code=any(required_codes) and c.approval_state='approved';
  if ready_count<>cardinality(required_codes) then raise exception 'Operational transaction is not approved or available for this company' using errcode='42501'; end if;
  return actor_id;
end;
$fn$;

-- Replace the two read contracts so the new SAP-style codes are enforced at
-- the database boundary, including the new internally-generated movements.
create or replace function public.operational_list_inventory_balances(p_tenant_id uuid,p_branch_id uuid,p_search text default null,p_limit integer default 50,p_offset integer default 0)
returns table(item_id uuid,code text,name text,quantity numeric,minimum_stock numeric,reorder_point numeric,below_reorder_point boolean)
language plpgsql stable security definer set search_path='' set row_security=off as $fn$
begin
  perform app_private.assert_operational_permission(p_tenant_id,'transaction.inventory.balance.read',p_branch_id);
  if p_limit not between 1 and 100 or p_offset<0 then raise exception 'Invalid inventory listing request' using errcode='22023'; end if;
  return query select i.id,i.code,i.name,coalesce(b.quantity,0),i.minimum_stock,i.reorder_point,(coalesce(b.quantity,0)<=i.reorder_point)
    from public.catalog_items i left join public.inventory_balances b on b.tenant_id=i.tenant_id and b.branch_id=p_branch_id and b.item_id=i.id
    where i.tenant_id=p_tenant_id and i.item_type='product' and i.status='active' and (p_search is null or i.code ilike '%'||pg_catalog.btrim(p_search)||'%' or i.name ilike '%'||pg_catalog.btrim(p_search)||'%')
    order by i.code,i.id limit p_limit offset p_offset;
end;
$fn$;

create or replace function public.operational_list_inventory_movements(p_tenant_id uuid,p_branch_id uuid,p_item_id uuid default null,p_movement_type text default null,p_from timestamptz default null,p_to timestamptz default null,p_limit integer default 50,p_offset integer default 0)
returns table(movement_id uuid,item_id uuid,item_code text,item_name text,movement_type text,quantity numeric,balance_after numeric,reference_note text,created_at timestamptz)
language plpgsql stable security definer set search_path='' set row_security=off as $fn$
begin
  perform app_private.assert_operational_permission(p_tenant_id,'transaction.inventory.history.read',p_branch_id);
  if p_limit not between 1 and 100 or p_offset<0 or (p_movement_type is not null and p_movement_type not in ('initial','entry','exit','adjustment_positive','adjustment_negative','transfer_out','transfer_in','physical_count_in','physical_count_out','service_consumption','service_reversal')) or (p_from is not null and p_to is not null and p_from>p_to) then raise exception 'Invalid inventory movement listing request' using errcode='22023'; end if;
  return query select m.id,m.item_id,i.code,i.name,m.movement_type,m.quantity,m.balance_after,m.reference_note,m.created_at from public.inventory_movements m join public.catalog_items i on i.tenant_id=m.tenant_id and i.id=m.item_id where m.tenant_id=p_tenant_id and m.branch_id=p_branch_id and (p_item_id is null or m.item_id=p_item_id) and (p_movement_type is null or m.movement_type=p_movement_type) and (p_from is null or m.created_at>=p_from) and (p_to is null or m.created_at<=p_to) order by m.created_at desc,m.id desc limit p_limit offset p_offset;
end;
$fn$;

create function public.operational_create_inventory_transfer(p_tenant_id uuid,p_source_branch_id uuid,p_destination_branch_id uuid,p_item_id uuid,p_quantity numeric,p_reference_note text,p_request_id uuid)
returns uuid language plpgsql volatile security definer set search_path='' set row_security=off as $fn$
declare actor uuid; transfer_id uuid;
begin
  actor:=app_private.assert_operational_permission(p_tenant_id,'transaction.inventory.transfer',p_source_branch_id);
  if not app_private.can_access_branch(p_tenant_id,p_destination_branch_id) or not exists(select 1 from public.branches where tenant_id=p_tenant_id and id in (p_source_branch_id,p_destination_branch_id) and status='active' group by tenant_id having count(*)=2) or p_source_branch_id=p_destination_branch_id or p_item_id is null or p_quantity is null or p_quantity<=0 or p_request_id is null then raise exception 'Invalid or unauthorized inventory transfer' using errcode='42501'; end if;
  perform pg_catalog.pg_advisory_xact_lock(pg_catalog.hashtextextended('inventory-transfer:'||p_tenant_id::text||':'||p_request_id::text,0));
  select id into transfer_id from public.inventory_transfers where tenant_id=p_tenant_id and request_id=p_request_id; if found then return transfer_id; end if;
  if not exists(select 1 from public.catalog_items where tenant_id=p_tenant_id and id=p_item_id and item_type='product' and status='active') then raise exception 'Active product in this company required' using errcode='23503'; end if;
  perform pg_catalog.pg_advisory_xact_lock(pg_catalog.hashtextextended('inventory:'||p_tenant_id::text||':'||least(p_source_branch_id,p_destination_branch_id)::text||':'||p_item_id::text,0));
  perform pg_catalog.pg_advisory_xact_lock(pg_catalog.hashtextextended('inventory:'||p_tenant_id::text||':'||greatest(p_source_branch_id,p_destination_branch_id)::text||':'||p_item_id::text,0));
  insert into public.inventory_transfers(tenant_id,source_branch_id,destination_branch_id,item_id,quantity,request_id,reference_note,created_by_user_id) values(p_tenant_id,p_source_branch_id,p_destination_branch_id,p_item_id,p_quantity,p_request_id,nullif(pg_catalog.btrim(p_reference_note),''),actor) returning id into transfer_id;
  perform * from app_private.apply_inventory_delta(p_tenant_id,p_source_branch_id,p_item_id,'transfer_out',p_quantity,pg_catalog.gen_random_uuid(),actor,'Transfer '||transfer_id::text);
  perform * from app_private.apply_inventory_delta(p_tenant_id,p_destination_branch_id,p_item_id,'transfer_in',p_quantity,pg_catalog.gen_random_uuid(),actor,'Transfer '||transfer_id::text);
  perform app_private.write_operational_audit('inventory.transfer.created',p_tenant_id,p_source_branch_id,transfer_id,actor,pg_catalog.jsonb_build_object('destination_branch_id',p_destination_branch_id,'item_id',p_item_id,'quantity',p_quantity));
  return transfer_id;
end;
$fn$;

create function public.operational_create_inventory_count(p_tenant_id uuid,p_branch_id uuid,p_notes text,p_request_id uuid)
returns uuid language plpgsql volatile security definer set search_path='' set row_security=off as $fn$
declare actor uuid; session_id uuid;
begin
  actor:=app_private.assert_operational_permission(p_tenant_id,'transaction.inventory.physical.create',p_branch_id);
  if p_request_id is null or not exists(select 1 from public.branches where tenant_id=p_tenant_id and id=p_branch_id and status='active') then raise exception 'Active branch and request identifier are required' using errcode='22023'; end if;
  perform pg_catalog.pg_advisory_xact_lock(pg_catalog.hashtextextended('inventory-count:'||p_tenant_id::text||':'||p_request_id::text,0));
  select id into session_id from public.inventory_count_sessions where tenant_id=p_tenant_id and request_id=p_request_id; if found then return session_id; end if;
  insert into public.inventory_count_sessions(tenant_id,branch_id,notes,request_id,created_by_user_id) values(p_tenant_id,p_branch_id,nullif(pg_catalog.btrim(p_notes),''),p_request_id,actor) returning id into session_id;
  perform app_private.write_operational_audit('inventory.count.created',p_tenant_id,p_branch_id,session_id,actor,'{}'); return session_id;
end;
$fn$;

create function public.operational_record_inventory_count(p_tenant_id uuid,p_session_id uuid,p_item_id uuid,p_counted_quantity numeric)
returns text language plpgsql volatile security definer set search_path='' set row_security=off as $fn$
declare actor uuid; branch uuid; recorded numeric;
begin
  select branch_id into branch from public.inventory_count_sessions where tenant_id=p_tenant_id and id=p_session_id and status='open' for update;
  if not found then raise exception 'Open inventory count not found' using errcode='P0002'; end if;
  actor:=app_private.assert_operational_permission(p_tenant_id,'transaction.inventory.physical.count',branch);
  if p_item_id is null or p_counted_quantity is null or p_counted_quantity<0 or not exists(select 1 from public.catalog_items where tenant_id=p_tenant_id and id=p_item_id and item_type='product' and status='active') then raise exception 'Invalid inventory count line' using errcode='22023'; end if;
  select quantity into recorded from public.inventory_balances where tenant_id=p_tenant_id and branch_id=branch and item_id=p_item_id; recorded:=coalesce(recorded,0);
  insert into public.inventory_count_lines(tenant_id,session_id,item_id,counted_quantity,recorded_quantity,counted_by_user_id) values(p_tenant_id,p_session_id,p_item_id,p_counted_quantity,recorded,actor) on conflict(session_id,item_id) do update set counted_quantity=excluded.counted_quantity,recorded_quantity=excluded.recorded_quantity,counted_by_user_id=excluded.counted_by_user_id,counted_at=pg_catalog.clock_timestamp();
  perform app_private.write_operational_audit('inventory.count.recorded',p_tenant_id,branch,p_session_id,actor,pg_catalog.jsonb_build_object('item_id',p_item_id)); return 'recorded';
end;
$fn$;

create function public.operational_post_inventory_count(p_tenant_id uuid,p_session_id uuid)
returns text language plpgsql volatile security definer set search_path='' set row_security=off as $fn$
declare actor uuid; branch uuid; line record; difference numeric; current_quantity numeric;
begin
  select branch_id into branch from public.inventory_count_sessions where tenant_id=p_tenant_id and id=p_session_id and status='open' for update;
  if not found then return 'unchanged'; end if;
  actor:=app_private.assert_operational_permission(p_tenant_id,'transaction.inventory.physical.adjust',branch);
  for line in select * from public.inventory_count_lines where tenant_id=p_tenant_id and session_id=p_session_id order by item_id loop
    -- A count is a target quantity. If stock moved after the line was counted,
    -- adjust from the locked current balance rather than replaying a stale delta.
    select quantity into current_quantity from public.inventory_balances where tenant_id=p_tenant_id and branch_id=branch and item_id=line.item_id for update;
    difference:=line.counted_quantity-coalesce(current_quantity,0);
    if difference<>0 then perform * from app_private.apply_inventory_delta(p_tenant_id,branch,line.item_id,case when difference>0 then 'physical_count_in' else 'physical_count_out' end,abs(difference),pg_catalog.gen_random_uuid(),actor,'Inventory count '||p_session_id::text); end if;
  end loop;
  update public.inventory_count_sessions set status='posted',posted_at=pg_catalog.clock_timestamp(),posted_by_user_id=actor where id=p_session_id;
  perform app_private.write_operational_audit('inventory.count.posted',p_tenant_id,branch,p_session_id,actor,'{}'); return 'posted';
end;
$fn$;

create function app_private.next_work_order_number(p_tenant_id uuid)
returns bigint language plpgsql volatile security definer set search_path='' set row_security=off as $fn$
declare result bigint;
begin
  insert into public.work_order_counters(tenant_id,last_number) values(p_tenant_id,1) on conflict(tenant_id) do update set last_number=public.work_order_counters.last_number+1 returning last_number into result; return result;
end;
$fn$;

create function public.operational_create_work_order(p_tenant_id uuid,p_branch_id uuid,p_customer_id uuid,p_equipment_description text,p_problem_description text,p_request_id uuid)
returns uuid language plpgsql volatile security definer set search_path='' set row_security=off as $fn$
declare actor uuid; order_id uuid;
begin
  actor:=app_private.assert_operational_permission(p_tenant_id,'transaction.service_order.create',p_branch_id);
  if p_customer_id is null or p_request_id is null or p_problem_description is null or pg_catalog.length(pg_catalog.btrim(p_problem_description)) not between 1 and 4000 or not exists(select 1 from public.branches where tenant_id=p_tenant_id and id=p_branch_id and status='active') or not exists(select 1 from public.business_parties where tenant_id=p_tenant_id and id=p_customer_id and party_type in ('customer','both') and status='active') then raise exception 'Active branch, customer and problem description are required' using errcode='22023'; end if;
  perform pg_catalog.pg_advisory_xact_lock(pg_catalog.hashtextextended('work-order:'||p_tenant_id::text||':'||p_request_id::text,0)); select id into order_id from public.work_orders where tenant_id=p_tenant_id and request_id=p_request_id; if found then return order_id; end if;
  insert into public.work_orders(tenant_id,branch_id,order_number,customer_id,equipment_description,problem_description,request_id,created_by_user_id) values(p_tenant_id,p_branch_id,app_private.next_work_order_number(p_tenant_id),p_customer_id,nullif(pg_catalog.btrim(p_equipment_description),''),pg_catalog.btrim(p_problem_description),p_request_id,actor) returning id into order_id;
  insert into public.work_order_events(tenant_id,work_order_id,event_key,actor_user_id) values(p_tenant_id,order_id,'work_order.created',actor);
  perform app_private.write_operational_audit('work_order.created',p_tenant_id,p_branch_id,order_id,actor,'{}'); return order_id;
end;
$fn$;

create function public.operational_update_work_order(p_tenant_id uuid,p_work_order_id uuid,p_diagnosis text,p_lines jsonb,p_request_id uuid)
returns uuid language plpgsql volatile security definer set search_path='' set row_security=off as $fn$
declare actor uuid; branch uuid; line_count integer; inserted_count integer; v_service_total numeric; v_parts_total numeric; v_discount_total numeric;
begin
  select branch_id into branch from public.work_orders where tenant_id=p_tenant_id and id=p_work_order_id and status in ('open','in_progress') for update;
  if not found then raise exception 'Editable work order not found' using errcode='P0002'; end if;
  actor:=app_private.assert_operational_permission(p_tenant_id,'transaction.service_order.update',branch);
  if p_request_id is null or p_lines is null or pg_catalog.jsonb_typeof(p_lines)<>'array' or pg_catalog.jsonb_array_length(p_lines)>100 then raise exception 'Invalid work order lines' using errcode='22023'; end if;
  perform pg_catalog.pg_advisory_xact_lock(pg_catalog.hashtextextended('work-order-update:'||p_tenant_id::text||':'||p_work_order_id::text||':'||p_request_id::text,0));
  if exists(select 1 from app_private.work_order_update_requests where tenant_id=p_tenant_id and work_order_id=p_work_order_id and request_id=p_request_id) then return p_work_order_id; end if;
  if exists(select 1 from public.work_order_part_reservations where tenant_id=p_tenant_id and work_order_id=p_work_order_id and status='reserved') then raise exception 'Release reservations before changing parts' using errcode='55000'; end if;
  select count(*) into line_count from pg_catalog.jsonb_to_recordset(p_lines) as x(line_type text,item_id uuid,quantity numeric,unit_price numeric,discount_amount numeric);
  if line_count<>pg_catalog.jsonb_array_length(p_lines) or exists(select 1 from pg_catalog.jsonb_to_recordset(p_lines) as x(line_type text,item_id uuid,quantity numeric,unit_price numeric,discount_amount numeric) where line_type not in ('service','part') or item_id is null or quantity is null or quantity<=0 or unit_price is null or unit_price<0 or coalesce(discount_amount,0)<0 or coalesce(discount_amount,0)>quantity*unit_price) then raise exception 'Invalid work order line values' using errcode='22023'; end if;
  delete from public.work_order_lines where tenant_id=p_tenant_id and work_order_id=p_work_order_id;
  with supplied as (select x.*,row_number() over() as n from pg_catalog.jsonb_to_recordset(p_lines) as x(line_type text,item_id uuid,quantity numeric,unit_price numeric,discount_amount numeric)), valid as (select s.*,i.name from supplied s join public.catalog_items i on i.tenant_id=p_tenant_id and i.id=s.item_id and i.status='active' and ((s.line_type='service' and i.item_type='service') or (s.line_type='part' and i.item_type='product'))), inserted as (insert into public.work_order_lines(tenant_id,work_order_id,line_number,line_type,item_id,description,quantity,unit_price,discount_amount,line_total) select p_tenant_id,p_work_order_id,n,line_type,item_id,name,quantity,unit_price,coalesce(discount_amount,0),pg_catalog.round(quantity*unit_price-coalesce(discount_amount,0),4) from valid returning line_type,line_total,discount_amount) select count(*),coalesce(sum(line_total) filter(where line_type='service'),0),coalesce(sum(line_total) filter(where line_type='part'),0),coalesce(sum(discount_amount),0) into inserted_count,v_service_total,v_parts_total,v_discount_total from inserted;
  if inserted_count<>line_count then raise exception 'Active items of the required type are mandatory' using errcode='23503'; end if;
  update public.work_orders set diagnosis=nullif(pg_catalog.btrim(p_diagnosis),''),service_total=v_service_total,parts_total=v_parts_total,discount_total=v_discount_total,total_amount=v_service_total+v_parts_total,updated_at=pg_catalog.clock_timestamp() where id=p_work_order_id;
  insert into app_private.work_order_update_requests(tenant_id,work_order_id,request_id) values(p_tenant_id,p_work_order_id,p_request_id);
  insert into public.work_order_events(tenant_id,work_order_id,event_key,actor_user_id,details) values(p_tenant_id,p_work_order_id,'work_order.updated',actor,pg_catalog.jsonb_build_object('request_id',p_request_id,'line_count',line_count));
  perform app_private.write_operational_audit('work_order.updated',p_tenant_id,branch,p_work_order_id,actor,pg_catalog.jsonb_build_object('request_id',p_request_id)); return p_work_order_id;
end;
$fn$;

create function public.operational_reserve_work_order_parts(p_tenant_id uuid,p_work_order_id uuid)
returns text language plpgsql volatile security definer set search_path='' set row_security=off as $fn$
declare actor uuid; branch uuid; line record; available numeric;
begin
  select branch_id into branch from public.work_orders where tenant_id=p_tenant_id and id=p_work_order_id and status in ('open','in_progress') for update; if not found then raise exception 'Reservable work order not found' using errcode='P0002'; end if;
  actor:=app_private.assert_operational_permission(p_tenant_id,'transaction.service_order.update',branch);
  for line in select item_id,quantity from public.work_order_lines where tenant_id=p_tenant_id and work_order_id=p_work_order_id and line_type='part' order by item_id loop
    perform pg_catalog.pg_advisory_xact_lock(pg_catalog.hashtextextended('inventory:'||p_tenant_id::text||':'||branch::text||':'||line.item_id::text,0));
    select coalesce(b.quantity,0)-coalesce((select sum(r.quantity) from public.work_order_part_reservations r join public.work_orders o on o.id=r.work_order_id where r.tenant_id=p_tenant_id and r.item_id=line.item_id and r.status='reserved' and o.branch_id=branch and r.work_order_id<>p_work_order_id),0) into available from public.inventory_balances b where b.tenant_id=p_tenant_id and b.branch_id=branch and b.item_id=line.item_id;
    if coalesce(available,0)<line.quantity then raise exception 'Insufficient available inventory for work order reservation' using errcode='23514'; end if;
    insert into public.work_order_part_reservations(tenant_id,work_order_id,item_id,quantity,status,reserved_by_user_id) values(p_tenant_id,p_work_order_id,line.item_id,line.quantity,'reserved',actor) on conflict(work_order_id,item_id) do update set quantity=excluded.quantity,status='reserved',reserved_by_user_id=excluded.reserved_by_user_id,reserved_at=pg_catalog.clock_timestamp(),consumed_at=null;
  end loop;
  update public.work_orders set status='in_progress',updated_at=pg_catalog.clock_timestamp() where id=p_work_order_id; insert into public.work_order_events(tenant_id,work_order_id,event_key,actor_user_id) values(p_tenant_id,p_work_order_id,'work_order.parts_reserved',actor); perform app_private.write_operational_audit('work_order.parts_reserved',p_tenant_id,branch,p_work_order_id,actor,'{}'); return 'reserved';
end;
$fn$;

create function public.operational_close_work_order(p_tenant_id uuid,p_work_order_id uuid)
returns text language plpgsql volatile security definer set search_path='' set row_security=off as $fn$
declare actor uuid; branch uuid; line record;
begin
  select branch_id into branch from public.work_orders where tenant_id=p_tenant_id and id=p_work_order_id for update; if not found then raise exception 'Work order not found' using errcode='P0002'; end if;
  actor:=app_private.assert_operational_permission(p_tenant_id,'transaction.service_order.close',branch);
  if (select status from public.work_orders where id=p_work_order_id)='closed' then return 'closed'; end if;
  if (select status from public.work_orders where id=p_work_order_id) not in ('in_progress','open') then raise exception 'Only open or in-progress work orders may close' using errcode='22023'; end if;
  if exists(select 1 from public.work_order_lines l where l.tenant_id=p_tenant_id and l.work_order_id=p_work_order_id and l.line_type='part' and not exists(select 1 from public.work_order_part_reservations r where r.work_order_id=p_work_order_id and r.item_id=l.item_id and r.status='reserved')) then raise exception 'Parts must be reserved before closing the work order' using errcode='23514'; end if;
  for line in select * from public.work_order_part_reservations where tenant_id=p_tenant_id and work_order_id=p_work_order_id and status='reserved' order by item_id for update loop
    perform * from app_private.apply_inventory_delta(p_tenant_id,branch,line.item_id,'service_consumption',line.quantity,pg_catalog.gen_random_uuid(),actor,'Work order '||p_work_order_id::text);
    update public.work_order_part_reservations set status='consumed',consumed_at=pg_catalog.clock_timestamp() where work_order_id=p_work_order_id and item_id=line.item_id;
  end loop;
  update public.work_orders set status='closed',closed_at=pg_catalog.clock_timestamp(),closed_by_user_id=actor,updated_at=pg_catalog.clock_timestamp() where id=p_work_order_id;
  insert into public.work_order_events(tenant_id,work_order_id,event_key,actor_user_id) values(p_tenant_id,p_work_order_id,'work_order.closed',actor); perform app_private.write_operational_audit('work_order.closed',p_tenant_id,branch,p_work_order_id,actor,'{}'); return 'closed';
end;
$fn$;

create function public.operational_reverse_work_order_consumption(p_tenant_id uuid,p_work_order_id uuid)
returns text language plpgsql volatile security definer set search_path='' set row_security=off as $fn$
declare actor uuid; branch uuid; line record; order_status text;
begin
  select branch_id,status into branch,order_status from public.work_orders where tenant_id=p_tenant_id and id=p_work_order_id for update; if not found then raise exception 'Work order not found' using errcode='P0002'; end if;
  actor:=app_private.assert_operational_permission(p_tenant_id,'transaction.service_order.close',branch);
  if order_status='reversed' then return 'reversed'; end if;
  if order_status<>'closed' then raise exception 'Closed work order not found' using errcode='P0002'; end if;
  for line in select * from public.work_order_part_reservations where tenant_id=p_tenant_id and work_order_id=p_work_order_id and status='consumed' order by item_id for update loop
    perform * from app_private.apply_inventory_delta(p_tenant_id,branch,line.item_id,'service_reversal',line.quantity,pg_catalog.gen_random_uuid(),actor,'Work order reversal '||p_work_order_id::text); update public.work_order_part_reservations set status='reversed' where work_order_id=p_work_order_id and item_id=line.item_id;
  end loop;
  update public.work_orders set status='reversed',updated_at=pg_catalog.clock_timestamp() where id=p_work_order_id; insert into public.work_order_events(tenant_id,work_order_id,event_key,actor_user_id) values(p_tenant_id,p_work_order_id,'work_order.reversed',actor); perform app_private.write_operational_audit('work_order.reversed',p_tenant_id,branch,p_work_order_id,actor,'{}'); return 'reversed';
end;
$fn$;

create function public.operational_list_work_orders(p_tenant_id uuid,p_branch_id uuid,p_status text default null,p_limit integer default 50,p_offset integer default 0)
returns table(work_order_id uuid,order_number bigint,customer_name text,status text,total_amount numeric,created_at timestamptz,updated_at timestamptz)
language plpgsql stable security definer set search_path='' set row_security=off as $fn$
begin
  perform app_private.assert_operational_permission(p_tenant_id,'transaction.service_order.read',p_branch_id);
  if p_limit not between 1 and 100 or p_offset<0 or (p_status is not null and p_status not in ('open','in_progress','closed','cancelled','reversed')) then raise exception 'Invalid work order listing request' using errcode='22023'; end if;
  return query select o.id,o.order_number,c.legal_name,o.status,o.total_amount,o.created_at,o.updated_at from public.work_orders o join public.business_parties c on c.tenant_id=o.tenant_id and c.id=o.customer_id where o.tenant_id=p_tenant_id and o.branch_id=p_branch_id and (p_status is null or o.status=p_status) order by o.created_at desc,o.id desc limit p_limit offset p_offset;
end;
$fn$;

alter function app_private.apply_inventory_delta(uuid,uuid,uuid,text,numeric,uuid,uuid,text) owner to postgres;
alter function app_private.next_work_order_number(uuid) owner to postgres;
alter function app_private.assert_operational_permission(uuid,text,uuid) owner to postgres;
alter function public.operational_list_inventory_balances(uuid,uuid,text,integer,integer) owner to postgres;
alter function public.operational_list_inventory_movements(uuid,uuid,uuid,text,timestamptz,timestamptz,integer,integer) owner to postgres;
alter function public.operational_create_inventory_transfer(uuid,uuid,uuid,uuid,numeric,text,uuid) owner to postgres;
alter function public.operational_create_inventory_count(uuid,uuid,text,uuid) owner to postgres;
alter function public.operational_record_inventory_count(uuid,uuid,uuid,numeric) owner to postgres;
alter function public.operational_post_inventory_count(uuid,uuid) owner to postgres;
alter function public.operational_create_work_order(uuid,uuid,uuid,text,text,uuid) owner to postgres;
alter function public.operational_update_work_order(uuid,uuid,text,jsonb,uuid) owner to postgres;
alter function public.operational_reserve_work_order_parts(uuid,uuid) owner to postgres;
alter function public.operational_close_work_order(uuid,uuid) owner to postgres;
alter function public.operational_reverse_work_order_consumption(uuid,uuid) owner to postgres;
alter function public.operational_list_work_orders(uuid,uuid,text,integer,integer) owner to postgres;
revoke all on function app_private.apply_inventory_delta(uuid,uuid,uuid,text,numeric,uuid,uuid,text),app_private.next_work_order_number(uuid),app_private.assert_operational_permission(uuid,text,uuid) from public,anon,authenticated,service_role;
revoke all on function public.operational_create_inventory_transfer(uuid,uuid,uuid,uuid,numeric,text,uuid),public.operational_create_inventory_count(uuid,uuid,text,uuid),public.operational_record_inventory_count(uuid,uuid,uuid,numeric),public.operational_post_inventory_count(uuid,uuid),public.operational_create_work_order(uuid,uuid,uuid,text,text,uuid),public.operational_update_work_order(uuid,uuid,text,jsonb,uuid),public.operational_reserve_work_order_parts(uuid,uuid),public.operational_close_work_order(uuid,uuid),public.operational_reverse_work_order_consumption(uuid,uuid),public.operational_list_work_orders(uuid,uuid,text,integer,integer) from public,anon,authenticated,service_role;
grant execute on function public.operational_create_inventory_transfer(uuid,uuid,uuid,uuid,numeric,text,uuid),public.operational_create_inventory_count(uuid,uuid,text,uuid),public.operational_record_inventory_count(uuid,uuid,uuid,numeric),public.operational_post_inventory_count(uuid,uuid),public.operational_create_work_order(uuid,uuid,uuid,text,text,uuid),public.operational_update_work_order(uuid,uuid,text,jsonb,uuid),public.operational_reserve_work_order_parts(uuid,uuid),public.operational_close_work_order(uuid,uuid),public.operational_reverse_work_order_consumption(uuid,uuid),public.operational_list_work_orders(uuid,uuid,text,integer,integer) to authenticated;

do $verify$
declare routine text; routine_oid oid;
begin
  if exists(select 1 from public.company_module_availability where enabled) or exists(select 1 from public.company_transaction_availability where enabled) then raise exception 'Migration must not enable company access'; end if;
  foreach routine in array array['public.operational_list_inventory_balances(uuid,uuid,text,integer,integer)','public.operational_list_inventory_movements(uuid,uuid,uuid,text,timestamptz,timestamptz,integer,integer)','public.operational_create_inventory_transfer(uuid,uuid,uuid,uuid,numeric,text,uuid)','public.operational_create_inventory_count(uuid,uuid,text,uuid)','public.operational_record_inventory_count(uuid,uuid,uuid,numeric)','public.operational_post_inventory_count(uuid,uuid)','public.operational_create_work_order(uuid,uuid,uuid,text,text,uuid)','public.operational_update_work_order(uuid,uuid,text,jsonb,uuid)','public.operational_reserve_work_order_parts(uuid,uuid)','public.operational_close_work_order(uuid,uuid)','public.operational_reverse_work_order_consumption(uuid,uuid)','public.operational_list_work_orders(uuid,uuid,text,integer,integer)'] loop
    routine_oid:=pg_catalog.to_regprocedure(routine);
    if not exists(select 1 from pg_catalog.pg_proc where oid=routine_oid and proowner='postgres'::regrole and prosecdef and 'search_path=""'=any(proconfig) and 'row_security=off'=any(proconfig)) or not pg_catalog.has_function_privilege('authenticated',routine_oid,'EXECUTE') or pg_catalog.has_function_privilege('anon',routine_oid,'EXECUTE') or pg_catalog.has_function_privilege('service_role',routine_oid,'EXECUTE') then raise exception 'Unsafe Package 04 routine: %',routine; end if;
  end loop;
end;
$verify$;
commit;
