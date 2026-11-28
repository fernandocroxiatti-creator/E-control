begin;

-- Explicit linkage only. No historical billing or obligation is backfilled.
insert into public.permission_definitions(permission_key,description,approval_state)
values('transaction.billing.finance.link','ZFB04: integrar faturamento e recebível por empresa e filial.','pending') on conflict do nothing;
insert into public.erp_transaction_authorization_catalog(transaction_code,module_code,permission_key,approval_state)
values('ZFB04','FIN','transaction.billing.finance.link','pending') on conflict do nothing;

create table public.billing_financial_links(
 tenant_id uuid not null, branch_id uuid not null, billing_document_id uuid not null, obligation_id uuid not null,
 link_mode text not null check(link_mode in ('generated','existing')), payment_terms text not null check(length(btrim(payment_terms)) between 3 and 500),
 request_id uuid not null, request_payload jsonb not null, actor_user_id uuid not null references auth.users(id), created_at timestamptz not null default clock_timestamp(),
 primary key(tenant_id,billing_document_id),unique(tenant_id,obligation_id),unique(tenant_id,request_id),
 foreign key(tenant_id,branch_id) references public.branches(tenant_id,id),
 foreign key(tenant_id,billing_document_id) references public.commercial_billing_documents(tenant_id,id),
 foreign key(tenant_id,obligation_id) references public.financial_obligations(tenant_id,id));
alter table public.billing_financial_links enable row level security;
alter table public.billing_financial_links force row level security;
revoke all on table public.billing_financial_links from public,anon,authenticated,service_role;

create function public.operational_integrate_billing_receivable(
 p_tenant_id uuid,p_billing_document_id uuid,p_issue_date date,p_payment_terms text,p_installments jsonb,p_request_id uuid,p_existing_obligation_id uuid default null
) returns uuid language plpgsql security definer set search_path='' set row_security=off as $f$
declare actor uuid; doc public.commercial_billing_documents%rowtype; obligation public.financial_obligations%rowtype; existing public.billing_financial_links%rowtype;
 normalized jsonb:='[]'::jsonb; row jsonb; due date; amount numeric; total numeric:=0; result uuid; payload jsonb; prior_due date;
