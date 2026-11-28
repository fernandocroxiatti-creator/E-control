begin;
-- Permit billing after delivery without changing historical documents.
create or replace function public.operational_issue_commercial_billing(p_tenant_id uuid,p_source_type text,p_source_id uuid,p_request_id uuid)
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
 if (p_source_type='sales_order' and source_status not in ('confirmed','fulfilled')) or (p_source_type='work_order' and source_status<>'closed') then raise exception 'Only confirmed or fulfilled sales orders or closed work orders may be billed' using errcode='55000'; end if;
 if exists(select 1 from public.commercial_billing_documents where tenant_id=p_tenant_id and source_type=p_source_type and source_id=p_source_id) then raise exception 'Source has already been billed; use the immutable cancellation process' using errcode='23505'; end if;
 insert into public.commercial_billing_documents(tenant_id,branch_id,source_type,source_id,customer_id,source_number,total_amount,request_payload,request_id,issued_by_user_id) values(p_tenant_id,branch,p_source_type,p_source_id,customer,source_number,source_total,payload,p_request_id,actor) returning id into document_id;
 insert into public.commercial_billing_events(tenant_id,branch_id,billing_document_id,event_key,actor_user_id,details) values(p_tenant_id,branch,document_id,'commercial_billing.issued',actor,pg_catalog.jsonb_build_object('source_type',p_source_type,'source_id',p_source_id,'total_amount',source_total));
 perform app_private.write_operational_audit('commercial_billing.issued',p_tenant_id,branch,document_id,actor,pg_catalog.jsonb_build_object('source_type',p_source_type,'source_id',p_source_id,'total_amount',source_total));
 return document_id;
end;$fn$;
create function app_private.prevent_billed_sales_cancellation()
returns trigger language plpgsql security definer set search_path='' set row_security=off as $fn$
begin
 if new.status='cancelled' and old.status is distinct from new.status and exists (
  select 1 from public.commercial_billing_documents where tenant_id=new.tenant_id and source_type='sales_order' and source_id=new.id and status='issued'
 ) then raise exception 'Cancel active commercial billing before cancelling or returning this sale' using errcode='55000'; end if;
 return new;
end;$fn$;
alter function app_private.prevent_billed_sales_cancellation() owner to postgres;
revoke all on function app_private.prevent_billed_sales_cancellation() from public,anon,authenticated,service_role;
create trigger prevent_billed_sales_cancellation before update of status on public.sales_orders for each row execute function app_private.prevent_billed_sales_cancellation();
commit;
