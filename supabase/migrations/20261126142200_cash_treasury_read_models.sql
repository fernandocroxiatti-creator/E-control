begin;

-- Extend the central authorization map; availability remains explicitly per company.
create or replace function app_private.assert_operational_permission(p_tenant_id uuid,p_permission_key text,p_branch_id uuid default null)
returns uuid language plpgsql stable security definer set search_path='' set row_security=off as $fn$
declare actor_id uuid; required_codes text[]; ready_count integer;
begin
  if coalesce(auth.role(),'')<>'authenticated' or auth.uid() is null then raise exception 'Authenticated session required' using errcode='42501'; end if;
  actor_id:=auth.uid();
  if p_tenant_id is null or p_permission_key is null or not exists(select 1 from public.companies where id=p_tenant_id and status='active') or not app_private.is_active_company_member(p_tenant_id) or (p_branch_id is not null and not app_private.can_access_branch(p_tenant_id,p_branch_id)) or not app_private.has_tenant_permission(p_tenant_id,p_permission_key,p_branch_id) or not exists(select 1 from public.permission_definitions where permission_key=p_permission_key and approval_state='approved') then raise exception 'Operational permission denied' using errcode='42501'; end if;
  required_codes:=case
    when p_permission_key in ('transaction.masterdata.party.read','transaction.masterdata.party.manage') then array['BP01'] when p_permission_key='transaction.masterdata.catalog.read' then array['MM01','SV01'] when p_permission_key='transaction.masterdata.catalog.product.manage' then array['MM01'] when p_permission_key='transaction.masterdata.catalog.service.manage' then array['SV01'] when p_permission_key='transaction.inventory.stock.read' then array['MIGO'] when p_permission_key='transaction.purchasing.purchase_order.read' then array['ME23N'] when p_permission_key='transaction.purchasing.purchase_order.create' then array['ME21N'] when p_permission_key='transaction.masterdata.catalog.product.update' then array['MM02'] when p_permission_key='transaction.masterdata.catalog.product.read' then array['MM03'] when p_permission_key='transaction.inventory.balance.read' then array['MB52'] when p_permission_key='transaction.inventory.history.read' then array['MB51'] when p_permission_key='transaction.inventory.physical.create' then array['MI01'] when p_permission_key='transaction.inventory.physical.count' then array['MI04'] when p_permission_key='transaction.inventory.physical.adjust' then array['MI07'] when p_permission_key='transaction.inventory.transfer' then array['ZTR01'] when p_permission_key='transaction.service_order.create' then array['ZOS01'] when p_permission_key='transaction.service_order.update' then array['ZOS02'] when p_permission_key='transaction.service_order.read' then array['ZOS03'] when p_permission_key='transaction.service_order.close' then array['ZOS04'] when p_permission_key='transaction.purchasing.receipt.manage' then array['ZGR01'] when p_permission_key='transaction.inventory.valuation.initial' then array['ZIV01'] when p_permission_key='transaction.quotation.create' then array['ZQT01'] when p_permission_key='transaction.quotation.manage' then array['ZQT02'] when p_permission_key='transaction.quotation.read' then array['ZQT03'] when p_permission_key='transaction.quotation.approve' then array['ZQT04'] when p_permission_key='transaction.sales.order.create' then array['ZVE01'] when p_permission_key='transaction.sales.order.manage' then array['ZVE02'] when p_permission_key='transaction.sales.order.read' then array['ZVE03'] when p_permission_key='transaction.sales.order.decide' then array['ZVE04'] when p_permission_key='transaction.finance.payable.manage' then array['ZFI01'] when p_permission_key='transaction.finance.receivable.manage' then array['ZFI02'] when p_permission_key='transaction.finance.settlement.manage' then array['ZFI03'] when p_permission_key='transaction.finance.read' then array['ZFI04'] when p_permission_key='transaction.cash.register.open' then array['ZCX01'] when p_permission_key='transaction.cash.register.move' then array['ZCX02'] when p_permission_key='transaction.cash.register.close' then array['ZCX03'] when p_permission_key='transaction.cash.register.read' then array['ZCX04'] else null end;
  -- Keep mappings introduced by the already-published Sales Inventory and Billing
  -- migrations. This migration intentionally extends (rather than narrows) the
  -- central authorization contract.
  if p_permission_key='transaction.sales.inventory.reserve' then required_codes:=array['ZVE05']; end if;
  if p_permission_key='transaction.sales.inventory.fulfill' then required_codes:=array['ZVE06']; end if;
  if p_permission_key='transaction.sales.inventory.return' then required_codes:=array['ZVE07']; end if;
  if p_permission_key='transaction.billing.issue' then required_codes:=array['ZFB01']; end if;
  if p_permission_key='transaction.billing.read' then required_codes:=array['ZFB02']; end if;
  if p_permission_key='transaction.billing.cancel' then required_codes:=array['ZFB03']; end if;
  if required_codes is null then raise exception 'Operational permission is not mapped to an approved transaction' using errcode='42501'; end if;
  select count(distinct c.transaction_code) into ready_count from public.erp_transaction_authorization_catalog c join public.permission_definitions p on p.permission_key=c.permission_key and p.approval_state='approved' join public.company_module_availability m on m.tenant_id=p_tenant_id and m.module_code=c.module_code and m.enabled join public.company_transaction_availability t on t.tenant_id=p_tenant_id and t.transaction_code=c.transaction_code and t.enabled where c.transaction_code=any(required_codes) and c.approval_state='approved';
  if ready_count<>cardinality(required_codes) then raise exception 'Operational transaction is not approved or available for this company' using errcode='42501'; end if;
  return actor_id;
