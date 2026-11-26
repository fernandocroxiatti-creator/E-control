begin;

-- Commercial billing is an auditable source-status contract. It deliberately
-- does not issue fiscal documents or create receivables, cash or tax facts.
do $preflight$
begin
  if current_user <> 'postgres' then raise exception 'Apply this migration as postgres'; end if;
  if pg_catalog.to_regclass('public.sales_orders') is null
     or pg_catalog.to_regclass('public.work_orders') is null
     or pg_catalog.to_regprocedure('app_private.has_tenant_permission(uuid,text,uuid)') is null
     or pg_catalog.to_regprocedure('app_private.write_operational_audit(text,uuid,uuid,uuid,uuid,jsonb)') is null then
    raise exception 'Sales, work-order and authorization foundations are required';
  end if;
  if pg_catalog.to_regclass('public.commercial_billing_documents') is not null then raise exception 'Commercial billing foundation already exists'; end if;
end;
$preflight$;

insert into public.permission_definitions(permission_key,description) values
 ('transaction.billing.issue','Transação ZFB01: emitir faturamento comercial por empresa e filial.'),
 ('transaction.billing.read','Transação ZFB02: consultar faturamento comercial por empresa e filial.'),
 ('transaction.billing.cancel','Transação ZFB03: cancelar faturamento comercial por empresa e filial.')
on conflict(permission_key) do nothing;
insert into public.erp_transaction_authorization_catalog(transaction_code,module_code,permission_key) values
 ('ZFB01','FIN','transaction.billing.issue'),('ZFB02','FIN','transaction.billing.read'),('ZFB03','FIN','transaction.billing.cancel')
on conflict(transaction_code) do nothing;

create sequence public.commercial_billing_number_seq;
alter sequence public.commercial_billing_number_seq owner to postgres;
revoke all on sequence public.commercial_billing_number_seq from public,anon,authenticated,service_role;

create table public.commercial_billing_documents (
 id uuid primary key default pg_catalog.gen_random_uuid(), tenant_id uuid not null references public.companies(id) on delete restrict,
 branch_id uuid not null, billing_number bigint not null default nextval('public.commercial_billing_number_seq'),
 source_type text not null check(source_type in ('sales_order','work_order')), source_id uuid not null,
 customer_id uuid not null, status text not null default 'issued' check(status in ('issued','cancelled')),
 source_number bigint not null, total_amount numeric(24,8) not null check(total_amount >= 0),
 request_payload jsonb not null check(pg_catalog.jsonb_typeof(request_payload)='object'), request_id uuid not null,
 issued_by_user_id uuid not null references auth.users(id) on delete restrict, issued_at timestamptz not null default pg_catalog.clock_timestamp(),
 cancelled_by_user_id uuid references auth.users(id) on delete restrict, cancelled_at timestamptz, cancellation_reason text,
 created_at timestamptz not null default pg_catalog.clock_timestamp(),
 unique(tenant_id,id), unique(tenant_id,billing_number), unique(tenant_id,request_id), unique(tenant_id,source_type,source_id),
 foreign key(tenant_id,branch_id) references public.branches(tenant_id,id) on delete restrict,
 foreign key(tenant_id,customer_id) references public.business_parties(tenant_id,id) on delete restrict,
 check((status='issued' and cancelled_at is null and cancelled_by_user_id is null and cancellation_reason is null) or (status='cancelled' and cancelled_at is not null and cancelled_by_user_id is not null and pg_catalog.length(cancellation_reason) between 3 and 1000))
);
create table public.commercial_billing_events (
 id uuid primary key default pg_catalog.gen_random_uuid(), tenant_id uuid not null, branch_id uuid not null, billing_document_id uuid not null,
 event_key text not null check(event_key ~ '^[a-z0-9._-]{3,100}$'), actor_user_id uuid not null references auth.users(id) on delete restrict,
 details jsonb not null default '{}'::jsonb check(pg_catalog.jsonb_typeof(details)='object'), created_at timestamptz not null default pg_catalog.clock_timestamp(),
 foreign key(tenant_id,billing_document_id) references public.commercial_billing_documents(tenant_id,id) on delete restrict,
 foreign key(tenant_id,branch_id) references public.branches(tenant_id,id) on delete restrict
);
-- A separate cancellation ledger distinguishes a safe replay from a second,
-- divergent cancellation request.
create table public.commercial_billing_cancellation_requests (
 id uuid primary key default pg_catalog.gen_random_uuid(), tenant_id uuid not null references public.companies(id) on delete restrict,
 billing_document_id uuid not null, request_id uuid not null,
 request_payload jsonb not null check(pg_catalog.jsonb_typeof(request_payload)='object'),
 actor_user_id uuid not null references auth.users(id) on delete restrict, created_at timestamptz not null default pg_catalog.clock_timestamp(),
 unique(tenant_id,request_id), unique(tenant_id,billing_document_id),
 foreign key(tenant_id,billing_document_id) references public.commercial_billing_documents(tenant_id,id) on delete restrict
);
create index commercial_billing_branch_idx on public.commercial_billing_documents(tenant_id,branch_id,status,created_at desc);
alter table public.commercial_billing_documents enable row level security; alter table public.commercial_billing_documents force row level security;
alter table public.commercial_billing_events enable row level security; alter table public.commercial_billing_events force row level security;
alter table public.commercial_billing_cancellation_requests enable row level security; alter table public.commercial_billing_cancellation_requests force row level security;
revoke all on table public.commercial_billing_documents,public.commercial_billing_events,public.commercial_billing_cancellation_requests from public,anon,authenticated,service_role;

