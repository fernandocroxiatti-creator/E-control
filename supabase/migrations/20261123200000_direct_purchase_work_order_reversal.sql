begin;

-- A direct-purchase reversal is deliberately independent from stock and
-- financial ledgers. It can become operational only after a future billing
-- phase supplies the trusted "not billed" contract below.
do $preflight$
begin
  if current_user <> 'postgres' then raise exception 'Apply this migration as postgres'; end if;
  if pg_catalog.to_regclass('public.work_order_direct_purchases') is null
     or pg_catalog.to_regclass('public.work_orders') is null
     or pg_catalog.to_regclass('public.work_order_events') is null
     or pg_catalog.to_regprocedure('app_private.assert_operational_permission(uuid,text,uuid)') is null
     or pg_catalog.to_regprocedure('app_private.write_operational_audit(text,uuid,uuid,uuid,uuid,jsonb)') is null then
    raise exception 'Direct-purchase and work-order foundations are required';
  end if;
end;
$preflight$;

create table public.work_order_direct_purchase_reversals (
  id uuid primary key default pg_catalog.gen_random_uuid(),
  tenant_id uuid not null references public.companies(id) on delete restrict,
  branch_id uuid not null,
  work_order_id uuid not null,
  direct_purchase_id uuid not null,
  reversed_quantity numeric(18,4) not null check (reversed_quantity > 0),
  reversed_total_cost numeric(24,8) not null check (reversed_total_cost >= 0),
  reason text,
  request_payload jsonb not null check (pg_catalog.jsonb_typeof(request_payload)='object'),
  request_id uuid not null,
  created_by_user_id uuid not null references auth.users(id) on delete restrict,
  created_at timestamptz not null default pg_catalog.clock_timestamp(),
  unique (tenant_id,id),
  unique (tenant_id,request_id),
  unique (tenant_id,direct_purchase_id),
  foreign key (tenant_id,branch_id) references public.branches(tenant_id,id) on delete restrict,
  foreign key (tenant_id,work_order_id) references public.work_orders(tenant_id,id) on delete restrict,
  foreign key (tenant_id,direct_purchase_id) references public.work_order_direct_purchases(tenant_id,id) on delete restrict
);
create index work_order_direct_purchase_reversals_order_idx on public.work_order_direct_purchase_reversals(tenant_id,branch_id,work_order_id,created_at desc);

alter table public.work_order_direct_purchase_reversals owner to postgres;
alter table public.work_order_direct_purchase_reversals enable row level security;
alter table public.work_order_direct_purchase_reversals force row level security;
revoke all on table public.work_order_direct_purchase_reversals from public, anon, authenticated, service_role;

-- There is currently no billing model for work orders. This explicit guard is
-- intentionally fail-closed; a future billing migration must replace it with a
-- trusted, tenant-scoped billing assertion before reversals can be performed.
create function app_private.assert_work_order_not_billed(p_tenant_id uuid,p_work_order_id uuid)
returns void language plpgsql stable security definer
set search_path='' set row_security=off
as $fn$
begin
  raise exception 'Direct-purchase reversal is unavailable until a trusted work-order billing status contract is installed'
    using errcode='55000';
end;
$fn$;

create function public.operational_reverse_work_order_direct_purchase(
  p_tenant_id uuid,
  p_work_order_id uuid,
  p_direct_purchase_id uuid,
  p_reason text,
  p_request_id uuid
)
returns uuid
language plpgsql volatile security definer
set search_path='' set row_security=off
as $fn$
declare
  actor uuid;
  branch uuid;
  work_order_status text;
  purchase public.work_order_direct_purchases%rowtype;
  existing public.work_order_direct_purchase_reversals%rowtype;
  normalized_reason text := nullif(pg_catalog.btrim(coalesce(p_reason,'')), '');
  normalized_payload jsonb;
  reversal_id uuid;