begin
 if p_tenant_id is null or p_billing_document_id is null or p_issue_date is null or p_request_id is null or length(btrim(coalesce(p_payment_terms,''))) not between 3 and 500 then raise exception 'Valid billing, issue date and payment terms required' using errcode='22023'; end if;
 select * into doc from public.commercial_billing_documents where tenant_id=p_tenant_id and id=p_billing_document_id for update;
 if not found then raise exception 'Billing not found in company' using errcode='P0002'; end if;
 actor:=app_private.assert_operational_permission(p_tenant_id,'transaction.finance.receivable.manage',doc.branch_id);
 perform app_private.assert_commercial_billing_permission(p_tenant_id,'transaction.billing.read',doc.branch_id);
 if not app_private.has_tenant_permission(p_tenant_id,'transaction.billing.finance.link',doc.branch_id) or not exists(
 select 1 from public.erp_transaction_authorization_catalog c join public.permission_definitions p on p.permission_key=c.permission_key and p.approval_state='approved'
 join public.company_module_availability m on m.tenant_id=p_tenant_id and m.module_code=c.module_code and m.enabled
 join public.company_transaction_availability a on a.tenant_id=p_tenant_id and a.transaction_code=c.transaction_code and a.enabled
 where c.transaction_code='ZFB04' and c.approval_state='approved') then raise exception 'Billing integration permission denied' using errcode='42501'; end if;
 if p_existing_obligation_id is null then
   if p_installments is null or jsonb_typeof(p_installments)<>'array' or jsonb_array_length(p_installments) not between 1 and 120 then raise exception 'Provide 1 to 120 installments' using errcode='22023'; end if;
   for row in select value from jsonb_array_elements(p_installments) loop
     if jsonb_typeof(row)<>'object' or coalesce(row->>'amount','') !~ '^[0-9]{1,15}(\.[0-9]{1,8})?$' or coalesce(row->>'due_date','') !~ '^[0-9]{4}-[0-9]{2}-[0-9]{2}$' then raise exception 'Invalid installment data' using errcode='22023'; end if;
     due:=(row->>'due_date')::date; amount:=(row->>'amount')::numeric;
     if due<p_issue_date or (prior_due is not null and due<prior_due) or amount<=0 then raise exception 'Installments must be positive and chronologically ordered after issue date' using errcode='22023'; end if;
     total:=total+amount; prior_due:=due; normalized:=normalized||jsonb_build_array(jsonb_build_object('due_date',due,'amount',amount));
   end loop;
   if total is distinct from doc.total_amount or total<=0 then raise exception 'Installments must match billing total' using errcode='23514'; end if;
 elsif p_installments is distinct from '[]'::jsonb then raise exception 'Existing obligation retains its own installments' using errcode='22023'; end if;
 payload:=jsonb_build_object('billing_document_id',p_billing_document_id,'issue_date',p_issue_date,'payment_terms',btrim(p_payment_terms),'installments',normalized,'existing_obligation_id',p_existing_obligation_id);
 perform pg_advisory_xact_lock(hashtextextended('billing-finance:'||p_tenant_id::text||':'||p_request_id::text,0));
 select * into existing from public.billing_financial_links where tenant_id=p_tenant_id and request_id=p_request_id;
 if found then
   if existing.request_payload is distinct from payload or existing.actor_user_id is distinct from actor then raise exception 'Integration request belongs to another payload' using errcode='23505'; end if; return existing.obligation_id;
 end if;
 if doc.status<>'issued' then raise exception 'Cancelled billing cannot create or link a receivable' using errcode='55000'; end if;
 if exists(select 1 from public.billing_financial_links where tenant_id=p_tenant_id and billing_document_id=doc.id) then raise exception 'Billing already linked to a receivable' using errcode='23505'; end if;
 if p_existing_obligation_id is not null then
   select * into obligation from public.financial_obligations where tenant_id=p_tenant_id and id=p_existing_obligation_id for update;
   if not found or obligation.branch_id<>doc.branch_id or obligation.counterparty_id is distinct from doc.customer_id or obligation.obligation_type<>'receivable' or obligation.gross_amount<>doc.total_amount or obligation.issue_date<>p_issue_date or obligation.status='cancelled' then raise exception 'Existing obligation must match company, branch, customer, amount and issue date' using errcode='23514'; end if;
   result:=obligation.id;
 else
   -- No guess about existing manual receivables: require explicit review/linking.
   if exists(select 1 from public.financial_obligations o where o.tenant_id=p_tenant_id and o.branch_id=doc.branch_id and o.counterparty_id=doc.customer_id and o.obligation_type='receivable' and o.status<>'cancelled' and o.gross_amount=doc.total_amount and o.issue_date=p_issue_date and not exists(select 1 from public.billing_financial_links l where l.tenant_id=o.tenant_id and l.obligation_id=o.id)) then raise exception 'Matching existing obligation found; review and link explicitly' using errcode='23505'; end if;
   result:=public.operational_create_financial_obligation(p_tenant_id,doc.branch_id,'receivable',doc.customer_id,'Faturamento comercial #'||doc.billing_number,p_issue_date,normalized,gen_random_uuid());
   perform public.operational_classify_financial_result(p_tenant_id,result,'revenue',p_issue_date,'Receita gerada explicitamente pelo faturamento #'||doc.billing_number);
 end if;
 insert into public.billing_financial_links(tenant_id,branch_id,billing_document_id,obligation_id,link_mode,payment_terms,request_id,request_payload,actor_user_id)
 values(p_tenant_id,doc.branch_id,doc.id,result,case when p_existing_obligation_id is null then 'generated' else 'existing' end,btrim(p_payment_terms),p_request_id,payload,actor);
 insert into public.commercial_billing_events(tenant_id,branch_id,billing_document_id,event_key,actor_user_id,details) values(p_tenant_id,doc.branch_id,doc.id,'commercial_billing.receivable_linked',actor,jsonb_build_object('obligation_id',result,'mode',case when p_existing_obligation_id is null then 'generated' else 'existing' end));
 perform app_private.write_operational_audit('commercial_billing.receivable_linked',p_tenant_id,doc.branch_id,doc.id,actor,jsonb_build_object('obligation_id',result,'payment_terms',btrim(p_payment_terms),'request_id',p_request_id));
 return result;
end;$f$;

