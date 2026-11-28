begin;
-- Read-only management aggregates over persisted commercial and financial facts.
create or replace function public.operational_get_management_summary(p_tenant_id uuid,p_branch_id uuid,p_from date,p_to date)
returns table(receivable_open numeric,payable_open numeric,settled_receivable numeric,settled_payable numeric,billed_revenue numeric,inventory_value numeric)
language plpgsql stable security definer set search_path='' set row_security=off as $fn$
begin
  perform app_private.assert_operational_permission(p_tenant_id,'transaction.finance.read',p_branch_id);
  if p_from is null or p_to is null or p_from>p_to or p_to-p_from>366 then raise exception 'Valid reporting period is required' using errcode='22023'; end if;
  return query select
    coalesce((select sum(i.amount-i.settled_amount) from public.financial_installments i join public.financial_obligations o on o.tenant_id=i.tenant_id and o.id=i.obligation_id where o.tenant_id=p_tenant_id and o.branch_id=p_branch_id and o.obligation_type='receivable' and i.status<>'cancelled'),0),
    coalesce((select sum(i.amount-i.settled_amount) from public.financial_installments i join public.financial_obligations o on o.tenant_id=i.tenant_id and o.id=i.obligation_id where o.tenant_id=p_tenant_id and o.branch_id=p_branch_id and o.obligation_type='payable' and i.status<>'cancelled'),0),
    coalesce((select sum(s.amount) from public.financial_settlements s join public.financial_installments i on i.tenant_id=s.tenant_id and i.id=s.installment_id join public.financial_obligations o on o.tenant_id=i.tenant_id and o.id=i.obligation_id where o.tenant_id=p_tenant_id and o.branch_id=p_branch_id and o.obligation_type='receivable' and s.settled_on between p_from and p_to and not exists(select 1 from public.financial_settlement_reversals r where r.tenant_id=s.tenant_id and r.settlement_id=s.id)),0),
    coalesce((select sum(s.amount) from public.financial_settlements s join public.financial_installments i on i.tenant_id=s.tenant_id and i.id=s.installment_id join public.financial_obligations o on o.tenant_id=i.tenant_id and o.id=i.obligation_id where o.tenant_id=p_tenant_id and o.branch_id=p_branch_id and o.obligation_type='payable' and s.settled_on between p_from and p_to and not exists(select 1 from public.financial_settlement_reversals r where r.tenant_id=s.tenant_id and r.settlement_id=s.id)),0),
    coalesce((select sum(d.total_amount) from public.commercial_billing_documents d where d.tenant_id=p_tenant_id and d.branch_id=p_branch_id and d.status='issued' and d.issued_at::date between p_from and p_to),0),
    coalesce((select sum(v.stock_value) from public.inventory_balances v where v.tenant_id=p_tenant_id and v.branch_id=p_branch_id),0);
end;$fn$;
alter function public.operational_get_management_summary(uuid,uuid,date,date) owner to postgres;
revoke all on function public.operational_get_management_summary(uuid,uuid,date,date) from public,anon,authenticated,service_role;
grant execute on function public.operational_get_management_summary(uuid,uuid,date,date) to authenticated;
commit;
