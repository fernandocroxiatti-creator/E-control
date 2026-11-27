begin;

-- Financial foundation: obligations and their settlements are immutable,
-- tenant/branch scoped facts.  It deliberately does not create cash, fiscal,
-- bank-conciliation or ledger entries; those require their own contracts.
do $preflight$
begin
  if current_user <> 'postgres' then raise exception 'Apply this migration as postgres'; end if;
  if pg_catalog.to_regclass('public.companies') is null
     or pg_catalog.to_regclass('public.branches') is null
     or pg_catalog.to_regprocedure('app_private.assert_operational_permission(uuid,text,uuid)') is null
     or pg_catalog.to_regprocedure('app_private.write_operational_audit(text,uuid,uuid,uuid,uuid,jsonb)') is null then
    raise exception 'Operational authorization foundation is required';
  end if;
  if pg_catalog.to_regclass('public.financial_obligations') is not null then
    raise exception 'Financial obligations already exist; inspect before applying';
  end if;
end;
$preflight$;

insert into public.permission_definitions(permission_key,description) values
  ('transaction.finance.payable.manage','Transação ZFI01: criar contas a pagar por empresa e filial.'),
  ('transaction.finance.receivable.manage','Transação ZFI02: criar contas a receber por empresa e filial.'),
  ('transaction.finance.settlement.manage','Transação ZFI03: registrar baixa financeira por empresa e filial.'),
  ('transaction.finance.read','Transação ZFI04: consultar contas financeiras por empresa e filial.')
on conflict(permission_key) do nothing;
insert into public.erp_transaction_authorization_catalog(transaction_code,module_code,permission_key) values
  ('ZFI01','FIN','transaction.finance.payable.manage'),
  ('ZFI02','FIN','transaction.finance.receivable.manage'),
  ('ZFI03','FIN','transaction.finance.settlement.manage'),
  ('ZFI04','FIN','transaction.finance.read')
on conflict(transaction_code) do nothing;

