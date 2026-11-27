begin;

-- Cash events never settle a financial obligation or create accounting, fiscal or bank ledger facts.
create function public.operational_open_cash_session(p_tenant_id uuid,p_branch_id uuid,p_register_id uuid,p_opening numeric,p_request_id uuid)
returns uuid language plpgsql volatile security definer set search_path='' set row_security=off as $f$
declare actor uuid; existing public.cash_sessions%rowtype; result uuid; payload jsonb;
begin
  if p_tenant_id is null or p_branch_id is null or p_register_id is null or p_request_id is null or p_opening is null or p_opening<0 or p_opening<>pg_catalog.round(p_opening,8) then raise exception 'Valid cash session opening is required' using errcode='22023'; end if;
  actor:=app_private.assert_operational_permission(p_tenant_id,'transaction.cash.register.open',p_branch_id);
  payload:=pg_catalog.jsonb_build_object('branch_id',p_branch_id,'register_id',p_register_id,'opening_amount',p_opening);
  perform pg_catalog.pg_advisory_xact_lock(pg_catalog.hashtextextended('cash-open-request:'||p_tenant_id::text||':'||p_request_id::text,0));
  select * into existing from public.cash_sessions where tenant_id=p_tenant_id and request_id=p_request_id;
  if found then
    if existing.request_payload is distinct from payload or existing.opened_by_user_id is distinct from actor then raise exception 'Cash opening request identifier belongs to a different payload' using errcode='23505'; end if;
    return existing.id;
  end if;
  if not exists(select 1 from public.cash_registers where id=p_register_id and tenant_id=p_tenant_id and branch_id=p_branch_id and status='active') then raise exception 'Active cash register required' using errcode='23503'; end if;
  perform pg_catalog.pg_advisory_xact_lock(pg_catalog.hashtextextended('cash-register:'||p_tenant_id::text||':'||p_register_id::text,0));
  if exists(select 1 from public.cash_sessions where tenant_id=p_tenant_id and cash_register_id=p_register_id and status='open') then raise exception 'Cash register already has an open session' using errcode='55000'; end if;
  insert into public.cash_sessions(tenant_id,branch_id,cash_register_id,status,opening_amount,opened_by_user_id,request_id,request_payload)
  values(p_tenant_id,p_branch_id,p_register_id,'open',p_opening,actor,p_request_id,payload) returning id into result;
  perform app_private.write_operational_audit('cash.session_opened',p_tenant_id,p_branch_id,result,actor,pg_catalog.jsonb_build_object('opening_amount',p_opening,'cash_register_id',p_register_id));
  return result;
end $f$;

create function public.operational_record_cash_movement(p_tenant_id uuid,p_session_id uuid,p_type text,p_direction text,p_amount numeric,p_reason text,p_request_id uuid,p_obligation_id uuid default null)
returns uuid language plpgsql volatile security definer set search_path='' set row_security=off as $f$
declare actor uuid; session_row public.cash_sessions%rowtype; existing public.cash_movements%rowtype; result uuid; reason_text text:=pg_catalog.btrim(coalesce(p_reason,'')); payload jsonb; obligation public.financial_obligations%rowtype;
begin
  if p_tenant_id is null or p_session_id is null or p_request_id is null or p_amount is null or p_amount<=0 or p_amount<>pg_catalog.round(p_amount,8) or p_type not in ('supply','withdrawal','payment','receipt','adjustment') or p_direction not in ('in','out') or pg_catalog.length(reason_text) not between 3 and 1000 then raise exception 'Valid cash movement data is required' using errcode='22023'; end if;
  if (p_type in ('supply','receipt') and p_direction<>'in') or (p_type in ('withdrawal','payment') and p_direction<>'out') then raise exception 'Cash movement type and direction do not match' using errcode='23514'; end if;
  if p_type='adjustment' and pg_catalog.length(reason_text)<10 then raise exception 'Cash adjustment requires a detailed reason' using errcode='22023'; end if;
  select * into session_row from public.cash_sessions where tenant_id=p_tenant_id and id=p_session_id;
  if not found then raise exception 'Cash session not found in this company' using errcode='P0002'; end if;
  actor:=app_private.assert_operational_permission(p_tenant_id,'transaction.cash.register.move',session_row.branch_id);
  if p_obligation_id is not null then
    select * into obligation from public.financial_obligations where tenant_id=p_tenant_id and id=p_obligation_id;
    if not found or obligation.branch_id<>session_row.branch_id then raise exception 'Financial obligation is not in this cash session company and branch' using errcode='23503'; end if;
    if (obligation.obligation_type='receivable' and not (p_type='receipt' and p_direction='in')) or (obligation.obligation_type='payable' and not (p_type='payment' and p_direction='out')) then raise exception 'Cash movement does not match financial obligation type' using errcode='23514'; end if;
  elsif p_type in ('payment','receipt') then raise exception 'Payment or receipt requires an in-scope financial obligation' using errcode='23503'; end if;
  payload:=pg_catalog.jsonb_build_object('session_id',p_session_id,'movement_type',p_type,'direction',p_direction,'amount',p_amount,'reason',reason_text,'obligation_id',p_obligation_id);
  perform pg_catalog.pg_advisory_xact_lock(pg_catalog.hashtextextended('cash-movement-request:'||p_tenant_id::text||':'||p_request_id::text,0));
  select * into existing from public.cash_movements where tenant_id=p_tenant_id and request_id=p_request_id;
  if found then
    if existing.request_payload is distinct from payload or existing.actor_user_id is distinct from actor then raise exception 'Cash movement request identifier belongs to a different payload' using errcode='23505'; end if;
    return existing.id;
  end if;
  perform pg_catalog.pg_advisory_xact_lock(pg_catalog.hashtextextended('cash-session:'||p_tenant_id::text||':'||p_session_id::text,0));
  select * into session_row from public.cash_sessions where tenant_id=p_tenant_id and id=p_session_id for update;
  if session_row.status<>'open' then raise exception 'Cash session is closed' using errcode='55000'; end if;
  insert into public.cash_movements(tenant_id,branch_id,cash_session_id,movement_type,direction,amount,reason,source_obligation_id,actor_user_id,request_id,request_payload)
  values(p_tenant_id,session_row.branch_id,p_session_id,p_type,p_direction,p_amount,reason_text,p_obligation_id,actor,p_request_id,payload) returning id into result;
  perform app_private.write_operational_audit('cash.movement_recorded',p_tenant_id,session_row.branch_id,result,actor,pg_catalog.jsonb_build_object('cash_session_id',p_session_id,'movement_type',p_type,'direction',p_direction,'amount',p_amount,'source_obligation_id',p_obligation_id));
  return result;
