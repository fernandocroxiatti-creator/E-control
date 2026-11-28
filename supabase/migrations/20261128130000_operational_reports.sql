begin;
insert into public.permission_definitions(permission_key,description,approval_state) values
 ('transaction.reports.purchases','Relatórios de compras por filial.','pending_approval'),
 ('transaction.reports.sales','Relatórios de vendas por filial.','pending_approval'),
 ('transaction.reports.inventory','Relatórios de movimentações de estoque por filial.','pending_approval'),
 ('transaction.reports.finance','Relatórios financeiros por filial.','pending_approval'),
 ('transaction.reports.banks','Relatórios bancários por filial.','pending_approval'),
 ('transaction.reports.work_orders','Relatórios de ordens de serviço por filial.','pending_approval') on conflict do nothing;
insert into public.erp_transaction_authorization_catalog(transaction_code,module_code,permission_key,approval_state) values
 ('ZRP01','MGT','transaction.reports.purchases','pending_approval'),('ZRP02','MGT','transaction.reports.sales','pending_approval'),
 ('ZRP03','MGT','transaction.reports.inventory','pending_approval'),('ZRP04','MGT','transaction.reports.finance','pending_approval'),
 ('ZRP05','MGT','transaction.reports.banks','pending_approval'),('ZRP06','MGT','transaction.reports.work_orders','pending_approval') on conflict do nothing;

create function public.operational_get_report(p_tenant_id uuid,p_branch_id uuid,p_kind text,p_from date,p_to date,p_status text default null,p_search text default null,p_limit integer default 100,p_offset integer default 0,p_export boolean default false)
returns jsonb language plpgsql stable security definer set search_path='' set row_security=off as $f$
declare permission text; result jsonb;
begin
 if p_kind is null or p_kind not in ('purchases','sales','inventory','finance','banks','work_orders') or p_from is null or p_to is null or p_from>p_to or p_to-p_from>366 or p_limit is null or p_limit not between 1 and 5000 or p_offset is null or p_offset<0 or p_offset>1000000 or length(coalesce(p_search,''))>120 or length(coalesce(p_status,''))>32 or p_export is null then raise exception 'Invalid report filters' using errcode='22023'; end if;
 permission:='transaction.reports.'||p_kind;
 if coalesce(auth.role(),'')<>'authenticated' or auth.uid() is null or p_branch_id is null
 or not exists(select 1 from public.companies where id=p_tenant_id and status='active')
 or not exists(select 1 from public.branches where tenant_id=p_tenant_id and id=p_branch_id and status='active')
 or not app_private.is_active_company_member(p_tenant_id) or not app_private.can_access_branch(p_tenant_id,p_branch_id)
 or not app_private.has_tenant_permission(p_tenant_id,permission,p_branch_id)
 or not exists(select 1 from public.erp_transaction_authorization_catalog c join public.permission_definitions d on d.permission_key=c.permission_key and d.approval_state='approved' join public.company_module_availability m on m.tenant_id=p_tenant_id and m.module_code=c.module_code and m.enabled join public.company_transaction_availability a on a.tenant_id=p_tenant_id and a.transaction_code=c.transaction_code and a.enabled where c.permission_key=permission and c.approval_state='approved') then raise exception 'Report permission denied' using errcode='42501'; end if;
 if p_kind='banks' then perform app_private.assert_treasury_permission(p_tenant_id,'transaction.treasury.read',p_branch_id);
 else perform app_private.assert_operational_permission(p_tenant_id,case p_kind when 'purchases' then 'transaction.purchasing.purchase_order.read' when 'sales' then 'transaction.sales.order.read' when 'inventory' then 'transaction.inventory.history.read' when 'finance' then 'transaction.finance.read' when 'work_orders' then 'transaction.service_order.read' end,p_branch_id); end if;
 if p_export then perform app_private.assert_management_permission(p_tenant_id,p_branch_id,true); end if;
 with facts as (
 select o.id,(o.created_at at time zone 'America/Sao_Paulo')::date as day,o.order_number::text as reference,p.legal_name as description,o.status,null::numeric as quantity,o.total_amount as amount,null::numeric as balance from public.purchase_orders o join public.business_parties p on p.tenant_id=o.tenant_id and p.id=o.supplier_id where p_kind='purchases' and o.tenant_id=p_tenant_id and o.branch_id=p_branch_id
 union all
 select o.id,(o.created_at at time zone 'America/Sao_Paulo')::date,o.sales_order_number::text,p.legal_name,o.status,null,o.total_amount,null from public.sales_orders o join public.business_parties p on p.tenant_id=o.tenant_id and p.id=o.customer_id where p_kind='sales' and o.tenant_id=p_tenant_id and o.branch_id=p_branch_id
 union all
 select m.id,(m.created_at at time zone 'America/Sao_Paulo')::date,i.code,i.name,m.movement_type,m.quantity,m.value_delta,m.balance_after from public.inventory_movements m join public.catalog_items i on i.tenant_id=m.tenant_id and i.id=m.item_id where p_kind='inventory' and m.tenant_id=p_tenant_id and m.branch_id=p_branch_id
 union all
 select o.id,o.issue_date,case o.obligation_type when 'receivable' then 'A receber' else 'A pagar' end,o.description,o.status,null,o.gross_amount,o.gross_amount-o.settled_amount from public.financial_obligations o where p_kind='finance' and o.tenant_id=p_tenant_id and o.branch_id=p_branch_id
 union all
 select m.id,m.occurred_on,a.code,m.description,case when m.reconciled_at is null then 'pending' else 'reconciled' end,null,case m.direction when 'in' then m.amount else -m.amount end,null from public.treasury_bank_movements m join public.treasury_bank_accounts a on a.tenant_id=m.tenant_id and a.id=m.bank_account_id where p_kind='banks' and m.tenant_id=p_tenant_id and m.branch_id=p_branch_id
 union all
 select o.id,(o.created_at at time zone 'America/Sao_Paulo')::date,o.order_number::text,p.legal_name,o.status,null,o.total_amount,null from public.work_orders o join public.business_parties p on p.tenant_id=o.tenant_id and p.id=o.customer_id where p_kind='work_orders' and o.tenant_id=p_tenant_id and o.branch_id=p_branch_id
 ), filtered as materialized (
 select * from facts f where f.day between p_from and p_to and (nullif(p_status,'') is null or f.status=p_status) and (nullif(btrim(p_search),'') is null or strpos(lower(f.description||' '||f.reference),lower(btrim(p_search)))>0)
 ), page as (select * from filtered order by day desc,id limit p_limit offset p_offset)
 select jsonb_build_object('total_count',(select count(*) from filtered),'amount_total',(select sum(amount)::text from filtered),'rows',coalesce((select jsonb_agg(jsonb_build_object('id',id,'date',day,'reference',reference,'description',description,'status',status,'quantity',quantity::text,'amount',amount::text,'balance',balance::text) order by day desc,id) from page),'[]'::jsonb)) into result;
 return result;
end;$f$;
alter function public.operational_get_report(uuid,uuid,text,date,date,text,text,integer,integer,boolean) owner to postgres;
revoke all on function public.operational_get_report(uuid,uuid,text,date,date,text,text,integer,integer,boolean) from public,anon,authenticated,service_role;
grant execute on function public.operational_get_report(uuid,uuid,text,date,date,text,text,integer,integer,boolean) to authenticated;
commit;
