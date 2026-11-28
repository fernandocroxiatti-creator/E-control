begin;
insert into public.permission_definitions(permission_key,description,approval_state) values ('transaction.management.read','Consultar fluxo de caixa, DRE gerencial e dashboard.','pending'),('transaction.management.export','Exportar relatórios gerenciais por filial.','pending') on conflict do nothing;
insert into public.erp_transaction_authorization_catalog(transaction_code,module_code,permission_key,approval_state) values ('ZGE01','MGT','transaction.management.read','pending'),('ZGE02','MGT','transaction.management.export','pending') on conflict do nothing;

create function app_private.assert_management_permission(p_tenant_id uuid,p_branch_id uuid,p_export boolean default false)
returns uuid language plpgsql stable security definer set search_path='' set row_security=off as $f$
declare permission text:=case when p_export then 'transaction.management.export' else 'transaction.management.read' end;
begin
 if coalesce(auth.role(),'')<>'authenticated' or auth.uid() is null or p_branch_id is null
 or not exists(select 1 from public.companies where id=p_tenant_id and status='active')
 or not exists(select 1 from public.branches where tenant_id=p_tenant_id and id=p_branch_id and status='active')
 or not app_private.is_active_company_member(p_tenant_id) or not app_private.can_access_branch(p_tenant_id,p_branch_id)
 or not app_private.has_tenant_permission(p_tenant_id,permission,p_branch_id)
 or not exists(select 1 from public.erp_transaction_authorization_catalog c join public.permission_definitions d on d.permission_key=c.permission_key and d.approval_state='approved' join public.company_module_availability m on m.tenant_id=p_tenant_id and m.module_code=c.module_code and m.enabled join public.company_transaction_availability a on a.tenant_id=p_tenant_id and a.transaction_code=c.transaction_code and a.enabled where c.permission_key=permission and c.approval_state='approved')
 then raise exception 'Management permission denied' using errcode='42501'; end if;
 return auth.uid();
end;$f$;

-- DRE is based on explicitly classified obligations and their recognition date.
-- Unclassified obligations are reported separately, never silently treated as expense.
create table public.management_obligation_classifications(
 tenant_id uuid not null,obligation_id uuid not null,category text not null check(category in ('revenue','deduction','cost','expense','financial_income','financial_expense','excluded')),
 recognized_on date not null,reason text not null check(length(btrim(reason)) between 10 and 1000),actor_user_id uuid not null references auth.users(id),updated_at timestamptz not null default clock_timestamp(),primary key(tenant_id,obligation_id),foreign key(tenant_id,obligation_id) references public.financial_obligations(tenant_id,id));
alter table public.management_obligation_classifications enable row level security;
alter table public.management_obligation_classifications force row level security;
revoke all on table public.management_obligation_classifications from public,anon,authenticated,service_role;

create function public.operational_classify_financial_result(p_tenant_id uuid,p_obligation_id uuid,p_category text,p_recognized_on date,p_reason text)
returns uuid language plpgsql security definer set search_path='' set row_security=off as $f$
declare o public.financial_obligations%rowtype; actor uuid;
begin
 select * into o from public.financial_obligations where tenant_id=p_tenant_id and id=p_obligation_id for update;
 if not found then raise exception 'Obligation not found' using errcode='23503'; end if;
 actor:=app_private.assert_operational_permission(p_tenant_id,case o.obligation_type when 'receivable' then 'transaction.finance.receivable.manage' else 'transaction.finance.payable.manage' end,o.branch_id);
 if p_category is null or p_category not in ('revenue','deduction','cost','expense','financial_income','financial_expense','excluded') or p_recognized_on is null or length(btrim(coalesce(p_reason,''))) not between 10 and 1000
 or (o.obligation_type='receivable' and p_category not in ('revenue','financial_income','excluded')) or (o.obligation_type='payable' and p_category in ('revenue','financial_income')) then raise exception 'Invalid result classification' using errcode='22023'; end if;
 insert into public.management_obligation_classifications(tenant_id,obligation_id,category,recognized_on,reason,actor_user_id) values(p_tenant_id,o.id,p_category,p_recognized_on,btrim(p_reason),actor)
 on conflict(tenant_id,obligation_id) do update set category=excluded.category,recognized_on=excluded.recognized_on,reason=excluded.reason,actor_user_id=excluded.actor_user_id,updated_at=clock_timestamp();
 perform app_private.write_operational_audit('management.obligation.classified',p_tenant_id,o.branch_id,o.id,actor,jsonb_build_object('category',p_category,'recognized_on',p_recognized_on,'reason',btrim(p_reason))); return o.id;