create function app_private.assert_commercial_billing_permission(p_tenant_id uuid,p_permission_key text,p_branch_id uuid)
returns uuid language plpgsql stable security definer set search_path='' set row_security=off as $fn$
declare actor uuid; code text;
begin
 if coalesce(auth.role(),'')<>'authenticated' or auth.uid() is null or p_tenant_id is null or p_branch_id is null then raise exception 'Authenticated billing session required' using errcode='42501'; end if;
 actor:=auth.uid();
 code:=case p_permission_key when 'transaction.billing.issue' then 'ZFB01' when 'transaction.billing.read' then 'ZFB02' when 'transaction.billing.cancel' then 'ZFB03' else null end;
 if code is null or not exists(select 1 from public.companies where id=p_tenant_id and status='active') or not app_private.is_active_company_member(p_tenant_id) or not app_private.can_access_branch(p_tenant_id,p_branch_id) or not app_private.has_tenant_permission(p_tenant_id,p_permission_key,p_branch_id) or not exists(select 1 from public.permission_definitions where permission_key=p_permission_key and approval_state='approved') or not exists(select 1 from public.erp_transaction_authorization_catalog c join public.company_module_availability m on m.tenant_id=p_tenant_id and m.module_code=c.module_code and m.enabled join public.company_transaction_availability t on t.tenant_id=p_tenant_id and t.transaction_code=c.transaction_code and t.enabled where c.transaction_code=code and c.approval_state='approved') then raise exception 'Commercial billing permission denied' using errcode='42501'; end if;
 return actor;
end;$fn$;

-- Replaces the deliberate Phase 2 fail-closed guard only with a persisted,
-- tenant-scoped commercial billing status. Cancellation makes reversal eligible.
create or replace function app_private.assert_work_order_not_billed(p_tenant_id uuid,p_work_order_id uuid)
returns void language plpgsql stable security definer set search_path='' set row_security=off as $fn$
begin
 if p_tenant_id is null or p_work_order_id is null then raise exception 'Work order billing context is required' using errcode='22023'; end if;
 if exists(select 1 from public.commercial_billing_documents d where d.tenant_id=p_tenant_id and d.source_type='work_order' and d.source_id=p_work_order_id and d.status='issued') then raise exception 'Direct-purchase reversal is blocked because the work order has active commercial billing' using errcode='55000'; end if;
end;$fn$;