end $f$;

create function public.operational_close_cash_session(p_tenant_id uuid,p_session_id uuid,p_counted numeric,p_request_id uuid)
returns text language plpgsql volatile security definer set search_path='' set row_security=off as $f$
declare actor uuid; session_row public.cash_sessions%rowtype; expected numeric; payload jsonb;
begin
  if p_tenant_id is null or p_session_id is null or p_request_id is null or p_counted is null or p_counted<0 or p_counted<>pg_catalog.round(p_counted,8) then raise exception 'Valid cash closing amount is required' using errcode='22023'; end if;
  select * into session_row from public.cash_sessions where tenant_id=p_tenant_id and id=p_session_id;
  if not found then raise exception 'Cash session not found in this company' using errcode='P0002'; end if;
  actor:=app_private.assert_operational_permission(p_tenant_id,'transaction.cash.register.close',session_row.branch_id);
  payload:=pg_catalog.jsonb_build_object('session_id',p_session_id,'counted_amount',p_counted);
  perform pg_catalog.pg_advisory_xact_lock(pg_catalog.hashtextextended('cash-close-request:'||p_tenant_id::text||':'||p_request_id::text,0));
  perform pg_catalog.pg_advisory_xact_lock(pg_catalog.hashtextextended('cash-session:'||p_tenant_id::text||':'||p_session_id::text,0));
  select * into session_row from public.cash_sessions where tenant_id=p_tenant_id and id=p_session_id for update;
  if session_row.status='closed' then
    if session_row.close_request_id=p_request_id and session_row.close_request_payload is not distinct from payload and session_row.closed_by_user_id is not distinct from actor then return 'closed'; end if;
    raise exception 'Cash session already closed' using errcode='55000';
  end if;
  select session_row.opening_amount+coalesce(sum(case when direction='in' then amount else -amount end),0) into expected from public.cash_movements where tenant_id=p_tenant_id and cash_session_id=session_row.id;
  update public.cash_sessions set status='closed',expected_amount=expected,closing_amount=p_counted,difference_amount=p_counted-expected,closed_by_user_id=actor,closed_at=pg_catalog.clock_timestamp(),close_request_id=p_request_id,close_request_payload=payload where tenant_id=p_tenant_id and id=session_row.id;
  perform app_private.write_operational_audit('cash.session_closed',p_tenant_id,session_row.branch_id,session_row.id,actor,pg_catalog.jsonb_build_object('expected_amount',expected,'counted_amount',p_counted,'difference_amount',p_counted-expected));
  return 'closed';
end $f$;

alter function public.operational_open_cash_session(uuid,uuid,uuid,numeric,uuid) owner to postgres;
alter function public.operational_record_cash_movement(uuid,uuid,text,text,numeric,text,uuid,uuid) owner to postgres;
alter function public.operational_close_cash_session(uuid,uuid,numeric,uuid) owner to postgres;
revoke all on function public.operational_open_cash_session(uuid,uuid,uuid,numeric,uuid),public.operational_record_cash_movement(uuid,uuid,text,text,numeric,text,uuid,uuid),public.operational_close_cash_session(uuid,uuid,numeric,uuid) from public,anon,authenticated,service_role;
grant execute on function public.operational_open_cash_session(uuid,uuid,uuid,numeric,uuid),public.operational_record_cash_movement(uuid,uuid,text,text,numeric,text,uuid,uuid),public.operational_close_cash_session(uuid,uuid,numeric,uuid) to authenticated;
commit;
