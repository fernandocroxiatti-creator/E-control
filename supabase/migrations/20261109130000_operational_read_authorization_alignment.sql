-- Prepared only. Do not apply remotely without a separate Production approval.
-- Aligns the read models with the already-authorized operational transactions;
-- it neither grants a role permission nor enables a company transaction.
begin;

do $preflight$
begin
  if current_user <> 'postgres' then raise exception 'Apply this migration as postgres'; end if;
  if pg_catalog.to_regprocedure('app_private.assert_operational_permission(uuid,text,uuid)') is null
    or pg_catalog.to_regprocedure('public.operational_list_business_parties(uuid,text,text,text,integer,integer)') is null
    or pg_catalog.to_regprocedure('public.operational_list_catalog_items(uuid,text,text,text,integer,integer)') is null
    or pg_catalog.to_regprocedure('public.operational_list_inventory_balances(uuid,uuid,text,integer,integer)') is null
    or pg_catalog.to_regprocedure('public.operational_list_inventory_movements(uuid,uuid,uuid,text,timestamptz,timestamptz,integer,integer)') is null then
    raise exception 'Operational read contracts and hardened assertion are required';
  end if;
end;
$preflight$;

-- BP01 grants the commercial-party workflow, including its own lookup.
create or replace function public.operational_list_business_parties(p_tenant_id uuid,p_search text default null,p_party_type text default null,p_status text default null,p_limit integer default 50,p_offset integer default 0)
returns table(party_id uuid,party_type text,legal_name text,document_number text,contact_email text,contact_phone text,status text,created_at timestamptz)
language plpgsql stable security definer set search_path='' set row_security=off as $fn$
begin
  perform app_private.assert_operational_permission(p_tenant_id,'transaction.masterdata.party.manage');
  if p_limit not between 1 and 100 or p_offset < 0 or (p_party_type is not null and p_party_type not in ('customer','supplier','both')) or (p_status is not null and p_status not in ('active','inactive')) then raise exception 'Invalid business party listing request' using errcode='22023'; end if;
  return query select p.id,p.party_type,p.legal_name,p.document_number,p.contact_email,p.contact_phone,p.status,p.created_at
    from public.business_parties p where p.tenant_id=p_tenant_id
      and (p_search is null or p.legal_name ilike '%'||pg_catalog.btrim(p_search)||'%' or coalesce(p.document_number,'') like '%'||pg_catalog.btrim(p_search)||'%')
      and (p_party_type is null or p.party_type=p_party_type or p.party_type='both') and (p_status is null or p.status=p_status)
    order by p.legal_name,p.id limit p_limit offset p_offset;
end;
$fn$;

-- A manage transaction can inspect only its own item type. A cross-type catalog
-- listing remains reserved for transaction.masterdata.catalog.read.
create or replace function public.operational_list_catalog_items(p_tenant_id uuid,p_search text default null,p_item_type text default null,p_status text default null,p_limit integer default 50,p_offset integer default 0)
returns table(item_id uuid,item_type text,code text,name text,category text,unit_of_measure text,current_cost numeric,selling_price numeric,minimum_stock numeric,reorder_point numeric,status text,created_at timestamptz)
language plpgsql stable security definer set search_path='' set row_security=off as $fn$
begin
  if p_item_type='product' then perform app_private.assert_operational_permission(p_tenant_id,'transaction.masterdata.catalog.product.manage');
  elsif p_item_type='service' then perform app_private.assert_operational_permission(p_tenant_id,'transaction.masterdata.catalog.service.manage');
  else perform app_private.assert_operational_permission(p_tenant_id,'transaction.masterdata.catalog.read');
  end if;
  if p_limit not between 1 and 100 or p_offset < 0 or (p_item_type is not null and p_item_type not in ('product','service')) or (p_status is not null and p_status not in ('active','inactive')) then raise exception 'Invalid catalog listing request' using errcode='22023'; end if;
  return query select i.id,i.item_type,i.code,i.name,i.category,i.unit_of_measure,i.current_cost,i.selling_price,i.minimum_stock,i.reorder_point,i.status,i.created_at
    from public.catalog_items i where i.tenant_id=p_tenant_id
      and (p_search is null or i.code ilike '%'||pg_catalog.btrim(p_search)||'%' or i.name ilike '%'||pg_catalog.btrim(p_search)||'%')
      and (p_item_type is null or i.item_type=p_item_type) and (p_status is null or i.status=p_status)
    order by i.name,i.id limit p_limit offset p_offset;
end;
$fn$;