create table public.financial_obligations (
  id uuid primary key default pg_catalog.gen_random_uuid(), tenant_id uuid not null references public.companies(id) on delete restrict,
  branch_id uuid not null, obligation_type text not null check(obligation_type in ('payable','receivable')),
  status text not null default 'open' check(status in ('open','partially_settled','settled','cancelled')),
  counterparty_id uuid, description text not null check(pg_catalog.length(description) between 1 and 1000),
  issue_date date not null default current_date, gross_amount numeric(24,8) not null check(gross_amount>0),
  settled_amount numeric(24,8) not null default 0 check(settled_amount>=0 and settled_amount<=gross_amount),
  request_payload jsonb not null check(pg_catalog.jsonb_typeof(request_payload)='object'), request_id uuid not null,
  created_by_user_id uuid not null references auth.users(id) on delete restrict,
  created_at timestamptz not null default pg_catalog.clock_timestamp(), updated_at timestamptz not null default pg_catalog.clock_timestamp(),
  unique(tenant_id,id), unique(tenant_id,request_id),
  foreign key(tenant_id,branch_id) references public.branches(tenant_id,id) on delete restrict,
  foreign key(tenant_id,counterparty_id) references public.business_parties(tenant_id,id) on delete restrict
);
create table public.financial_installments (
  id uuid primary key default pg_catalog.gen_random_uuid(), tenant_id uuid not null, obligation_id uuid not null, installment_number integer not null check(installment_number>0),
  due_date date not null, amount numeric(24,8) not null check(amount>0), settled_amount numeric(24,8) not null default 0 check(settled_amount>=0 and settled_amount<=amount),
  status text not null default 'open' check(status in ('open','partially_settled','settled','cancelled')),
  unique(tenant_id,id), unique(tenant_id,obligation_id,installment_number), foreign key(tenant_id,obligation_id) references public.financial_obligations(tenant_id,id) on delete restrict
);
create table public.financial_settlements (
  id uuid primary key default pg_catalog.gen_random_uuid(), tenant_id uuid not null, branch_id uuid not null, obligation_id uuid not null, installment_id uuid not null,
  settlement_type text not null check(settlement_type in ('payment','receipt')), amount numeric(24,8) not null check(amount>0), settled_on date not null,
  method text not null check(pg_catalog.length(method) between 1 and 80), reference text, request_id uuid not null, request_payload jsonb not null check(pg_catalog.jsonb_typeof(request_payload)='object'),
  created_by_user_id uuid not null references auth.users(id) on delete restrict, created_at timestamptz not null default pg_catalog.clock_timestamp(),
  unique(tenant_id,id), unique(tenant_id,request_id), foreign key(tenant_id,obligation_id) references public.financial_obligations(tenant_id,id) on delete restrict,
  foreign key(tenant_id,installment_id) references public.financial_installments(tenant_id,id) on delete restrict
);
create table public.financial_settlement_reversals (
  id uuid primary key default pg_catalog.gen_random_uuid(), tenant_id uuid not null, branch_id uuid not null,
  obligation_id uuid not null, installment_id uuid not null, settlement_id uuid not null,
  amount numeric(24,8) not null check(amount>0), reason text not null check(pg_catalog.length(reason) between 3 and 1000),
  request_id uuid not null, request_payload jsonb not null check(pg_catalog.jsonb_typeof(request_payload)='object'),
  created_by_user_id uuid not null references auth.users(id) on delete restrict, created_at timestamptz not null default pg_catalog.clock_timestamp(),
  unique(tenant_id,request_id), unique(tenant_id,settlement_id),
  foreign key(tenant_id,obligation_id) references public.financial_obligations(tenant_id,id) on delete restrict,
  foreign key(tenant_id,installment_id) references public.financial_installments(tenant_id,id) on delete restrict,
  foreign key(tenant_id,settlement_id) references public.financial_settlements(tenant_id,id) on delete restrict
);
create table public.financial_events (
  id uuid primary key default pg_catalog.gen_random_uuid(), tenant_id uuid not null, branch_id uuid not null, obligation_id uuid not null,
  event_key text not null check(event_key ~ '^[a-z0-9._-]{3,100}$'), actor_user_id uuid not null references auth.users(id) on delete restrict,
  details jsonb not null default '{}'::jsonb check(pg_catalog.jsonb_typeof(details)='object'), created_at timestamptz not null default pg_catalog.clock_timestamp(),
  foreign key(tenant_id,obligation_id) references public.financial_obligations(tenant_id,id) on delete restrict
);
create index financial_obligations_lookup_idx on public.financial_obligations(tenant_id,branch_id,obligation_type,status,created_at desc);
create index financial_installments_due_idx on public.financial_installments(tenant_id,due_date,status);

alter table public.financial_obligations enable row level security; alter table public.financial_obligations force row level security;
alter table public.financial_installments enable row level security; alter table public.financial_installments force row level security;
alter table public.financial_settlements enable row level security; alter table public.financial_settlements force row level security;
alter table public.financial_settlement_reversals enable row level security; alter table public.financial_settlement_reversals force row level security;
alter table public.financial_events enable row level security; alter table public.financial_events force row level security;
revoke all on table public.financial_obligations,public.financial_installments,public.financial_settlements,public.financial_settlement_reversals,public.financial_events from public,anon,authenticated,service_role;

