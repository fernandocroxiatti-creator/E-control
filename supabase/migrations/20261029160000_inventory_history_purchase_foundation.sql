-- Read-only inventory history and draft purchase orders.
-- New transaction catalog entries start pending_approval. No role grant, stock movement,
-- payable entry, financial posting, invitation or membership is created by this migration.

begin;

do $preflight$
begin
  if current_user <> 'postgres' then raise exception 'Apply this migration as postgres'; end if;
  if pg_catalog.to_regclass('public.companies') is null
    or pg_catalog.to_regclass('public.branches') is null
    or pg_catalog.to_regclass('public.business_parties') is null
    or pg_catalog.to_regclass('public.catalog_items') is null
    or pg_catalog.to_regclass('public.inventory_movements') is null
    or pg_catalog.to_regclass('public.permission_definitions') is null
    or pg_catalog.to_regclass('public.erp_transaction_authorization_catalog') is null
    or pg_catalog.to_regprocedure('app_private.assert_operational_permission(uuid,text,uuid)') is null
    or pg_catalog.to_regprocedure('app_private.write_operational_audit(text,uuid,uuid,uuid,uuid,jsonb)') is null then
    raise exception 'Operational ERP foundation is required';
  end if;
  if pg_catalog.to_regclass('public.purchase_orders') is not null
    or pg_catalog.to_regclass('public.purchase_order_items') is not null
    or pg_catalog.to_regprocedure('public.operational_list_inventory_movements(uuid,uuid,uuid,text,timestamptz,timestamptz,integer,integer)') is not null then
    raise exception 'Inventory history or purchase order objects already exist; inspect before applying';
  end if;
end;
$preflight$;

insert into public.permission_definitions (permission_key, description)
values ('transaction.purchasing.purchase_order.read', 'Transação ME23N: consultar pedidos de compra da própria empresa e filial.')
on conflict (permission_key) do nothing;

insert into public.erp_transaction_authorization_catalog (transaction_code, module_code, permission_key)
values ('ME23N', 'PUR', 'transaction.purchasing.purchase_order.read')
on conflict (transaction_code) do nothing;

create table public.purchase_orders (
  id uuid primary key default pg_catalog.gen_random_uuid(),
  tenant_id uuid not null references public.companies(id) on delete restrict,
  branch_id uuid not null,
  order_number bigint generated always as identity unique,
  supplier_id uuid not null,
  status text not null default 'draft' check (status in ('draft','submitted','cancelled')),
  notes text check (notes is null or pg_catalog.length(pg_catalog.btrim(notes)) <= 1000),
  total_amount numeric(18,4) not null default 0 check (total_amount >= 0),
  request_id uuid not null,
  created_by_user_id uuid not null references auth.users(id) on delete restrict,
  created_at timestamptz not null default pg_catalog.clock_timestamp(),
  updated_at timestamptz not null default pg_catalog.clock_timestamp(),
  constraint purchase_orders_tenant_id_id_unique unique (tenant_id,id),
  constraint purchase_orders_tenant_request_unique unique (tenant_id,request_id),
  constraint purchase_orders_branch_fk foreign key (tenant_id,branch_id) references public.branches(tenant_id,id) on delete restrict,
  constraint purchase_orders_supplier_fk foreign key (tenant_id,supplier_id) references public.business_parties(tenant_id,id) on delete restrict
);
create index purchase_orders_tenant_branch_lookup_idx on public.purchase_orders(tenant_id,branch_id,status,created_at desc);
create index purchase_orders_supplier_lookup_idx on public.purchase_orders(tenant_id,supplier_id,created_at desc);

