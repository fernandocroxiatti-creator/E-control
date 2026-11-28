begin;

-- Cancellation extinguishes the collectible balance, not the historical amount.
-- Read model only: original obligations, installments and settlement events remain intact.
create or replace function public.operational_list_financial_obligations(p_tenant_id uuid,p_branch_id uuid,p_type text default null,p_status text default null,p_limit integer default 50,p_offset integer default 0)
returns table(obligation_id uuid,obligation_type text,status text,description text,gross_amount numeric,settled_amount numeric,open_amount numeric,installments jsonb,created_at timestamptz)
language plpgsql stable security definer set search_path='' set row_security=off as $fn$
begin
  perform app_private.assert_operational_permission(p_tenant_id,'transaction.finance.read',p_branch_id);
  if p_limit not between 1 and 100 or p_offset<0 or (p_type is not null and p_type not in ('payable','receivable')) or (p_status is not null and p_status not in ('open','partially_settled','settled','cancelled')) then raise exception 'Invalid financial listing request' using errcode='22023'; end if;
  return query select o.id,o.obligation_type,o.status,o.description,o.gross_amount,o.settled_amount,case when o.status='cancelled' then 0::numeric else o.gross_amount-o.settled_amount end,
    coalesce((select pg_catalog.jsonb_agg(pg_catalog.jsonb_build_object('installment_id',i.id,'number',i.installment_number,'due_date',i.due_date,'amount',i.amount,'settled_amount',i.settled_amount,'open_amount',case when o.status='cancelled' or i.status='cancelled' then 0::numeric else i.amount-i.settled_amount end,'status',i.status,'settlements',coalesce((select pg_catalog.jsonb_agg(pg_catalog.jsonb_build_object('settlement_id',s.id,'amount',s.amount,'settled_on',s.settled_on,'method',s.method,'reversed',exists(select 1 from public.financial_settlement_reversals r where r.tenant_id=s.tenant_id and r.settlement_id=s.id)) order by s.created_at) from public.financial_settlements s where s.tenant_id=i.tenant_id and s.installment_id=i.id),'[]'::jsonb)) order by i.installment_number) from public.financial_installments i where i.tenant_id=o.tenant_id and i.obligation_id=o.id),'[]'::jsonb),o.created_at
    from public.financial_obligations o where o.tenant_id=p_tenant_id and o.branch_id=p_branch_id and (p_type is null or o.obligation_type=p_type) and (p_status is null or o.status=p_status) order by o.created_at desc,o.id desc limit p_limit offset p_offset;
end;$fn$;

commit;