-- Replace only the central mapping, preserving all previous Phase 1–4 cases.
create or replace function app_private.assert_operational_permission(p_tenant_id uuid,p_permission_key text,p_branch_id uuid default null)
returns uuid language plpgsql stable security definer set search_path='' set row_security=off as $fn$
declare actor_id uuid; required_codes text[]; ready_count integer;
begin
  if coalesce(auth.role(),'')<>'authenticated' or auth.uid() is null then raise exception 'Authenticated session required' using errcode='42501'; end if;
  actor_id:=auth.uid();
  if p_tenant_id is null or p_permission_key is null or not exists(select 1 from public.companies where id=p_tenant_id and status='active') or not app_private.is_active_company_member(p_tenant_id) or (p_branch_id is not null and not app_private.can_access_branch(p_tenant_id,p_branch_id)) or not app_private.has_tenant_permission(p_tenant_id,p_permission_key,p_branch_id) or not exists(select 1 from public.permission_definitions where permission_key=p_permission_key and approval_state='approved') then raise exception 'Operational permission denied' using errcode='42501'; end if;
  required_codes:=case
    when p_permission_key in ('transaction.masterdata.party.read','transaction.masterdata.party.manage') then array['BP01'] when p_permission_key='transaction.masterdata.catalog.read' then array['MM01','SV01'] when p_permission_key='transaction.masterdata.catalog.product.manage' then array['MM01'] when p_permission_key='transaction.masterdata.catalog.service.manage' then array['SV01'] when p_permission_key='transaction.inventory.stock.read' then array['MIGO'] when p_permission_key='transaction.purchasing.purchase_order.read' then array['ME23N'] when p_permission_key='transaction.purchasing.purchase_order.create' then array['ME21N'] when p_permission_key='transaction.masterdata.catalog.product.update' then array['MM02'] when p_permission_key='transaction.masterdata.catalog.product.read' then array['MM03'] when p_permission_key='transaction.inventory.balance.read' then array['MB52'] when p_permission_key='transaction.inventory.history.read' then array['MB51'] when p_permission_key='transaction.inventory.physical.create' then array['MI01'] when p_permission_key='transaction.inventory.physical.count' then array['MI04'] when p_permission_key='transaction.inventory.physical.adjust' then array['MI07'] when p_permission_key='transaction.inventory.transfer' then array['ZTR01'] when p_permission_key='transaction.service_order.create' then array['ZOS01'] when p_permission_key='transaction.service_order.update' then array['ZOS02'] when p_permission_key='transaction.service_order.read' then array['ZOS03'] when p_permission_key='transaction.service_order.close' then array['ZOS04'] when p_permission_key='transaction.purchasing.receipt.manage' then array['ZGR01'] when p_permission_key='transaction.inventory.valuation.initial' then array['ZIV01'] when p_permission_key='transaction.quotation.create' then array['ZQT01'] when p_permission_key='transaction.quotation.manage' then array['ZQT02'] when p_permission_key='transaction.quotation.read' then array['ZQT03'] when p_permission_key='transaction.quotation.approve' then array['ZQT04'] when p_permission_key='transaction.sales.order.create' then array['ZVE01'] when p_permission_key='transaction.sales.order.manage' then array['ZVE02'] when p_permission_key='transaction.sales.order.read' then array['ZVE03'] when p_permission_key='transaction.sales.order.decide' then array['ZVE04'] when p_permission_key='transaction.finance.payable.manage' then array['ZFI01'] when p_permission_key='transaction.finance.receivable.manage' then array['ZFI02'] when p_permission_key='transaction.finance.settlement.manage' then array['ZFI03'] when p_permission_key='transaction.finance.read' then array['ZFI04'] else null end;
  if required_codes is null then raise exception 'Operational permission is not mapped to an approved transaction' using errcode='42501'; end if;
  select count(distinct c.transaction_code) into ready_count from public.erp_transaction_authorization_catalog c join public.permission_definitions p on p.permission_key=c.permission_key and p.approval_state='approved' join public.company_module_availability m on m.tenant_id=p_tenant_id and m.module_code=c.module_code and m.enabled join public.company_transaction_availability t on t.tenant_id=p_tenant_id and t.transaction_code=c.transaction_code and t.enabled where c.transaction_code=any(required_codes) and c.approval_state='approved';
  if ready_count<>cardinality(required_codes) then raise exception 'Operational transaction is not approved or available for this company' using errcode='42501'; end if; return actor_id;