create function public.operational_issue_commercial_billing(p_tenant_id uuid,p_source_type text,p_source_id uuid,p_request_id uuid)
returns uuid language plpgsql volatile security definer set search_path='' set row_security=off as $fn$
declare actor uuid; branch uuid; customer uuid; source_number bigint; source_total numeric; source_status text; document_id uuid; existing public.commercial_billing_documents%rowtype; payload jsonb;
begin
 if p_tenant_id is null or p_source_type not in ('sales_order','work_order') or p_source_id is null or p_request_id is null then raise exception 'Valid billing source is required' using errcode='22023'; end if;
 if p_source_type='sales_order' then select branch_id,customer_id,sales_order_number,total_amount,status into branch,customer,source_number,source_total,source_status from public.sales_orders where tenant_id=p_tenant_id and id=p_source_id for update; else select branch_id,customer_id,order_number,total_amount,status into branch,customer,source_number,source_total,source_status from public.work_orders where tenant_id=p_tenant_id and id=p_source_id for update; end if;
 if not found then raise exception 'Billing source not found in this company' using errcode='P0002'; end if;
 actor:=app_private.assert_commercial_billing_permission(p_tenant_id,'transaction.billing.issue',branch);
 perform pg_catalog.pg_advisory_xact_lock(pg_catalog.hashtextextended('commercial-billing:'||p_tenant_id::text||':'||p_request_id::text,0));
 payload:=pg_catalog.jsonb_build_object('source_type',p_source_type,'source_id',p_source_id);
 select * into existing from public.commercial_billing_documents where tenant_id=p_tenant_id and request_id=p_request_id;
 if found then if existing.request_payload is distinct from payload or existing.issued_by_user_id is distinct from actor then raise exception 'Billing request identifier belongs to a different payload' using errcode='23505'; end if; return existing.id; end if;
 if (p_source_type='sales_order' and source_status<>'confirmed') or (p_source_type='work_order' and source_status<>'closed') then raise exception 'Only confirmed sales orders or closed work orders may be billed' using errcode='55000'; end if;
 if exists(select 1 from public.commercial_billing_documents where tenant_id=p_tenant_id and source_type=p_source_type and source_id=p_source_id) then raise exception 'Source has already been billed; use the immutable cancellation process' using errcode='23505'; end if;
 insert into public.commercial_billing_documents(tenant_id,branch_id,source_type,source_id,customer_id,source_number,total_amount,request_payload,request_id,issued_by_user_id) values(p_tenant_id,branch,p_source_type,p_source_id,customer,source_number,source_total,payload,p_request_id,actor) returning id into document_id;
 insert into public.commercial_billing_events(tenant_id,branch_id,billing_document_id,event_key,actor_user_id,details) values(p_tenant_id,branch,document_id,'commercial_billing.issued',actor,pg_catalog.jsonb_build_object('source_type',p_source_type,'source_id',p_source_id,'total_amount',source_total));
 perform app_private.write_operational_audit('commercial_billing.issued',p_tenant_id,branch,document_id,actor,pg_catalog.jsonb_build_object('source_type',p_source_type,'source_id',p_source_id,'total_amount',source_total));
 return document_id;
end;$fn$;

create function public.operational_cancel_commercial_billing(p_tenant_id uuid,p_billing_document_id uuid,p_reason text,p_request_id uuid)
returns text language plpgsql volatile security definer set search_path='' set row_security=off as $fn$
declare actor uuid; document public.commercial_billing_documents%rowtype; existing public.commercial_billing_cancellation_requests%rowtype; normalized_reason text:=nullif(pg_catalog.btrim(coalesce(p_reason,'')), ''); payload jsonb;
begin
 if p_tenant_id is null or p_billing_document_id is null or p_request_id is null or pg_catalog.length(normalized_reason) not between 3 and 1000 then raise exception 'Billing cancellation reason is required' using errcode='22023'; end if;
 select * into document from public.commercial_billing_documents where tenant_id=p_tenant_id and id=p_billing_document_id for update; if not found then raise exception 'Billing document not found in this company' using errcode='P0002'; end if;
 actor:=app_private.assert_commercial_billing_permission(p_tenant_id,'transaction.billing.cancel',document.branch_id);
 payload:=pg_catalog.jsonb_build_object('billing_document_id',p_billing_document_id,'reason',normalized_reason);
 perform pg_catalog.pg_advisory_xact_lock(pg_catalog.hashtextextended('commercial-billing-cancel:'||p_tenant_id::text||':'||p_request_id::text,0));
 select * into existing from public.commercial_billing_cancellation_requests where tenant_id=p_tenant_id and request_id=p_request_id;
 if found then
   if existing.request_payload is distinct from payload or existing.actor_user_id is distinct from actor then raise exception 'Billing cancellation request identifier belongs to a different payload' using errcode='23505'; end if;
   return 'cancelled';
 end if;
 if document.status<>'issued' then raise exception 'Only issued billing documents may be cancelled' using errcode='55000'; end if;
 update public.commercial_billing_documents set status='cancelled',cancelled_by_user_id=actor,cancelled_at=pg_catalog.clock_timestamp(),cancellation_reason=normalized_reason where tenant_id=p_tenant_id and id=p_billing_document_id;
 insert into public.commercial_billing_cancellation_requests(tenant_id,billing_document_id,request_id,request_payload,actor_user_id) values(p_tenant_id,p_billing_document_id,p_request_id,payload,actor);
 insert into public.commercial_billing_events(tenant_id,branch_id,billing_document_id,event_key,actor_user_id,details) values(p_tenant_id,document.branch_id,p_billing_document_id,'commercial_billing.cancelled',actor,pg_catalog.jsonb_build_object('reason',normalized_reason,'request_id',p_request_id));
 perform app_private.write_operational_audit('commercial_billing.cancelled',p_tenant_id,document.branch_id,p_billing_document_id,actor,pg_catalog.jsonb_build_object('reason',normalized_reason));
 return 'cancelled';