end;$fn$;
alter function app_private.assert_operational_permission(uuid,text,uuid) owner to postgres;
revoke all on function app_private.assert_operational_permission(uuid,text,uuid) from public,anon,authenticated,service_role;

create function public.operational_create_cash_register(p_tenant_id uuid,p_branch_id uuid,p_code text,p_name text,p_request_id uuid)
returns uuid language plpgsql volatile security definer set search_path='' set row_security=off as $f$
declare actor uuid; existing public.cash_registers%rowtype; result uuid; code_text text:=pg_catalog.upper(pg_catalog.btrim(coalesce(p_code,''))); name_text text:=pg_catalog.btrim(coalesce(p_name,'')); payload jsonb;
begin
  if p_tenant_id is null or p_branch_id is null or p_request_id is null or pg_catalog.length(code_text) not between 2 and 32 or code_text !~ '^[A-Z0-9][A-Z0-9_-]*$' or pg_catalog.length(name_text) not between 2 and 160 then raise exception 'Valid cash register data is required' using errcode='22023'; end if;
  actor:=app_private.assert_operational_permission(p_tenant_id,'transaction.cash.register.open',p_branch_id);
  if not exists(select 1 from public.branches where tenant_id=p_tenant_id and id=p_branch_id and status='active') then raise exception 'Active branch required' using errcode='23503'; end if;
  payload:=pg_catalog.jsonb_build_object('branch_id',p_branch_id,'code',code_text,'name',name_text);
  perform pg_catalog.pg_advisory_xact_lock(pg_catalog.hashtextextended('cash-register-request:'||p_tenant_id::text||':'||p_request_id::text,0));
  select * into existing from public.cash_registers where tenant_id=p_tenant_id and request_id=p_request_id;
  if found then
    if existing.request_payload is distinct from payload or existing.created_by_user_id is distinct from actor then raise exception 'Cash register request identifier belongs to a different payload' using errcode='23505'; end if;
    return existing.id;
  end if;
  insert into public.cash_registers(tenant_id,branch_id,code,name,created_by_user_id,request_id,request_payload) values(p_tenant_id,p_branch_id,code_text,name_text,actor,p_request_id,payload) returning id into result;
  perform app_private.write_operational_audit('cash.register_created',p_tenant_id,p_branch_id,result,actor,pg_catalog.jsonb_build_object('code',code_text,'name',name_text));
  return result;
end $f$;