end;$fn$;
alter function app_private.assert_operational_permission(uuid,text,uuid) owner to postgres;
revoke all on function app_private.assert_operational_permission(uuid,text,uuid) from public,anon,authenticated,service_role;

create function public.operational_create_financial_obligation(p_tenant_id uuid,p_branch_id uuid,p_type text,p_counterparty_id uuid,p_description text,p_issue_date date,p_installments jsonb,p_request_id uuid)
returns uuid language plpgsql volatile security definer set search_path='' set row_security=off as $fn$
declare actor uuid; obligation_id uuid; existing public.financial_obligations%rowtype; row jsonb; n integer:=0; due date; amount numeric; total numeric:=0; normalized_description text:=pg_catalog.btrim(coalesce(p_description,'')); payload jsonb;
begin
  if p_tenant_id is null or p_branch_id is null or p_type not in ('payable','receivable') or p_request_id is null or pg_catalog.length(normalized_description) not between 1 and 1000 or p_issue_date is null or pg_catalog.jsonb_typeof(p_installments)<>'array' or pg_catalog.jsonb_array_length(p_installments) not between 1 and 120 then raise exception 'Valid financial obligation data is required' using errcode='22023'; end if;
  actor:=app_private.assert_operational_permission(p_tenant_id,case when p_type='payable' then 'transaction.finance.payable.manage' else 'transaction.finance.receivable.manage' end,p_branch_id);
  if not exists(select 1 from public.branches where tenant_id=p_tenant_id and id=p_branch_id and status='active') or (p_counterparty_id is not null and not exists(select 1 from public.business_parties where tenant_id=p_tenant_id and id=p_counterparty_id and status='active')) then raise exception 'Active branch and optional counterparty are required' using errcode='23503'; end if;
  payload:=pg_catalog.jsonb_build_object('branch_id',p_branch_id,'type',p_type,'counterparty_id',p_counterparty_id,'description',normalized_description,'issue_date',p_issue_date,'installments',p_installments);
  perform pg_catalog.pg_advisory_xact_lock(pg_catalog.hashtextextended('financial-obligation:'||p_tenant_id::text||':'||p_request_id::text,0)); select * into existing from public.financial_obligations where tenant_id=p_tenant_id and request_id=p_request_id;
  if found then if existing.request_payload is distinct from payload or existing.created_by_user_id is distinct from actor then raise exception 'Financial request identifier belongs to a different payload' using errcode='23505'; end if; return existing.id; end if;
  insert into public.financial_obligations(tenant_id,branch_id,obligation_type,counterparty_id,description,issue_date,gross_amount,request_payload,request_id,created_by_user_id) values(p_tenant_id,p_branch_id,p_type,p_counterparty_id,normalized_description,p_issue_date,1,payload,p_request_id,actor) returning id into obligation_id;
  for row in select value from pg_catalog.jsonb_array_elements(p_installments) loop
    n:=n+1; due:=(row->>'due_date')::date; amount:=(row->>'amount')::numeric;
    if due is null or due<p_issue_date or amount is null or amount<=0 or amount<>pg_catalog.round(amount,8) then raise exception 'Invalid installment' using errcode='22023'; end if;
    insert into public.financial_installments(tenant_id,obligation_id,installment_number,due_date,amount) values(p_tenant_id,obligation_id,n,due,amount); total:=total+amount;
  end loop;
  update public.financial_obligations set gross_amount=total where tenant_id=p_tenant_id and id=obligation_id;
  insert into public.financial_events(tenant_id,branch_id,obligation_id,event_key,actor_user_id,details) values(p_tenant_id,p_branch_id,obligation_id,'financial_obligation.created',actor,pg_catalog.jsonb_build_object('type',p_type,'installment_count',n,'gross_amount',total));
  perform app_private.write_operational_audit('financial_obligation.created',p_tenant_id,p_branch_id,obligation_id,actor,pg_catalog.jsonb_build_object('type',p_type,'installment_count',n,'gross_amount',total)); return obligation_id;
end;$fn$;