create table public.purchase_order_items (
  id uuid primary key default pg_catalog.gen_random_uuid(),
  tenant_id uuid not null,
  purchase_order_id uuid not null,
  line_number integer not null check (line_number > 0),
  item_id uuid not null,
  quantity numeric(18,4) not null check (quantity > 0),
  unit_price numeric(18,4) not null check (unit_price >= 0),
  line_total numeric(18,4) not null check (line_total >= 0),
  created_at timestamptz not null default pg_catalog.clock_timestamp(),
  updated_at timestamptz not null default pg_catalog.clock_timestamp(),
  constraint purchase_order_items_order_fk foreign key (tenant_id,purchase_order_id) references public.purchase_orders(tenant_id,id) on delete cascade,
  constraint purchase_order_items_item_fk foreign key (tenant_id,item_id) references public.catalog_items(tenant_id,id) on delete restrict,
  constraint purchase_order_items_line_unique unique (purchase_order_id,line_number),
  constraint purchase_order_items_item_unique unique (purchase_order_id,item_id)
);
create index purchase_order_items_order_lookup_idx on public.purchase_order_items(tenant_id,purchase_order_id,line_number);

create table app_private.purchase_order_update_requests (
  tenant_id uuid not null,
  purchase_order_id uuid not null,
  request_id uuid not null,
  created_at timestamptz not null default pg_catalog.clock_timestamp(),
  primary key (tenant_id,request_id),
  constraint purchase_order_update_requests_order_fk foreign key (tenant_id,purchase_order_id) references public.purchase_orders(tenant_id,id) on delete cascade
);

alter table public.purchase_orders enable row level security;
alter table public.purchase_orders force row level security;
alter table public.purchase_order_items enable row level security;
alter table public.purchase_order_items force row level security;
alter table app_private.purchase_order_update_requests enable row level security;
alter table app_private.purchase_order_update_requests force row level security;
revoke all on table public.purchase_orders, public.purchase_order_items, app_private.purchase_order_update_requests from public,anon,authenticated,service_role;

create function public.operational_list_inventory_movements(
  p_tenant_id uuid,
  p_branch_id uuid,
  p_item_id uuid default null,
  p_movement_type text default null,
  p_from timestamptz default null,
  p_to timestamptz default null,
  p_limit integer default 50,
  p_offset integer default 0
)
returns table (movement_id uuid,item_id uuid,item_code text,item_name text,movement_type text,quantity numeric,balance_after numeric,reference_note text,created_at timestamptz)
language plpgsql stable security definer set search_path = '' set row_security = off as $function$
begin
  perform app_private.assert_operational_permission(p_tenant_id,'transaction.inventory.stock.read',p_branch_id);
  if p_limit not between 1 and 100 or p_offset < 0
    or (p_movement_type is not null and p_movement_type not in ('initial','entry','exit','adjustment_positive','adjustment_negative'))
    or (p_from is not null and p_to is not null and p_from > p_to) then
    raise exception 'Invalid inventory movement listing request' using errcode='22023';
  end if;
  return query
    select m.id,m.item_id,i.code,i.name,m.movement_type,m.quantity,m.balance_after,m.reference_note,m.created_at
    from public.inventory_movements m
    join public.catalog_items i on i.tenant_id=m.tenant_id and i.id=m.item_id
    where m.tenant_id=p_tenant_id and m.branch_id=p_branch_id
      and (p_item_id is null or m.item_id=p_item_id)
      and (p_movement_type is null or m.movement_type=p_movement_type)
      and (p_from is null or m.created_at >= p_from)
      and (p_to is null or m.created_at <= p_to)
    order by m.created_at desc,m.id desc limit p_limit offset p_offset;
end;
$function$;

