begin;
-- Bank treasury is a distinct ledger. It never settles financial installments implicitly.
insert into public.permission_definitions(permission_key,description,approval_state) values
 ('transaction.treasury.account.manage','Gerenciar contas bancárias por empresa e filial.','pending'),
 ('transaction.treasury.movement.manage','Registrar movimentos e transferências bancárias auditáveis.','pending'),
 ('transaction.treasury.reconcile.manage','Conciliar movimentos bancários manualmente.','pending'),
 ('transaction.treasury.read','Consultar tesouraria e fluxo de caixa.','pending') on conflict(permission_key) do nothing;
insert into public.erp_transaction_authorization_catalog(transaction_code,module_code,permission_key,approval_state) values
 ('ZTR02','TSY','transaction.treasury.account.manage','pending'),('ZTR03','TSY','transaction.treasury.movement.manage','pending'),('ZTR04','TSY','transaction.treasury.reconcile.manage','pending'),('ZTR05','TSY','transaction.treasury.read','pending') on conflict(transaction_code) do nothing;

create table public.treasury_bank_accounts(
 id uuid primary key default pg_catalog.gen_random_uuid(),tenant_id uuid not null references public.companies(id) on delete restrict,branch_id uuid not null,
 code text not null check(code=pg_catalog.upper(pg_catalog.btrim(code)) and length(code) between 2 and 32),name text not null check(length(pg_catalog.btrim(name)) between 2 and 160),bank_name text,account_kind text not null check(account_kind in ('checking','savings','wallet')),status text not null default 'active' check(status in ('active','inactive')),opening_balance numeric(24,8) not null default 0,request_id uuid not null,request_payload jsonb not null,created_by_user_id uuid not null references auth.users(id),created_at timestamptz not null default clock_timestamp(),unique(tenant_id,branch_id,code),unique(tenant_id,request_id));
create table public.treasury_bank_movements(
 id uuid primary key default pg_catalog.gen_random_uuid(),tenant_id uuid not null references public.companies(id) on delete restrict,branch_id uuid not null,bank_account_id uuid not null references public.treasury_bank_accounts(id) on delete restrict,
 movement_kind text not null check(movement_kind in ('deposit','withdrawal','transfer_in','transfer_out','adjustment')),direction text not null check(direction in ('in','out')),amount numeric(24,8) not null check(amount>0),occurred_on date not null,description text not null check(length(pg_catalog.btrim(description)) between 3 and 1000),counterparty_account_id uuid references public.treasury_bank_accounts(id) on delete restrict,source_settlement_id uuid references public.financial_settlements(id) on delete restrict,reconciled_at timestamptz,reconciled_by_user_id uuid references auth.users(id),request_id uuid not null,request_payload jsonb not null,actor_user_id uuid not null references auth.users(id),created_at timestamptz not null default clock_timestamp(),unique(tenant_id,request_id));
alter table public.treasury_bank_accounts enable row level security; alter table public.treasury_bank_accounts force row level security;
alter table public.treasury_bank_movements enable row level security; alter table public.treasury_bank_movements force row level security;
revoke all on table public.treasury_bank_accounts,public.treasury_bank_movements from public,anon,authenticated,service_role;