create function public.operational_settle_financial_installment(p_tenant_id uuid,p_installment_id uuid,p_amount numeric,p_settled_on date,p_method text,p_reference text,p_request_id uuid)
returns uuid language plpgsql volatile security definer set search_path='' set row_security=off as $fn$
declare actor uuid; installment public.financial_installments%rowtype; obligation public.financial_obligations%rowtype; existing public.financial_settlements%rowtype; settlement_id uuid; normalized_method text:=pg_catalog.btrim(coalesce(p_method,'')); normalized_reference text:=nullif(pg_catalog.btrim(coalesce(p_reference,'')), ''); payload jsonb; remaining numeric; new_settled numeric;
begin
  if p_tenant_id is null or p_installment_id is null or p_request_id is null or p_amount is null or p_amount<=0 or p_amount<>pg_catalog.round(p_amount,8) or p_settled_on is null or pg_catalog.length(normalized_method) not between 1 and 80 then raise exception 'Valid settlement data is required' using errcode='22023'; end if;
  select * into installment from public.financial_installments where tenant_id=p_tenant_id and id=p_installment_id; if not found then raise exception 'Installment not found in this company' using errcode='P0002'; end if;
  select * into obligation from public.financial_obligations where tenant_id=p_tenant_id and id=installment.obligation_id for update;
  actor:=app_private.assert_operational_permission(p_tenant_id,'transaction.finance.settlement.manage',obligation.branch_id);
  payload:=pg_catalog.jsonb_build_object('installment_id',p_installment_id,'amount',p_amount,'settled_on',p_settled_on,'method',normalized_method,'reference',normalized_reference);
  perform pg_catalog.pg_advisory_xact_lock(pg_catalog.hashtextextended('financial-settlement:'||p_tenant_id::text||':'||p_request_id::text,0)); select * into existing from public.financial_settlements where tenant_id=p_tenant_id and request_id=p_request_id;
  if found then if existing.request_payload is distinct from payload or existing.created_by_user_id is distinct from actor then raise exception 'Financial request identifier belongs to a different payload' using errcode='23505'; end if; return existing.id; end if;
  select * into installment from public.financial_installments where tenant_id=p_tenant_id and id=p_installment_id for update;
  if obligation.status in ('settled','cancelled') then raise exception 'Obligation cannot be settled' using errcode='55000'; end if; remaining:=installment.amount-installment.settled_amount; if p_amount>remaining then raise exception 'Settlement exceeds installment balance' using errcode='23514'; end if;
  insert into public.financial_settlements(tenant_id,branch_id,obligation_id,installment_id,settlement_type,amount,settled_on,method,reference,request_id,request_payload,created_by_user_id) values(p_tenant_id,obligation.branch_id,obligation.id,installment.id,case when obligation.obligation_type='payable' then 'payment' else 'receipt' end,p_amount,p_settled_on,normalized_method,normalized_reference,p_request_id,payload,actor) returning id into settlement_id;
  new_settled:=installment.settled_amount+p_amount; update public.financial_installments set settled_amount=new_settled,status=case when new_settled=amount then 'settled' else 'partially_settled' end where tenant_id=p_tenant_id and id=installment.id;
  update public.financial_obligations set settled_amount=(select coalesce(sum(settled_amount),0) from public.financial_installments where tenant_id=p_tenant_id and obligation_id=obligation.id),status=case when (select count(*) from public.financial_installments where tenant_id=p_tenant_id and obligation_id=obligation.id and status='settled')=(select count(*) from public.financial_installments where tenant_id=p_tenant_id and obligation_id=obligation.id) then 'settled' else 'partially_settled' end,updated_at=pg_catalog.clock_timestamp() where tenant_id=p_tenant_id and id=obligation.id;
  insert into public.financial_events(tenant_id,branch_id,obligation_id,event_key,actor_user_id,details) values(p_tenant_id,obligation.branch_id,obligation.id,'financial_installment.settled',actor,pg_catalog.jsonb_build_object('installment_id',installment.id,'settlement_id',settlement_id,'amount',p_amount));
  perform app_private.write_operational_audit('financial_installment.settled',p_tenant_id,obligation.branch_id,obligation.id,actor,pg_catalog.jsonb_build_object('installment_id',installment.id,'settlement_id',settlement_id,'amount',p_amount)); return settlement_id;