-- MIGO includes the balance and recent-movement context needed to validate a
-- movement. It remains tenant/branch scoped and requires its existing grant.
create or replace function public.operational_list_inventory_balances(p_tenant_id uuid,p_branch_id uuid,p_search text default null,p_limit integer default 50,p_offset integer default 0)
returns table(item_id uuid,code text,name text,quantity numeric,minimum_stock numeric,reorder_point numeric,below_reorder_point boolean)
language plpgsql stable security definer set search_path='' set row_security=off as $fn$
begin
  perform app_private.assert_operational_permission(p_tenant_id,'transaction.inventory.stock.move',p_branch_id);
  if p_limit not between 1 and 100 or p_offset<0 then raise exception 'Invalid inventory listing request' using errcode='22023'; end if;
  return query select i.id,i.code,i.name,coalesce(b.quantity,0),i.minimum_stock,i.reorder_point,(coalesce(b.quantity,0)<=i.reorder_point)
    from public.catalog_items i left join public.inventory_balances b on b.tenant_id=i.tenant_id and b.branch_id=p_branch_id and b.item_id=i.id
    where i.tenant_id=p_tenant_id and i.item_type='product' and i.status='active' and (p_search is null or i.code ilike '%'||pg_catalog.btrim(p_search)||'%' or i.name ilike '%'||pg_catalog.btrim(p_search)||'%')
    order by i.name,i.id limit p_limit offset p_offset;
end;
$fn$;

create or replace function public.operational_list_inventory_movements(p_tenant_id uuid,p_branch_id uuid,p_item_id uuid default null,p_movement_type text default null,p_from timestamptz default null,p_to timestamptz default null,p_limit integer default 50,p_offset integer default 0)
returns table(movement_id uuid,item_id uuid,item_code text,item_name text,movement_type text,quantity numeric,balance_after numeric,reference_note text,created_at timestamptz)
language plpgsql stable security definer set search_path='' set row_security=off as $fn$
begin
  perform app_private.assert_operational_permission(p_tenant_id,'transaction.inventory.stock.move',p_branch_id);
  if p_limit not between 1 and 100 or p_offset<0 or (p_movement_type is not null and p_movement_type not in ('initial','entry','exit','adjustment_positive','adjustment_negative')) or (p_from is not null and p_to is not null and p_from>p_to) then raise exception 'Invalid inventory movement listing request' using errcode='22023'; end if;
  return query select m.id,m.item_id,i.code,i.name,m.movement_type,m.quantity,m.balance_after,m.reference_note,m.created_at
    from public.inventory_movements m join public.catalog_items i on i.tenant_id=m.tenant_id and i.id=m.item_id
    where m.tenant_id=p_tenant_id and m.branch_id=p_branch_id and (p_item_id is null or m.item_id=p_item_id)
      and (p_movement_type is null or m.movement_type=p_movement_type) and (p_from is null or m.created_at>=p_from) and (p_to is null or m.created_at<=p_to)
    order by m.created_at desc,m.id desc limit p_limit offset p_offset;
end;
$fn$;

alter function public.operational_list_business_parties(uuid,text,text,text,integer,integer) owner to postgres;
alter function public.operational_list_catalog_items(uuid,text,text,text,integer,integer) owner to postgres;
alter function public.operational_list_inventory_balances(uuid,uuid,text,integer,integer) owner to postgres;
alter function public.operational_list_inventory_movements(uuid,uuid,uuid,text,timestamptz,timestamptz,integer,integer) owner to postgres;
revoke all on function public.operational_list_business_parties(uuid,text,text,text,integer,integer),public.operational_list_catalog_items(uuid,text,text,text,integer,integer),public.operational_list_inventory_balances(uuid,uuid,text,integer,integer),public.operational_list_inventory_movements(uuid,uuid,uuid,text,timestamptz,timestamptz,integer,integer) from public,anon,authenticated,service_role;
grant execute on function public.operational_list_business_parties(uuid,text,text,text,integer,integer),public.operational_list_catalog_items(uuid,text,text,text,integer,integer),public.operational_list_inventory_balances(uuid,uuid,text,integer,integer),public.operational_list_inventory_movements(uuid,uuid,uuid,text,timestamptz,timestamptz,integer,integer) to authenticated;

do $verify$
declare routine oid;
begin
  foreach routine in array array[
    pg_catalog.to_regprocedure('public.operational_list_business_parties(uuid,text,text,text,integer,integer)'),
    pg_catalog.to_regprocedure('public.operational_list_catalog_items(uuid,text,text,text,integer,integer)'),
    pg_catalog.to_regprocedure('public.operational_list_inventory_balances(uuid,uuid,text,integer,integer)'),
    pg_catalog.to_regprocedure('public.operational_list_inventory_movements(uuid,uuid,uuid,text,timestamptz,timestamptz,integer,integer)')
  ] loop
    if routine is null or not exists(select 1 from pg_catalog.pg_proc where oid=routine and proowner='postgres'::regrole and prosecdef and 'search_path=""'=any(proconfig) and 'row_security=off'=any(proconfig)) or pg_catalog.has_function_privilege('anon',routine,'EXECUTE') or pg_catalog.has_function_privilege('service_role',routine,'EXECUTE') then raise exception 'Unsafe operational read contract'; end if;
  end loop;
end;
$verify$;

commit;