create function public.operational_list_purchase_orders(
  p_tenant_id uuid,
  p_branch_id uuid,
  p_search text default null,
  p_status text default null,
  p_limit integer default 50,
  p_offset integer default 0
)
returns table (purchase_order_id uuid,order_number bigint,supplier_id uuid,supplier_name text,status text,total_amount numeric,item_count bigint,items jsonb,created_at timestamptz,updated_at timestamptz)
language plpgsql stable security definer set search_path = '' set row_security = off as $function$
begin
  perform app_private.assert_operational_permission(p_tenant_id,'transaction.purchasing.purchase_order.read',p_branch_id);
  if p_limit not between 1 and 100 or p_offset < 0 or (p_status is not null and p_status not in ('draft','submitted','cancelled')) then
    raise exception 'Invalid purchase order listing request' using errcode='22023';
  end if;
  return query
    select o.id,o.order_number,o.supplier_id,s.legal_name,o.status,o.total_amount,count(i.id),coalesce(pg_catalog.jsonb_agg(pg_catalog.jsonb_build_object('item_id',i.item_id,'quantity',i.quantity,'unit_price',i.unit_price) order by i.line_number) filter (where i.id is not null),'[]'::jsonb),o.created_at,o.updated_at
    from public.purchase_orders o
    join public.business_parties s on s.tenant_id=o.tenant_id and s.id=o.supplier_id
    left join public.purchase_order_items i on i.tenant_id=o.tenant_id and i.purchase_order_id=o.id
    where o.tenant_id=p_tenant_id and o.branch_id=p_branch_id
      and (p_status is null or o.status=p_status)
      and (p_search is null or s.legal_name ilike '%' || pg_catalog.btrim(p_search) || '%' or o.order_number::text like '%' || pg_catalog.btrim(p_search) || '%')
    group by o.id,s.legal_name
    order by o.created_at desc,o.id desc limit p_limit offset p_offset;
end;
$function$;

create function public.operational_create_purchase_order(
  p_tenant_id uuid,
  p_branch_id uuid,
  p_supplier_id uuid,
  p_items jsonb,
  p_notes text,
  p_request_id uuid
)
returns uuid language plpgsql volatile security definer set search_path = '' set row_security = off as $function$
declare actor_id uuid; order_id uuid; supplied_count integer; inserted_count integer; calculated_total numeric(18,4);
begin
  actor_id:=app_private.assert_operational_permission(p_tenant_id,'transaction.purchasing.purchase_order.create',p_branch_id);
  if p_supplier_id is null or p_request_id is null or p_items is null or pg_catalog.jsonb_typeof(p_items) <> 'array' or pg_catalog.jsonb_array_length(p_items) not between 1 and 100 or (p_notes is not null and pg_catalog.length(pg_catalog.btrim(p_notes)) > 1000) then
    raise exception 'Invalid purchase order request' using errcode='22023';
  end if;
  perform pg_catalog.pg_advisory_xact_lock(pg_catalog.hashtextextended('purchase-order:' || p_tenant_id::text || ':' || p_request_id::text,0));
  select o.id into order_id from public.purchase_orders o where o.tenant_id=p_tenant_id and o.request_id=p_request_id;
  if found then return order_id; end if;
  if not exists (select 1 from public.branches b where b.tenant_id=p_tenant_id and b.id=p_branch_id and b.status='active')
    or not exists (select 1 from public.business_parties s where s.tenant_id=p_tenant_id and s.id=p_supplier_id and s.party_type in ('supplier','both') and s.status='active') then
    raise exception 'Active branch and supplier in this company are required' using errcode='23503';
  end if;
  select count(*),count(distinct entry.item_id) into supplied_count,inserted_count
  from pg_catalog.jsonb_to_recordset(p_items) as entry(item_id uuid,quantity numeric,unit_price numeric);
  if supplied_count <> pg_catalog.jsonb_array_length(p_items) or supplied_count <> inserted_count or exists (
    select 1 from pg_catalog.jsonb_to_recordset(p_items) as entry(item_id uuid,quantity numeric,unit_price numeric)
    where entry.item_id is null or entry.quantity is null or entry.quantity <= 0 or entry.unit_price is null or entry.unit_price < 0
  ) then raise exception 'Purchase order items are invalid' using errcode='22023'; end if;
  insert into public.purchase_orders(tenant_id,branch_id,supplier_id,notes,request_id,created_by_user_id)
  values(p_tenant_id,p_branch_id,p_supplier_id,nullif(pg_catalog.btrim(p_notes),''),p_request_id,actor_id) returning id into order_id;
  with supplied as (
    select (entry.value->>'item_id')::uuid as item_id,(entry.value->>'quantity')::numeric as quantity,(entry.value->>'unit_price')::numeric as unit_price,entry.ordinality
    from pg_catalog.jsonb_array_elements(p_items) with ordinality as entry(value,ordinality)
  ), valid_items as (
    select supplied.* from supplied join public.catalog_items item on item.tenant_id=p_tenant_id and item.id=supplied.item_id and item.item_type='product' and item.status='active'
  ), inserted as (
    insert into public.purchase_order_items(tenant_id,purchase_order_id,line_number,item_id,quantity,unit_price,line_total)
    select p_tenant_id,order_id,ordinality::integer,item_id,quantity,unit_price,pg_catalog.round(quantity*unit_price,4) from valid_items
    returning line_total
  ) select count(*),coalesce(sum(line_total),0) into inserted_count,calculated_total from inserted;
  if inserted_count <> supplied_count then raise exception 'Active products in this company are required' using errcode='23503'; end if;
  update public.purchase_orders set total_amount=calculated_total,updated_at=pg_catalog.clock_timestamp() where id=order_id and tenant_id=p_tenant_id;
  perform app_private.write_operational_audit('purchase_order.created',p_tenant_id,p_branch_id,order_id,actor_id,pg_catalog.jsonb_build_object('request_id',p_request_id,'item_count',supplied_count,'total_amount',calculated_total));
  return order_id;