end;$fn$;

create function public.operational_list_financial_obligations(p_tenant_id uuid,p_branch_id uuid,p_type text default null,p_status text default null,p_limit integer default 50,p_offset integer default 0)
returns table(obligation_id uuid,obligation_type text,status text,description text,gross_amount numeric,settled_amount numeric,open_amount numeric,installments jsonb,created_at timestamptz)
language plpgsql stable security definer set search_path='' set row_security=off as $fn$
begin
  perform app_private.assert_operational_permission(p_tenant_id,'transaction.finance.read',p_branch_id);
  if p_limit not between 1 and 100 or p_offset<0 or (p_type is not null and p_type not in ('payable','receivable')) or (p_status is not null and p_status not in ('open','partially_settled','settled','cancelled')) then raise exception 'Invalid financial listing request' using errcode='22023'; end if;
  return query select o.id,o.obligation_type,o.status,o.description,o.gross_amount,o.settled_amount,o.gross_amount-o.settled_amount,
    coalesce((select pg_catalog.jsonb_agg(pg_catalog.jsonb_build_object('installment_id',i.id,'number',i.installment_number,'due_date',i.due_date,'amount',i.amount,'settled_amount',i.settled_amount,'open_amount',i.amount-i.settled_amount,'status',i.status,'settlements',coalesce((select pg_catalog.jsonb_agg(pg_catalog.jsonb_build_object('settlement_id',s.id,'amount',s.amount,'settled_on',s.settled_on,'method',s.method,'reversed',exists(select 1 from public.financial_settlement_reversals r where r.tenant_id=s.tenant_id and r.settlement_id=s.id)) order by s.created_at) from public.financial_settlements s where s.tenant_id=i.tenant_id and s.installment_id=i.id),'[]'::jsonb)) order by i.installment_number) from public.financial_installments i where i.tenant_id=o.tenant_id and i.obligation_id=o.id),'[]'::jsonb),o.created_at
    from public.financial_obligations o where o.tenant_id=p_tenant_id and o.branch_id=p_branch_id and (p_type is null or o.obligation_type=p_type) and (p_status is null or o.status=p_status) order by o.created_at desc,o.id desc limit p_limit offset p_offset;
end;$fn$;

