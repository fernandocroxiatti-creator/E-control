begin;
-- Manual reconciliation retains the statement reference and original bank fact.
alter table public.treasury_bank_movements add column statement_reference text;
create unique index treasury_statement_reference on public.treasury_bank_movements(tenant_id,bank_account_id,statement_reference) where statement_reference is not null;
create function public.operational_record_bank_movement(p_tenant_id uuid,p_account_id uuid,p_direction text,p_amount numeric,p_occurred_on date,p_description text,p_request_id uuid)
returns uuid language plpgsql security definer set search_path='' set row_security=off as $f$
declare actor uuid; account public.treasury_bank_accounts%rowtype; existing public.treasury_bank_movements%rowtype; payload jsonb; result uuid;
begin
 if p_request_id is null or p_direction is null or p_direction not in ('in','out') or p_amount is null or p_amount::text in ('NaN','Infinity','-Infinity') or p_amount<=0 or p_amount<>round(p_amount,8) or p_occurred_on is null or length(btrim(coalesce(p_description,''))) not between 3 and 1000 then raise exception 'Invalid bank movement' using errcode='22023'; end if;
 select * into account from public.treasury_bank_accounts where tenant_id=p_tenant_id and id=p_account_id for update;
 if not found or account.status<>'active' then raise exception 'Active bank account required' using errcode='23503'; end if;
 actor:=app_private.assert_treasury_permission(p_tenant_id,'transaction.treasury.movement.manage',account.branch_id);
 payload:=jsonb_build_object('account',p_account_id,'direction',p_direction,'amount',p_amount,'date',p_occurred_on,'description',btrim(p_description));
 perform pg_advisory_xact_lock(hashtextextended('treasury-transfer:'||p_tenant_id::text||':'||p_request_id::text,0));
 select * into existing from public.treasury_bank_movements where tenant_id=p_tenant_id and request_id=p_request_id;
 if found then
 if existing.request_payload is distinct from payload or existing.actor_user_id is distinct from actor then raise exception 'Request reused with different payload' using errcode='23505'; end if; return existing.id;
 end if;
 insert into public.treasury_bank_movements(tenant_id,branch_id,bank_account_id,movement_kind,direction,amount,occurred_on,description,request_id,request_payload,actor_user_id)
 values(p_tenant_id,account.branch_id,p_account_id,case p_direction when 'in' then 'deposit' else 'withdrawal' end,p_direction,p_amount,p_occurred_on,btrim(p_description),p_request_id,payload,actor) returning id into result;
 perform app_private.write_operational_audit('treasury.movement.created',p_tenant_id,account.branch_id,result,actor,payload); return result;
end;$f$;

create function public.operational_reconcile_bank_movement(p_tenant_id uuid,p_movement_id uuid,p_reference text,p_amount numeric,p_occurred_on date)
returns uuid language plpgsql security definer set search_path='' set row_security=off as $f$
declare actor uuid; movement public.treasury_bank_movements%rowtype;
begin
 if length(btrim(coalesce(p_reference,''))) not between 3 and 160 or p_amount is null or p_occurred_on is null then raise exception 'Statement reference, amount and date required' using errcode='22023'; end if;
 select * into movement from public.treasury_bank_movements where tenant_id=p_tenant_id and id=p_movement_id for update;
 if not found then raise exception 'Movement not found' using errcode='23503'; end if;
 actor:=app_private.assert_treasury_permission(p_tenant_id,'transaction.treasury.reconcile.manage',movement.branch_id);
 if p_amount is distinct from (case movement.direction when 'in' then movement.amount else -movement.amount end) or p_occurred_on is distinct from movement.occurred_on then raise exception 'Statement date or signed amount does not match' using errcode='23514'; end if;
 if movement.reconciled_at is not null then
 if movement.statement_reference is distinct from btrim(p_reference) then raise exception 'Movement already reconciled to another statement' using errcode='23505'; end if; return movement.id;
 end if;
 update public.treasury_bank_movements set reconciled_at=clock_timestamp(),reconciled_by_user_id=actor,statement_reference=btrim(p_reference) where id=movement.id;
 perform app_private.write_operational_audit('treasury.movement.reconciled',p_tenant_id,movement.branch_id,movement.id,actor,jsonb_build_object('reference',btrim(p_reference))); return movement.id;
end;$f$;

create function public.operational_get_bank_treasury(p_tenant_id uuid,p_branch_id uuid,p_from date,p_to date,p_offset integer default 0)
returns jsonb language plpgsql stable security definer set search_path='' set row_security=off as $f$
declare result jsonb;
begin
 perform app_private.assert_treasury_permission(p_tenant_id,'transaction.treasury.read',p_branch_id);
 if p_from is null or p_to is null or p_from>p_to or p_to-p_from>366 or p_offset is null or p_offset<0 then raise exception 'Invalid period or offset' using errcode='22023'; end if;
 select jsonb_build_object('accounts',coalesce((select jsonb_agg(jsonb_build_object('id',a.id,'code',a.code,'name',a.name,'status',a.status,'account_kind',a.account_kind,'balance',a.opening_balance+coalesce((select sum(case m.direction when 'in' then m.amount else -m.amount end) from public.treasury_bank_movements m where m.tenant_id=a.tenant_id and m.bank_account_id=a.id and m.occurred_on<=p_to),0)) order by a.code) from public.treasury_bank_accounts a where a.tenant_id=p_tenant_id and a.branch_id=p_branch_id),'[]'::jsonb),
 'movements',coalesce((select jsonb_agg(to_jsonb(x) order by x.occurred_on desc,x.id) from (select m.id,m.bank_account_id,m.direction,m.amount,m.occurred_on,m.description,m.movement_kind,m.reconciled_at,m.statement_reference from public.treasury_bank_movements m where m.tenant_id=p_tenant_id and m.branch_id=p_branch_id and m.occurred_on between p_from and p_to order by m.occurred_on desc,m.id limit 101 offset p_offset) x),'[]'::jsonb)) into result;
 return result;
end;$f$;

alter function public.operational_record_bank_movement(uuid,uuid,text,numeric,date,text,uuid) owner to postgres;
alter function public.operational_reconcile_bank_movement(uuid,uuid,text,numeric,date) owner to postgres;
alter function public.operational_get_bank_treasury(uuid,uuid,date,date,integer) owner to postgres;
revoke all on function public.operational_record_bank_movement(uuid,uuid,text,numeric,date,text,uuid),public.operational_reconcile_bank_movement(uuid,uuid,text,numeric,date),public.operational_get_bank_treasury(uuid,uuid,date,date,integer) from public,anon,authenticated,service_role;
grant execute on function public.operational_record_bank_movement(uuid,uuid,text,numeric,date,text,uuid),public.operational_reconcile_bank_movement(uuid,uuid,text,numeric,date),public.operational_get_bank_treasury(uuid,uuid,date,date,integer) to authenticated;
commit;