end;
$function$;

create function public.operational_update_purchase_order(
  p_tenant_id uuid,
  p_purchase_order_id uuid,
  p_supplier_id uuid,
  p_items jsonb,
  p_notes text,
  p_request_id uuid
)
returns uuid language plpgsql volatile security definer set search_path = '' set row_security = off as $function$
declare actor_id uuid; branch_value uuid; supplied_count integer; inserted_count integer; calculated_total numeric(18,4); recorded_order_id uuid;
begin
  actor_id := auth.uid();
  if coalesce(auth.role(), '') <> 'authenticated' or actor_id is null then
    raise exception 'Authenticated session required' using errcode='42501';
  end if;
  if p_purchase_order_id is null or p_supplier_id is null or p_request_id is null or p_items is null or pg_catalog.jsonb_typeof(p_items) <> 'array' or pg_catalog.jsonb_array_length(p_items) not between 1 and 100 or (p_notes is not null and pg_catalog.length(pg_catalog.btrim(p_notes)) > 1000) then
    raise exception 'Invalid purchase order update request' using errcode='22023';
  end if;
  perform pg_catalog.pg_advisory_xact_lock(pg_catalog.hashtextextended('purchase-order-update:' || p_tenant_id::text || ':' || p_request_id::text,0));
  select request_row.purchase_order_id into recorded_order_id from app_private.purchase_order_update_requests request_row where request_row.tenant_id=p_tenant_id and request_row.request_id=p_request_id;
  if found then
    if recorded_order_id <> p_purchase_order_id then raise exception 'Purchase order update request belongs to another order' using errcode='23505'; end if;
    return p_purchase_order_id;
  end if;
  select o.branch_id into branch_value from public.purchase_orders o where o.tenant_id=p_tenant_id and o.id=p_purchase_order_id and o.status='draft' for update;
  if not found then raise exception 'Draft purchase order not found in this company' using errcode='P0002'; end if;
  perform app_private.assert_operational_permission(p_tenant_id,'transaction.purchasing.purchase_order.create',branch_value);
  if not exists (select 1 from public.business_parties s where s.tenant_id=p_tenant_id and s.id=p_supplier_id and s.party_type in ('supplier','both') and s.status='active') then raise exception 'Active supplier in this company is required' using errcode='23503'; end if;
  select count(*),count(distinct entry.item_id) into supplied_count,inserted_count from pg_catalog.jsonb_to_recordset(p_items) as entry(item_id uuid,quantity numeric,unit_price numeric);
  if supplied_count <> pg_catalog.jsonb_array_length(p_items) or supplied_count <> inserted_count or exists (select 1 from pg_catalog.jsonb_to_recordset(p_items) as entry(item_id uuid,quantity numeric,unit_price numeric) where entry.item_id is null or entry.quantity is null or entry.quantity <= 0 or entry.unit_price is null or entry.unit_price < 0) then raise exception 'Purchase order items are invalid' using errcode='22023'; end if;
  delete from public.purchase_order_items where tenant_id=p_tenant_id and purchase_order_id=p_purchase_order_id;
  with supplied as (select (entry.value->>'item_id')::uuid as item_id,(entry.value->>'quantity')::numeric as quantity,(entry.value->>'unit_price')::numeric as unit_price,entry.ordinality from pg_catalog.jsonb_array_elements(p_items) with ordinality as entry(value,ordinality)), valid_items as (select supplied.* from supplied join public.catalog_items item on item.tenant_id=p_tenant_id and item.id=supplied.item_id and item.item_type='product' and item.status='active'), inserted as (insert into public.purchase_order_items(tenant_id,purchase_order_id,line_number,item_id,quantity,unit_price,line_total) select p_tenant_id,p_purchase_order_id,ordinality::integer,item_id,quantity,unit_price,pg_catalog.round(quantity*unit_price,4) from valid_items returning line_total) select count(*),coalesce(sum(line_total),0) into inserted_count,calculated_total from inserted;
  if inserted_count <> supplied_count then raise exception 'Active products in this company are required' using errcode='23503'; end if;
  update public.purchase_orders set supplier_id=p_supplier_id,notes=nullif(pg_catalog.btrim(p_notes),''),total_amount=calculated_total,updated_at=pg_catalog.clock_timestamp() where tenant_id=p_tenant_id and id=p_purchase_order_id;
  insert into app_private.purchase_order_update_requests(tenant_id,purchase_order_id,request_id) values(p_tenant_id,p_purchase_order_id,p_request_id);
  perform app_private.write_operational_audit('purchase_order.updated',p_tenant_id,branch_value,p_purchase_order_id,actor_id,pg_catalog.jsonb_build_object('request_id',p_request_id,'item_count',supplied_count,'total_amount',calculated_total));
  return p_purchase_order_id;