-- Existing cancellation RPC remains the sole public entry point. Cancel both
-- records atomically, only after all settlements were explicitly reversed.
create function app_private.cancel_linked_billing_receivable() returns trigger language plpgsql security definer set search_path='' set row_security=off as $f$
declare linked public.billing_financial_links%rowtype; obligation public.financial_obligations%rowtype; actor uuid;
begin
 if old.status=new.status or new.status<>'cancelled' then return new; end if;
 select * into linked from public.billing_financial_links where tenant_id=new.tenant_id and billing_document_id=new.id;
 if not found then return new; end if;
 select * into obligation from public.financial_obligations where tenant_id=linked.tenant_id and id=linked.obligation_id for update;
 actor:=app_private.assert_operational_permission(new.tenant_id,'transaction.finance.receivable.manage',new.branch_id);
 if obligation.settled_amount<>0 or exists(select 1 from public.financial_settlements s where s.tenant_id=new.tenant_id and s.obligation_id=obligation.id and not exists(select 1 from public.financial_settlement_reversals r where r.tenant_id=s.tenant_id and r.settlement_id=s.id)) then raise exception 'Reverse all receipts explicitly before cancelling linked billing' using errcode='55000'; end if;
 if exists(select 1 from public.cash_movements where tenant_id=new.tenant_id and source_obligation_id=obligation.id) or exists(select 1 from public.treasury_bank_movements m join public.financial_settlements s on s.tenant_id=m.tenant_id and s.id=m.source_settlement_id where s.tenant_id=new.tenant_id and s.obligation_id=obligation.id) then raise exception 'Linked cash or bank movement requires separate financial review before cancellation' using errcode='55000'; end if;
 update public.financial_installments set status='cancelled' where tenant_id=new.tenant_id and obligation_id=obligation.id;
 update public.financial_obligations set status='cancelled',updated_at=clock_timestamp() where tenant_id=new.tenant_id and id=obligation.id;
 insert into public.financial_events(tenant_id,branch_id,obligation_id,event_key,actor_user_id,details) values(new.tenant_id,new.branch_id,obligation.id,'financial_obligation.billing_cancelled',actor,jsonb_build_object('billing_document_id',new.id,'reason',new.cancellation_reason));
 perform app_private.write_operational_audit('financial_obligation.billing_cancelled',new.tenant_id,new.branch_id,obligation.id,actor,jsonb_build_object('billing_document_id',new.id,'reason',new.cancellation_reason)); return new;
end;$f$;
create trigger cancel_linked_billing_receivable before update of status on public.commercial_billing_documents for each row execute function app_private.cancel_linked_billing_receivable();

create function app_private.guard_billing_settlement_reversal() returns trigger language plpgsql security definer set search_path='' set row_security=off as $f$
begin
 if exists(select 1 from public.billing_financial_links l where l.tenant_id=new.tenant_id and l.obligation_id=new.obligation_id) and (
 exists(select 1 from public.financial_obligations o where o.tenant_id=new.tenant_id and o.id=new.obligation_id and o.status='cancelled') or
 exists(select 1 from public.cash_movements c where c.tenant_id=new.tenant_id and c.source_obligation_id=new.obligation_id) or
 exists(select 1 from public.treasury_bank_movements b where b.tenant_id=new.tenant_id and b.source_settlement_id=new.settlement_id)) then raise exception 'Linked billing receipt has cash/bank dependencies or is cancelled; reversal requires financial review' using errcode='55000'; end if;
 return new;
end;$f$;
create trigger guard_billing_settlement_reversal before insert on public.financial_settlement_reversals for each row execute function app_private.guard_billing_settlement_reversal();

create function public.operational_list_billing_financial_links(p_tenant_id uuid,p_branch_id uuid,p_limit integer default 100,p_offset integer default 0)
returns table(billing_document_id uuid,obligation_id uuid,link_mode text,payment_terms text,status text,gross_amount numeric,settled_amount numeric,installments jsonb)
language plpgsql stable security definer set search_path='' set row_security=off as $f$
begin
 perform app_private.assert_commercial_billing_permission(p_tenant_id,'transaction.billing.read',p_branch_id);
 perform app_private.assert_operational_permission(p_tenant_id,'transaction.finance.read',p_branch_id);
 if p_limit is null or p_limit not between 1 and 100 or p_offset is null or p_offset<0 then raise exception 'Invalid paging' using errcode='22023'; end if;
 return query select l.billing_document_id,l.obligation_id,l.link_mode,l.payment_terms,o.status,o.gross_amount,o.settled_amount,
 (select jsonb_agg(jsonb_build_object('due_date',i.due_date,'amount',i.amount,'settled_amount',i.settled_amount) order by i.installment_number) from public.financial_installments i where i.tenant_id=o.tenant_id and i.obligation_id=o.id)
 from public.billing_financial_links l join public.financial_obligations o on o.tenant_id=l.tenant_id and o.id=l.obligation_id where l.tenant_id=p_tenant_id and l.branch_id=p_branch_id order by l.created_at desc,l.billing_document_id limit p_limit offset p_offset;
end;$f$;

alter function public.operational_integrate_billing_receivable(uuid,uuid,date,text,jsonb,uuid,uuid) owner to postgres;
alter function public.operational_list_billing_financial_links(uuid,uuid,integer,integer) owner to postgres;
alter function app_private.cancel_linked_billing_receivable() owner to postgres;
alter function app_private.guard_billing_settlement_reversal() owner to postgres;
revoke all on function public.operational_integrate_billing_receivable(uuid,uuid,date,text,jsonb,uuid,uuid),public.operational_list_billing_financial_links(uuid,uuid,integer,integer),app_private.cancel_linked_billing_receivable(),app_private.guard_billing_settlement_reversal() from public,anon,authenticated,service_role;
grant execute on function public.operational_integrate_billing_receivable(uuid,uuid,date,text,jsonb,uuid,uuid),public.operational_list_billing_financial_links(uuid,uuid,integer,integer) to authenticated;
commit;