begin
  if p_tenant_id is null or p_work_order_id is null or p_direct_purchase_id is null or p_request_id is null
     or (normalized_reason is not null and pg_catalog.length(normalized_reason)>1000) then
    raise exception 'Valid direct-purchase reversal identifiers and optional reason are required' using errcode='22023';
  end if;

  -- Work-order lock is the first shared lock in both direct-purchase commands.
  select branch_id,status into branch,work_order_status
    from public.work_orders
   where tenant_id=p_tenant_id and id=p_work_order_id
   for update;
  if not found then raise exception 'Work order in this company is required' using errcode='P0002'; end if;
  actor := app_private.assert_operational_permission(p_tenant_id,'transaction.service_order.update',branch);
  if work_order_status <> 'open' then
    raise exception 'Direct purchases may be reversed only while the work order is open' using errcode='55000';
  end if;

  select * into purchase
    from public.work_order_direct_purchases
   where tenant_id=p_tenant_id and id=p_direct_purchase_id and work_order_id=p_work_order_id
   for update;
  if not found then raise exception 'Direct purchase does not belong to this work order in this company' using errcode='P0002'; end if;
  if purchase.branch_id <> branch then raise exception 'Direct purchase branch does not match the work order' using errcode='23503'; end if;

  normalized_payload := pg_catalog.jsonb_build_object(
    'work_order_id',p_work_order_id,
    'direct_purchase_id',p_direct_purchase_id,
    'reason',normalized_reason
  );
  perform pg_catalog.pg_advisory_xact_lock(pg_catalog.hashtextextended('work-order-direct-purchase-reversal:'||p_tenant_id::text||':'||p_request_id::text,0));

  select * into existing
    from public.work_order_direct_purchase_reversals
   where tenant_id=p_tenant_id and request_id=p_request_id;
  if found then
    if existing.request_payload is distinct from normalized_payload
       or existing.created_by_user_id is distinct from actor then
      raise exception 'Direct-purchase reversal request identifier belongs to a different payload' using errcode='23505';
    end if;
    return existing.id;
  end if;

  -- R01 is never inferred from the absence of a billing table or column.
  perform app_private.assert_work_order_not_billed(p_tenant_id,p_work_order_id);

  if exists(select 1 from public.work_order_direct_purchase_reversals where tenant_id=p_tenant_id and direct_purchase_id=p_direct_purchase_id) then
    raise exception 'This direct purchase has already been reversed' using errcode='23505';
  end if;
  if (select direct_purchase_total from public.work_orders where tenant_id=p_tenant_id and id=p_work_order_id) < purchase.total_cost then
    raise exception 'Direct-purchase total cannot be compensated below zero' using errcode='23514';
  end if;

  insert into public.work_order_direct_purchase_reversals(tenant_id,branch_id,work_order_id,direct_purchase_id,reversed_quantity,reversed_total_cost,reason,request_payload,request_id,created_by_user_id)
  values(p_tenant_id,branch,p_work_order_id,p_direct_purchase_id,purchase.quantity,purchase.total_cost,normalized_reason,normalized_payload,p_request_id,actor)
  returning id into reversal_id;
  update public.work_orders
     set direct_purchase_total=direct_purchase_total-purchase.total_cost,
         updated_at=pg_catalog.clock_timestamp()
   where tenant_id=p_tenant_id and id=p_work_order_id;
  insert into public.work_order_events(tenant_id,work_order_id,event_key,actor_user_id,details)
  values(p_tenant_id,p_work_order_id,'work_order.direct_purchase.reversed',actor,
    pg_catalog.jsonb_build_object('direct_purchase_id',p_direct_purchase_id,'direct_purchase_reversal_id',reversal_id,'quantity',purchase.quantity,'total_cost',purchase.total_cost,'reason',normalized_reason));
  perform app_private.write_operational_audit('work_order.direct_purchase.reversed',p_tenant_id,branch,reversal_id,actor,
    pg_catalog.jsonb_build_object('work_order_id',p_work_order_id,'direct_purchase_id',p_direct_purchase_id,'quantity',purchase.quantity,'total_cost',purchase.total_cost,'reason',normalized_reason));
  return reversal_id;
end;
$fn$;

create function public.operational_list_work_order_direct_purchase_reversals(
  p_tenant_id uuid,p_branch_id uuid,p_work_order_id uuid default null,p_limit integer default 100,p_offset integer default 0
)
returns table(direct_purchase_reversal_id uuid,direct_purchase_id uuid,work_order_id uuid,reversed_quantity numeric,reversed_total_cost numeric,reason text,created_at timestamptz)
language plpgsql stable security definer
set search_path='' set row_security=off
as $fn$
begin
  perform app_private.assert_operational_permission(p_tenant_id,'transaction.service_order.read',p_branch_id);
  if p_limit not between 1 and 100 or p_offset<0 then raise exception 'Invalid direct-purchase reversal listing request' using errcode='22023'; end if;
  return query
  select r.id,r.direct_purchase_id,r.work_order_id,r.reversed_quantity,r.reversed_total_cost,r.reason,r.created_at
    from public.work_order_direct_purchase_reversals r
   where r.tenant_id=p_tenant_id and r.branch_id=p_branch_id
     and (p_work_order_id is null or r.work_order_id=p_work_order_id)
   order by r.created_at desc,r.id desc
   limit p_limit offset p_offset;
end;
$fn$;

alter function app_private.assert_work_order_not_billed(uuid,uuid) owner to postgres;
alter function public.operational_reverse_work_order_direct_purchase(uuid,uuid,uuid,text,uuid) owner to postgres;
alter function public.operational_list_work_order_direct_purchase_reversals(uuid,uuid,uuid,integer,integer) owner to postgres;
revoke all on function app_private.assert_work_order_not_billed(uuid,uuid),public.operational_reverse_work_order_direct_purchase(uuid,uuid,uuid,text,uuid),public.operational_list_work_order_direct_purchase_reversals(uuid,uuid,uuid,integer,integer) from public,anon,authenticated,service_role;
grant execute on function public.operational_reverse_work_order_direct_purchase(uuid,uuid,uuid,text,uuid),public.operational_list_work_order_direct_purchase_reversals(uuid,uuid,uuid,integer,integer) to authenticated;

do $verify$
begin
  if pg_catalog.has_table_privilege('authenticated','public.work_order_direct_purchase_reversals','select')
     or pg_catalog.has_function_privilege('anon','public.operational_reverse_work_order_direct_purchase(uuid,uuid,uuid,text,uuid)','execute')
     or pg_catalog.has_function_privilege('service_role','public.operational_reverse_work_order_direct_purchase(uuid,uuid,uuid,text,uuid)','execute') then
    raise exception 'Direct-purchase reversal access is not closed';
  end if;
end;
$verify$;

commit;