create function public.operational_reverse_financial_settlement(p_tenant_id uuid,p_settlement_id uuid,p_reason text,p_request_id uuid)
returns uuid language plpgsql volatile security definer set search_path='' set row_security=off as $fn$
declare actor uuid; settlement public.financial_settlements%rowtype; installment public.financial_installments%rowtype; obligation public.financial_obligations%rowtype; existing public.financial_settlement_reversals%rowtype; reversal_id uuid; normalized_reason text:=pg_catalog.btrim(coalesce(p_reason,'')); payload jsonb; restored numeric;
begin
  if p_tenant_id is null or p_settlement_id is null or p_request_id is null or pg_catalog.length(normalized_reason) not between 3 and 1000 then raise exception 'Valid settlement reversal data is required' using errcode='22023'; end if;
  select * into settlement from public.financial_settlements where tenant_id=p_tenant_id and id=p_settlement_id;
  if not found then raise exception 'Settlement not found in this company' using errcode='P0002'; end if;
  select * into obligation from public.financial_obligations where tenant_id=p_tenant_id and id=settlement.obligation_id for update;
  actor:=app_private.assert_operational_permission(p_tenant_id,'transaction.finance.settlement.manage',obligation.branch_id);
  payload:=pg_catalog.jsonb_build_object('settlement_id',p_settlement_id,'reason',normalized_reason);
  perform pg_catalog.pg_advisory_xact_lock(pg_catalog.hashtextextended('financial-settlement-reversal:'||p_tenant_id::text||':'||p_request_id::text,0));
  select * into existing from public.financial_settlement_reversals where tenant_id=p_tenant_id and request_id=p_request_id;
  if found then if existing.request_payload is distinct from payload or existing.created_by_user_id is distinct from actor then raise exception 'Financial reversal request identifier belongs to a different payload' using errcode='23505'; end if; return existing.id; end if;
  if exists(select 1 from public.financial_settlement_reversals where tenant_id=p_tenant_id and settlement_id=p_settlement_id) then raise exception 'Settlement has already been reversed' using errcode='55000'; end if;
  select * into installment from public.financial_installments where tenant_id=p_tenant_id and id=settlement.installment_id for update;
  if installment.settled_amount<settlement.amount then raise exception 'Settlement balance cannot be reversed safely' using errcode='55000'; end if;
  insert into public.financial_settlement_reversals(tenant_id,branch_id,obligation_id,installment_id,settlement_id,amount,reason,request_id,request_payload,created_by_user_id) values(p_tenant_id,obligation.branch_id,obligation.id,installment.id,settlement.id,settlement.amount,normalized_reason,p_request_id,payload,actor) returning id into reversal_id;
  restored:=installment.settled_amount-settlement.amount;
  update public.financial_installments set settled_amount=restored,status=case when restored=0 then 'open' else 'partially_settled' end where tenant_id=p_tenant_id and id=installment.id;
  update public.financial_obligations set settled_amount=(select coalesce(sum(settled_amount),0) from public.financial_installments where tenant_id=p_tenant_id and obligation_id=obligation.id),status=case when (select coalesce(sum(settled_amount),0) from public.financial_installments where tenant_id=p_tenant_id and obligation_id=obligation.id)=0 then 'open' else 'partially_settled' end,updated_at=pg_catalog.clock_timestamp() where tenant_id=p_tenant_id and id=obligation.id;
  insert into public.financial_events(tenant_id,branch_id,obligation_id,event_key,actor_user_id,details) values(p_tenant_id,obligation.branch_id,obligation.id,'financial_settlement.reversed',actor,pg_catalog.jsonb_build_object('settlement_id',settlement.id,'reversal_id',reversal_id,'amount',settlement.amount,'reason',normalized_reason));
  perform app_private.write_operational_audit('financial_settlement.reversed',p_tenant_id,obligation.branch_id,obligation.id,actor,pg_catalog.jsonb_build_object('settlement_id',settlement.id,'reversal_id',reversal_id,'amount',settlement.amount)); return reversal_id;
end;$fn$;

alter function public.operational_create_financial_obligation(uuid,uuid,text,uuid,text,date,jsonb,uuid) owner to postgres;
alter function public.operational_settle_financial_installment(uuid,uuid,numeric,date,text,text,uuid) owner to postgres;
alter function public.operational_list_financial_obligations(uuid,uuid,text,text,integer,integer) owner to postgres;
alter function public.operational_reverse_financial_settlement(uuid,uuid,text,uuid) owner to postgres;
revoke all on function public.operational_create_financial_obligation(uuid,uuid,text,uuid,text,date,jsonb,uuid),public.operational_settle_financial_installment(uuid,uuid,numeric,date,text,text,uuid),public.operational_reverse_financial_settlement(uuid,uuid,text,uuid),public.operational_list_financial_obligations(uuid,uuid,text,text,integer,integer) from public,anon,authenticated,service_role;
grant execute on function public.operational_create_financial_obligation(uuid,uuid,text,uuid,text,date,jsonb,uuid),public.operational_settle_financial_installment(uuid,uuid,numeric,date,text,text,uuid),public.operational_reverse_financial_settlement(uuid,uuid,text,uuid),public.operational_list_financial_obligations(uuid,uuid,text,text,integer,integer) to authenticated;
commit;