end;$fn$;

-- This overrides only the Phase 2 state gate: reversal after closure is safe
-- solely if the persisted guard above sees no active billing. All original
-- locking, request idempotency, totals and audit behavior is retained.
create or replace function public.operational_reverse_work_order_direct_purchase(
  p_tenant_id uuid,p_work_order_id uuid,p_direct_purchase_id uuid,p_reason text,p_request_id uuid
) returns uuid language plpgsql volatile security definer set search_path='' set row_security=off as $fn$
declare actor uuid; branch uuid; work_order_status text; purchase public.work_order_direct_purchases%rowtype; existing public.work_order_direct_purchase_reversals%rowtype; normalized_reason text:=nullif(pg_catalog.btrim(coalesce(p_reason,'')), ''); normalized_payload jsonb; reversal_id uuid;
begin
 if p_tenant_id is null or p_work_order_id is null or p_direct_purchase_id is null or p_request_id is null or (normalized_reason is not null and pg_catalog.length(normalized_reason)>1000) then raise exception 'Valid direct-purchase reversal identifiers and optional reason are required' using errcode='22023'; end if;
 select branch_id,status into branch,work_order_status from public.work_orders where tenant_id=p_tenant_id and id=p_work_order_id for update;
 if not found then raise exception 'Work order in this company is required' using errcode='P0002'; end if;
 actor:=app_private.assert_operational_permission(p_tenant_id,'transaction.service_order.update',branch);
 if work_order_status not in ('open','closed') then raise exception 'Direct purchases may be reversed only while the work order is open or closed' using errcode='55000'; end if;
 select * into purchase from public.work_order_direct_purchases where tenant_id=p_tenant_id and id=p_direct_purchase_id and work_order_id=p_work_order_id for update;
 if not found then raise exception 'Direct purchase does not belong to this work order in this company' using errcode='P0002'; end if;
 if purchase.branch_id<>branch then raise exception 'Direct purchase branch does not match the work order' using errcode='23503'; end if;
 normalized_payload:=pg_catalog.jsonb_build_object('work_order_id',p_work_order_id,'direct_purchase_id',p_direct_purchase_id,'reason',normalized_reason);
 perform pg_catalog.pg_advisory_xact_lock(pg_catalog.hashtextextended('work-order-direct-purchase-reversal:'||p_tenant_id::text||':'||p_request_id::text,0));
 select * into existing from public.work_order_direct_purchase_reversals where tenant_id=p_tenant_id and request_id=p_request_id;
 if found then if existing.request_payload is distinct from normalized_payload or existing.created_by_user_id is distinct from actor then raise exception 'Direct-purchase reversal request identifier belongs to a different payload' using errcode='23505'; end if; return existing.id; end if;
 perform app_private.assert_work_order_not_billed(p_tenant_id,p_work_order_id);
 if exists(select 1 from public.work_order_direct_purchase_reversals where tenant_id=p_tenant_id and direct_purchase_id=p_direct_purchase_id) then raise exception 'This direct purchase has already been reversed' using errcode='23505'; end if;
 if (select direct_purchase_total from public.work_orders where tenant_id=p_tenant_id and id=p_work_order_id)<purchase.total_cost then raise exception 'Direct-purchase total cannot be compensated below zero' using errcode='23514'; end if;
 insert into public.work_order_direct_purchase_reversals(tenant_id,branch_id,work_order_id,direct_purchase_id,reversed_quantity,reversed_total_cost,reason,request_payload,request_id,created_by_user_id) values(p_tenant_id,branch,p_work_order_id,p_direct_purchase_id,purchase.quantity,purchase.total_cost,normalized_reason,normalized_payload,p_request_id,actor) returning id into reversal_id;
 update public.work_orders set direct_purchase_total=direct_purchase_total-purchase.total_cost,updated_at=pg_catalog.clock_timestamp() where tenant_id=p_tenant_id and id=p_work_order_id;
 insert into public.work_order_events(tenant_id,work_order_id,event_key,actor_user_id,details) values(p_tenant_id,p_work_order_id,'work_order.direct_purchase.reversed',actor,pg_catalog.jsonb_build_object('direct_purchase_id',p_direct_purchase_id,'direct_purchase_reversal_id',reversal_id,'quantity',purchase.quantity,'total_cost',purchase.total_cost,'reason',normalized_reason));
 perform app_private.write_operational_audit('work_order.direct_purchase.reversed',p_tenant_id,branch,reversal_id,actor,pg_catalog.jsonb_build_object('work_order_id',p_work_order_id,'direct_purchase_id',p_direct_purchase_id,'quantity',purchase.quantity,'total_cost',purchase.total_cost,'reason',normalized_reason));
 return reversal_id;
