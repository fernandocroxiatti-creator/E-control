-- Package 05: safe read models for the inventory-count and work-order flows.
-- Prepared only. Do not apply remotely without an explicit Production approval.
-- This migration does not enable a company, approve a catalog entry, grant a
-- role permission, or create operational data.
begin;

do $preflight$
begin
  if current_user <> 'postgres' then raise exception 'Apply this migration as postgres'; end if;
  if pg_catalog.to_regclass('public.inventory_count_sessions') is null
    or pg_catalog.to_regclass('public.work_orders') is null
    or pg_catalog.to_regprocedure('app_private.assert_operational_permission(uuid,text,uuid)') is null then
    raise exception 'Package 04 inventory and work-order foundation is required';
  end if;
  if pg_catalog.to_regprocedure('public.operational_get_work_order_detail(uuid,uuid)') is not null then
    raise exception 'Package 05 read models already exist; inspect before applying';
  end if;
end;
$preflight$;

create function app_private.assert_inventory_count_read_permission(p_tenant_id uuid,p_branch_id uuid)
returns uuid language plpgsql stable security definer set search_path='' set row_security=off as $fn$
declare permission_key text; actor uuid;
begin
  -- A counter, creator, or adjuster can reopen the same branch-scoped count.
  -- Each candidate keeps its own role grant, global approval and company
  -- availability check through the canonical assertion.
  foreach permission_key in array array['transaction.inventory.physical.count','transaction.inventory.physical.create','transaction.inventory.physical.adjust'] loop
    begin
      actor:=app_private.assert_operational_permission(p_tenant_id,permission_key,p_branch_id);
      return actor;
    exception when insufficient_privilege then null;
    end;
  end loop;
  raise exception 'Operational inventory-count read permission denied' using errcode='42501';
end;
$fn$;

create function public.operational_list_inventory_count_sessions(
  p_tenant_id uuid,p_branch_id uuid,p_status text default null,p_limit integer default 50,p_offset integer default 0
)
returns table(count_session_id uuid,status text,notes text,created_at timestamptz,posted_at timestamptz,line_count bigint)
language plpgsql stable security definer set search_path='' set row_security=off as $fn$
begin
  perform app_private.assert_inventory_count_read_permission(p_tenant_id,p_branch_id);
  if p_limit not between 1 and 100 or p_offset < 0
    or (p_status is not null and p_status not in ('open','posted')) then
    raise exception 'Invalid inventory count listing request' using errcode='22023';
  end if;
  return query
    select session.id,session.status,session.notes,session.created_at,session.posted_at,count(line.item_id)
    from public.inventory_count_sessions session
    left join public.inventory_count_lines line on line.tenant_id=session.tenant_id and line.session_id=session.id
    where session.tenant_id=p_tenant_id and session.branch_id=p_branch_id
      and (p_status is null or session.status=p_status)
    group by session.id,session.status,session.notes,session.created_at,session.posted_at
    order by session.created_at desc,session.id desc limit p_limit offset p_offset;
end;
$fn$;

create function public.operational_list_inventory_transfers(
  p_tenant_id uuid,p_branch_id uuid,p_limit integer default 50,p_offset integer default 0
)
returns table(transfer_id uuid,source_branch_id uuid,destination_branch_id uuid,item_id uuid,item_code text,item_name text,quantity numeric,reference_note text,created_at timestamptz)
language plpgsql stable security definer set search_path='' set row_security=off as $fn$
begin
  perform app_private.assert_operational_permission(p_tenant_id,'transaction.inventory.transfer',p_branch_id);
  if p_limit not between 1 and 100 or p_offset < 0 then raise exception 'Invalid transfer listing request' using errcode='22023'; end if;
  return query
    select transfer.id,transfer.source_branch_id,transfer.destination_branch_id,transfer.item_id,item.code,item.name,transfer.quantity,transfer.reference_note,transfer.created_at
    from public.inventory_transfers transfer
    join public.catalog_items item on item.tenant_id=transfer.tenant_id and item.id=transfer.item_id
    where transfer.tenant_id=p_tenant_id and (transfer.source_branch_id=p_branch_id or transfer.destination_branch_id=p_branch_id)
    order by transfer.created_at desc,transfer.id desc limit p_limit offset p_offset;
end;
$fn$;