create function public.operational_list_cash_registers(p_tenant_id uuid,p_branch_id uuid,p_limit integer default 50,p_offset integer default 0)
returns table(cash_register_id uuid,code text,name text,status text,created_at timestamptz)
language plpgsql stable security definer set search_path='' set row_security=off as $f$
begin
  perform app_private.assert_operational_permission(p_tenant_id,'transaction.cash.register.read',p_branch_id);
  if p_limit not between 1 and 100 or p_offset<0 then raise exception 'Invalid cash register listing request' using errcode='22023'; end if;
  return query select r.id,r.code,r.name,r.status,r.created_at from public.cash_registers r where r.tenant_id=p_tenant_id and r.branch_id=p_branch_id order by r.code,r.id limit p_limit offset p_offset;
end $f$;

create function public.operational_list_cash_sessions(p_tenant_id uuid,p_branch_id uuid,p_status text default null,p_limit integer default 50,p_offset integer default 0)
returns table(cash_session_id uuid,cash_register_id uuid,cash_register_code text,status text,opening_amount numeric,expected_amount numeric,closing_amount numeric,difference_amount numeric,opened_at timestamptz,closed_at timestamptz)
language plpgsql stable security definer set search_path='' set row_security=off as $f$
begin
  perform app_private.assert_operational_permission(p_tenant_id,'transaction.cash.register.read',p_branch_id);
  if p_limit not between 1 and 100 or p_offset<0 or (p_status is not null and p_status not in ('open','closed')) then raise exception 'Invalid cash session listing request' using errcode='22023'; end if;
  return query select s.id,s.cash_register_id,r.code,s.status,s.opening_amount,s.expected_amount,s.closing_amount,s.difference_amount,s.opened_at,s.closed_at from public.cash_sessions s join public.cash_registers r on r.tenant_id=s.tenant_id and r.id=s.cash_register_id where s.tenant_id=p_tenant_id and s.branch_id=p_branch_id and (p_status is null or s.status=p_status) order by s.opened_at desc,s.id desc limit p_limit offset p_offset;
end $f$;

create function public.operational_list_cash_movements(p_tenant_id uuid,p_branch_id uuid,p_session_id uuid default null,p_limit integer default 50,p_offset integer default 0)
returns table(cash_movement_id uuid,cash_session_id uuid,movement_type text,direction text,amount numeric,reason text,source_obligation_id uuid,created_at timestamptz)
language plpgsql stable security definer set search_path='' set row_security=off as $f$
begin
  perform app_private.assert_operational_permission(p_tenant_id,'transaction.cash.register.read',p_branch_id);
  if p_limit not between 1 and 100 or p_offset<0 or (p_session_id is not null and not exists(select 1 from public.cash_sessions where tenant_id=p_tenant_id and branch_id=p_branch_id and id=p_session_id)) then raise exception 'Invalid cash movement listing request' using errcode='22023'; end if;
  return query select m.id,m.cash_session_id,m.movement_type,m.direction,m.amount,m.reason,m.source_obligation_id,m.created_at from public.cash_movements m where m.tenant_id=p_tenant_id and m.branch_id=p_branch_id and (p_session_id is null or m.cash_session_id=p_session_id) order by m.created_at desc,m.id desc limit p_limit offset p_offset;
end $f$;

alter function public.operational_create_cash_register(uuid,uuid,text,text,uuid) owner to postgres;
alter function public.operational_list_cash_registers(uuid,uuid,integer,integer) owner to postgres;
alter function public.operational_list_cash_sessions(uuid,uuid,text,integer,integer) owner to postgres;
alter function public.operational_list_cash_movements(uuid,uuid,uuid,integer,integer) owner to postgres;
revoke all on function public.operational_create_cash_register(uuid,uuid,text,text,uuid),public.operational_list_cash_registers(uuid,uuid,integer,integer),public.operational_list_cash_sessions(uuid,uuid,text,integer,integer),public.operational_list_cash_movements(uuid,uuid,uuid,integer,integer) from public,anon,authenticated,service_role;
grant execute on function public.operational_create_cash_register(uuid,uuid,text,text,uuid),public.operational_list_cash_registers(uuid,uuid,integer,integer),public.operational_list_cash_sessions(uuid,uuid,text,integer,integer),public.operational_list_cash_movements(uuid,uuid,uuid,integer,integer) to authenticated;
commit;