end;$f$;

create function public.operational_get_management_report(p_tenant_id uuid,p_branch_id uuid,p_from date,p_to date,p_export boolean default false)
returns jsonb language plpgsql stable security definer set search_path='' set row_security=off as $f$
declare result jsonb;
begin
 perform app_private.assert_management_permission(p_tenant_id,p_branch_id,false);
 if p_export then perform app_private.assert_management_permission(p_tenant_id,p_branch_id,true); end if;
 if p_from is null or p_to is null or p_from>p_to or p_to-p_from>366 then raise exception 'Reporting period must be at most 367 days' using errcode='22023'; end if;
 select jsonb_build_object(
 'dre',coalesce((select jsonb_agg(to_jsonb(d) order by d.category) from (select c.category,sum(o.gross_amount) as amount from public.financial_obligations o join public.management_obligation_classifications c on c.tenant_id=o.tenant_id and c.obligation_id=o.id where o.tenant_id=p_tenant_id and o.branch_id=p_branch_id and o.status<>'cancelled' and c.recognized_on between p_from and p_to group by c.category) d),'[]'::jsonb),
 'unclassified', (select count(*) from public.financial_obligations o where o.tenant_id=p_tenant_id and o.branch_id=p_branch_id and o.status<>'cancelled' and o.issue_date between p_from and p_to and not exists(select 1 from public.management_obligation_classifications c where c.tenant_id=o.tenant_id and c.obligation_id=o.id)),
 'receivable_open',(select coalesce(sum(i.amount-i.settled_amount),0) from public.financial_installments i join public.financial_obligations o on o.tenant_id=i.tenant_id and o.id=i.obligation_id where o.tenant_id=p_tenant_id and o.branch_id=p_branch_id and o.obligation_type='receivable' and i.status<>'cancelled' and o.status<>'cancelled'),
 'payable_open',(select coalesce(sum(i.amount-i.settled_amount),0) from public.financial_installments i join public.financial_obligations o on o.tenant_id=i.tenant_id and o.id=i.obligation_id where o.tenant_id=p_tenant_id and o.branch_id=p_branch_id and o.obligation_type='payable' and i.status<>'cancelled' and o.status<>'cancelled'),
 'cash_flow',coalesce((select jsonb_agg(to_jsonb(f) order by f.day) from (
 select day,sum(receipts) receipts,sum(payments) payments,sum(expected_in) expected_in,sum(expected_out) expected_out from (
 select s.settled_on as day,case when s.settlement_type='receipt' then s.amount else 0 end receipts,case when s.settlement_type='payment' then s.amount else 0 end payments,0::numeric expected_in,0::numeric expected_out from public.financial_settlements s where s.tenant_id=p_tenant_id and s.branch_id=p_branch_id and s.settled_on between p_from and p_to and not exists(select 1 from public.financial_settlement_reversals r where r.tenant_id=s.tenant_id and r.settlement_id=s.id)
 union all
 select i.due_date,0,0,case when o.obligation_type='receivable' then i.amount-i.settled_amount else 0 end,case when o.obligation_type='payable' then i.amount-i.settled_amount else 0 end from public.financial_installments i join public.financial_obligations o on o.tenant_id=i.tenant_id and o.id=i.obligation_id where o.tenant_id=p_tenant_id and o.branch_id=p_branch_id and i.status in ('open','partially_settled') and o.status<>'cancelled' and i.due_date between p_from and p_to
 ) facts group by day) f),'[]'::jsonb)) into result;
 return result;
end;$f$;
alter function app_private.assert_management_permission(uuid,uuid,boolean) owner to postgres;
alter function public.operational_classify_financial_result(uuid,uuid,text,date,text) owner to postgres;
alter function public.operational_get_management_report(uuid,uuid,date,date,boolean) owner to postgres;
revoke all on function app_private.assert_management_permission(uuid,uuid,boolean),public.operational_classify_financial_result(uuid,uuid,text,date,text),public.operational_get_management_report(uuid,uuid,date,date,boolean) from public,anon,authenticated,service_role;
grant execute on function public.operational_classify_financial_result(uuid,uuid,text,date,text),public.operational_get_management_report(uuid,uuid,date,date,boolean) to authenticated;
commit;