create function public.operational_get_work_order_detail(p_tenant_id uuid,p_work_order_id uuid)
returns jsonb language plpgsql stable security definer set search_path='' set row_security=off as $fn$
declare order_branch uuid; payload jsonb;
begin
  select branch_id into order_branch from public.work_orders where tenant_id=p_tenant_id and id=p_work_order_id;
  if not found then raise exception 'Work order not found' using errcode='P0002'; end if;
  perform app_private.assert_operational_permission(p_tenant_id,'transaction.service_order.read',order_branch);
  select pg_catalog.jsonb_build_object(
    'work_order_id',order_row.id,'order_number',order_row.order_number,'branch_id',order_row.branch_id,
    'customer_name',customer.legal_name,'equipment_description',order_row.equipment_description,
    'problem_description',order_row.problem_description,'diagnosis',order_row.diagnosis,'status',order_row.status,
    'service_total',order_row.service_total,'parts_total',order_row.parts_total,'discount_total',order_row.discount_total,
    'total_amount',order_row.total_amount,'created_at',order_row.created_at,'updated_at',order_row.updated_at,'closed_at',order_row.closed_at,
    'lines',coalesce((select pg_catalog.jsonb_agg(pg_catalog.jsonb_build_object(
      'line_number',line.line_number,'line_type',line.line_type,'item_id',line.item_id,'description',line.description,
      'quantity',line.quantity,'unit_price',line.unit_price,'discount_amount',line.discount_amount,'line_total',line.line_total
    ) order by line.line_number) from public.work_order_lines line where line.tenant_id=p_tenant_id and line.work_order_id=order_row.id),'[]'::jsonb),
    'reservations',coalesce((select pg_catalog.jsonb_agg(pg_catalog.jsonb_build_object(
      'item_id',reservation.item_id,'quantity',reservation.quantity,'status',reservation.status,'reserved_at',reservation.reserved_at,'consumed_at',reservation.consumed_at
    ) order by reservation.item_id) from public.work_order_part_reservations reservation where reservation.tenant_id=p_tenant_id and reservation.work_order_id=order_row.id),'[]'::jsonb),
    'events',coalesce((select pg_catalog.jsonb_agg(pg_catalog.jsonb_build_object(
      'event_key',event.event_key,'details',event.details,'created_at',event.created_at
    ) order by event.created_at,event.id) from public.work_order_events event where event.tenant_id=p_tenant_id and event.work_order_id=order_row.id),'[]'::jsonb)
  ) into payload
  from public.work_orders order_row
  join public.business_parties customer on customer.tenant_id=order_row.tenant_id and customer.id=order_row.customer_id
  where order_row.tenant_id=p_tenant_id and order_row.id=p_work_order_id;
  return payload;
end;
$fn$;

alter function app_private.assert_inventory_count_read_permission(uuid,uuid) owner to postgres;
alter function public.operational_list_inventory_count_sessions(uuid,uuid,text,integer,integer) owner to postgres;
alter function public.operational_list_inventory_transfers(uuid,uuid,integer,integer) owner to postgres;
alter function public.operational_get_work_order_detail(uuid,uuid) owner to postgres;
revoke all on function public.operational_list_inventory_count_sessions(uuid,uuid,text,integer,integer),public.operational_list_inventory_transfers(uuid,uuid,integer,integer),public.operational_get_work_order_detail(uuid,uuid) from public,anon,authenticated,service_role;
revoke all on function app_private.assert_inventory_count_read_permission(uuid,uuid) from public,anon,authenticated,service_role;
grant execute on function public.operational_list_inventory_count_sessions(uuid,uuid,text,integer,integer),public.operational_list_inventory_transfers(uuid,uuid,integer,integer),public.operational_get_work_order_detail(uuid,uuid) to authenticated;

do $verify$
declare routine text;
begin
  foreach routine in array array[
    'app_private.assert_inventory_count_read_permission(uuid,uuid)',
    'public.operational_list_inventory_count_sessions(uuid,uuid,text,integer,integer)',
    'public.operational_list_inventory_transfers(uuid,uuid,integer,integer)',
    'public.operational_get_work_order_detail(uuid,uuid)'
  ] loop
    if not exists(select 1 from pg_catalog.pg_proc p where p.oid=pg_catalog.to_regprocedure(routine) and p.prosecdef and p.proconfig @> array['search_path=""','row_security=off']) then
      raise exception 'Unsafe read RPC: %',routine;
    end if;
    if has_function_privilege('anon',pg_catalog.to_regprocedure(routine),'execute') or has_function_privilege('service_role',pg_catalog.to_regprocedure(routine),'execute') then
      raise exception 'Broad read RPC grant: %',routine;
    end if;
  end loop;
end;
$verify$;

commit;