end;$fn$;

create function public.operational_list_commercial_billing(p_tenant_id uuid,p_branch_id uuid,p_status text default null,p_limit integer default 50,p_offset integer default 0)
returns table(billing_document_id uuid,billing_number bigint,source_type text,source_id uuid,source_number bigint,customer_name text,status text,total_amount numeric,issued_at timestamptz,cancelled_at timestamptz)
language plpgsql stable security definer set search_path='' set row_security=off as $fn$
begin
 perform app_private.assert_commercial_billing_permission(p_tenant_id,'transaction.billing.read',p_branch_id);
 if p_limit not between 1 and 100 or p_offset<0 or (p_status is not null and p_status not in ('issued','cancelled')) then raise exception 'Invalid billing list request' using errcode='22023'; end if;
 return query select d.id,d.billing_number,d.source_type,d.source_id,d.source_number,p.legal_name,d.status,d.total_amount,d.issued_at,d.cancelled_at from public.commercial_billing_documents d join public.business_parties p on p.tenant_id=d.tenant_id and p.id=d.customer_id where d.tenant_id=p_tenant_id and d.branch_id=p_branch_id and (p_status is null or d.status=p_status) order by d.issued_at desc,d.id desc limit p_limit offset p_offset;
end;$fn$;

alter function app_private.assert_commercial_billing_permission(uuid,text,uuid) owner to postgres;
alter function app_private.assert_work_order_not_billed(uuid,uuid) owner to postgres;
alter function public.operational_issue_commercial_billing(uuid,text,uuid,uuid) owner to postgres;
alter function public.operational_cancel_commercial_billing(uuid,uuid,text,uuid) owner to postgres;
alter function public.operational_list_commercial_billing(uuid,uuid,text,integer,integer) owner to postgres;
alter function public.operational_reverse_work_order_direct_purchase(uuid,uuid,uuid,text,uuid) owner to postgres;
revoke all on function app_private.assert_commercial_billing_permission(uuid,text,uuid),app_private.assert_work_order_not_billed(uuid,uuid),public.operational_issue_commercial_billing(uuid,text,uuid,uuid),public.operational_cancel_commercial_billing(uuid,uuid,text,uuid),public.operational_list_commercial_billing(uuid,uuid,text,integer,integer),public.operational_reverse_work_order_direct_purchase(uuid,uuid,uuid,text,uuid) from public,anon,authenticated,service_role;
grant execute on function public.operational_issue_commercial_billing(uuid,text,uuid,uuid),public.operational_cancel_commercial_billing(uuid,uuid,text,uuid),public.operational_list_commercial_billing(uuid,uuid,text,integer,integer) to authenticated;
commit;