end;
$function$;

alter function public.operational_list_inventory_movements(uuid,uuid,uuid,text,timestamptz,timestamptz,integer,integer) owner to postgres;
alter function public.operational_list_purchase_orders(uuid,uuid,text,text,integer,integer) owner to postgres;
alter function public.operational_create_purchase_order(uuid,uuid,uuid,jsonb,text,uuid) owner to postgres;
alter function public.operational_update_purchase_order(uuid,uuid,uuid,jsonb,text,uuid) owner to postgres;
revoke all on function public.operational_list_inventory_movements(uuid,uuid,uuid,text,timestamptz,timestamptz,integer,integer), public.operational_list_purchase_orders(uuid,uuid,text,text,integer,integer), public.operational_create_purchase_order(uuid,uuid,uuid,jsonb,text,uuid), public.operational_update_purchase_order(uuid,uuid,uuid,jsonb,text,uuid) from public,anon,authenticated,service_role;
grant execute on function public.operational_list_inventory_movements(uuid,uuid,uuid,text,timestamptz,timestamptz,integer,integer), public.operational_list_purchase_orders(uuid,uuid,text,text,integer,integer), public.operational_create_purchase_order(uuid,uuid,uuid,jsonb,text,uuid), public.operational_update_purchase_order(uuid,uuid,uuid,jsonb,text,uuid) to authenticated;

commit;