create or replace function app_private.assert_treasury_permission(p_tenant_id uuid,p_key text,p_branch_id uuid) returns uuid language plpgsql stable security definer set search_path='' set row_security=off as $f$
declare actor uuid; codes text[]; ready integer;
begin
 if coalesce(auth.role(),'')<>'authenticated' or auth.uid() is null or p_branch_id is null
 or not exists(select 1 from public.companies where id=p_tenant_id and status='active')
 or not exists(select 1 from public.branches where tenant_id=p_tenant_id and id=p_branch_id and status='active')
 or not app_private.is_active_company_member(p_tenant_id)
 or not app_private.can_access_branch(p_tenant_id,p_branch_id)
 or not app_private.has_tenant_permission(p_tenant_id,p_key,p_branch_id)
 then raise exception 'Treasury permission denied' using errcode='42501'; end if;
 actor:=auth.uid();
 codes:=case p_key when 'transaction.treasury.account.manage' then array['ZTR02'] when 'transaction.treasury.movement.manage' then array['ZTR03'] when 'transaction.treasury.reconcile.manage' then array['ZTR04'] when 'transaction.treasury.read' then array['ZTR05'] else null end;
 if codes is null then raise exception 'Treasury permission is not mapped' using errcode='42501'; end if;
 select count(*) into ready from public.erp_transaction_authorization_catalog c join public.permission_definitions p on p.permission_key=c.permission_key and p.approval_state='approved' join public.company_module_availability m on m.tenant_id=p_tenant_id and m.module_code=c.module_code and m.enabled join public.company_transaction_availability a on a.tenant_id=p_tenant_id and a.transaction_code=c.transaction_code and a.enabled where c.transaction_code=any(codes) and c.approval_state='approved';
 if ready<>1 then raise exception 'Treasury transaction is not approved or available for this company' using errcode='42501'; end if; return actor;
end;$f$;

create function public.operational_create_bank_account(p_tenant_id uuid,p_branch_id uuid,p_code text,p_name text,p_kind text,p_opening numeric,p_request_id uuid) returns uuid language plpgsql volatile security definer set search_path='' set row_security=off as $f$
declare actor uuid; result uuid; payload jsonb; existing public.treasury_bank_accounts%rowtype; code text:=upper(btrim(coalesce(p_code,''))); name text:=btrim(coalesce(p_name,''));
begin
 if p_tenant_id is null or p_branch_id is null or p_request_id is null or length(code) not between 2 and 32 or length(name) not between 2 and 160 or p_kind is null or p_kind not in ('checking','savings','wallet') or p_opening is null or p_opening::text in ('NaN','Infinity','-Infinity') or p_opening<>round(p_opening,8) then raise exception 'Valid bank account data is required' using errcode='22023'; end if;
 actor:=app_private.assert_treasury_permission(p_tenant_id,'transaction.treasury.account.manage',p_branch_id); payload:=jsonb_build_object('branch_id',p_branch_id,'code',code,'name',name,'kind',p_kind,'opening',p_opening); perform pg_advisory_xact_lock(hashtextextended('treasury-account:'||p_tenant_id::text||':'||p_request_id::text,0)); select * into existing from public.treasury_bank_accounts where tenant_id=p_tenant_id and request_id=p_request_id;
 if found then if existing.request_payload is distinct from payload or existing.created_by_user_id is distinct from actor then raise exception 'Bank account request identifier belongs to a different payload' using errcode='23505'; end if; return existing.id; end if;
 insert into public.treasury_bank_accounts(tenant_id,branch_id,code,name,account_kind,opening_balance,request_id,request_payload,created_by_user_id) values(p_tenant_id,p_branch_id,code,name,p_kind,p_opening,p_request_id,payload,actor) returning id into result; perform app_private.write_operational_audit('treasury.bank_account.created',p_tenant_id,p_branch_id,result,actor,payload); return result;
end;$f$;

create function public.operational_transfer_bank_funds(p_tenant_id uuid,p_from uuid,p_to uuid,p_amount numeric,p_occurred_on date,p_description text,p_request_id uuid) returns uuid language plpgsql volatile security definer set search_path='' set row_security=off as $f$
declare actor uuid; source public.treasury_bank_accounts%rowtype; destination public.treasury_bank_accounts%rowtype; transfer_id uuid:=gen_random_uuid(); payload jsonb; existing public.treasury_bank_movements%rowtype; description_text text:=btrim(coalesce(p_description,''));
begin
 if p_tenant_id is null or p_from is null or p_to is null or p_from=p_to or p_request_id is null or p_amount is null or p_amount::text in ('NaN','Infinity','-Infinity') or p_amount<=0 or p_amount<>round(p_amount,8) or p_occurred_on is null or length(description_text) not between 3 and 1000 then raise exception 'Valid bank transfer data is required' using errcode='22023'; end if;
 perform 1 from public.treasury_bank_accounts where tenant_id=p_tenant_id and id in (p_from,p_to) order by id for update;
 select * into source from public.treasury_bank_accounts where tenant_id=p_tenant_id and id=p_from and status='active' for update; if not found then raise exception 'Active source account required' using errcode='23503'; end if; select * into destination from public.treasury_bank_accounts where tenant_id=p_tenant_id and id=p_to and status='active' for update; if not found or destination.branch_id<>source.branch_id then raise exception 'Active destination account in the same branch required' using errcode='23503'; end if;
 actor:=app_private.assert_treasury_permission(p_tenant_id,'transaction.treasury.movement.manage',source.branch_id); payload:=jsonb_build_object('from',p_from,'to',p_to,'amount',p_amount,'occurred_on',p_occurred_on,'description',description_text); perform pg_advisory_xact_lock(hashtextextended('treasury-transfer:'||p_tenant_id::text||':'||p_request_id::text,0)); select * into existing from public.treasury_bank_movements where tenant_id=p_tenant_id and request_id=p_request_id;
 if found then if existing.request_payload is distinct from payload or existing.actor_user_id is distinct from actor then raise exception 'Bank transfer request identifier belongs to a different payload' using errcode='23505'; end if; return existing.id; end if;
 insert into public.treasury_bank_movements(tenant_id,branch_id,bank_account_id,movement_kind,direction,amount,occurred_on,description,counterparty_account_id,request_id,request_payload,actor_user_id) values(p_tenant_id,source.branch_id,p_from,'transfer_out','out',p_amount,p_occurred_on,description_text,p_to,p_request_id,payload,actor) returning id into transfer_id;
 insert into public.treasury_bank_movements(tenant_id,branch_id,bank_account_id,movement_kind,direction,amount,occurred_on,description,counterparty_account_id,request_id,request_payload,actor_user_id) values(p_tenant_id,source.branch_id,p_to,'transfer_in','in',p_amount,p_occurred_on,description_text,p_from,gen_random_uuid(),jsonb_build_object('transfer_id',transfer_id),actor);
 perform app_private.write_operational_audit('treasury.bank_transfer.created',p_tenant_id,source.branch_id,transfer_id,actor,payload); return transfer_id;
end;$f$;
alter function app_private.assert_treasury_permission(uuid,text,uuid) owner to postgres; alter function public.operational_create_bank_account(uuid,uuid,text,text,text,numeric,uuid) owner to postgres; alter function public.operational_transfer_bank_funds(uuid,uuid,uuid,numeric,date,text,uuid) owner to postgres;
revoke all on function app_private.assert_treasury_permission(uuid,text,uuid),public.operational_create_bank_account(uuid,uuid,text,text,text,numeric,uuid),public.operational_transfer_bank_funds(uuid,uuid,uuid,numeric,date,text,uuid) from public,anon,authenticated,service_role;
grant execute on function public.operational_create_bank_account(uuid,uuid,text,text,text,numeric,uuid),public.operational_transfer_bank_funds(uuid,uuid,uuid,numeric,date,text,uuid) to authenticated;
alter table public.treasury_bank_accounts add unique(tenant_id,branch_id,id), add foreign key(tenant_id,branch_id) references public.branches(tenant_id,id);
alter table public.treasury_bank_movements add foreign key(tenant_id,branch_id,bank_account_id) references public.treasury_bank_accounts(tenant_id,branch_id,id), add foreign key(tenant_id,branch_id,counterparty_account_id) references public.treasury_bank_accounts(tenant_id,branch_id,id);
create index treasury_movements_account_date on public.treasury_bank_movements(tenant_id,branch_id,bank_account_id,occurred_on,id);
commit;
