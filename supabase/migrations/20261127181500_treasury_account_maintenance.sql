begin;
create function public.operational_update_bank_account(p_tenant_id uuid,p_account_id uuid,p_name text,p_status text,p_reason text)
returns uuid language plpgsql security definer set search_path='' set row_security=off as $f$
declare a public.treasury_bank_accounts%rowtype; actor uuid;
begin
 if length(btrim(coalesce(p_name,''))) not between 2 and 160 or p_status is null or p_status not in ('active','inactive') or length(btrim(coalesce(p_reason,''))) not between 10 and 1000 then raise exception 'Valid name, status and reason required' using errcode='22023'; end if;
 select * into a from public.treasury_bank_accounts where tenant_id=p_tenant_id and id=p_account_id for update;
 if not found then raise exception 'Account not found' using errcode='23503'; end if;
 actor:=app_private.assert_treasury_permission(p_tenant_id,'transaction.treasury.account.manage',a.branch_id);
 if p_status='inactive' and (a.opening_balance+coalesce((select sum(case m.direction when 'in' then m.amount else -m.amount end) from public.treasury_bank_movements m where m.tenant_id=p_tenant_id and m.bank_account_id=a.id),0)<>0 or exists(select 1 from public.treasury_bank_movements m where m.tenant_id=p_tenant_id and m.bank_account_id=a.id and m.reconciled_at is null)) then raise exception 'Reconcile movements and clear balance before deactivating account' using errcode='55000'; end if;
 if a.name=btrim(p_name) and a.status=p_status then return a.id; end if;
 update public.treasury_bank_accounts set name=btrim(p_name),status=p_status where id=a.id;
 perform app_private.write_operational_audit('treasury.account.updated',p_tenant_id,a.branch_id,a.id,actor,jsonb_build_object('old_name',a.name,'old_status',a.status,'name',btrim(p_name),'status',p_status,'reason',btrim(p_reason))); return a.id;
end;$f$;
create function public.operational_unreconcile_bank_movement(p_tenant_id uuid,p_movement_id uuid,p_reference text,p_reason text)
returns uuid language plpgsql security definer set search_path='' set row_security=off as $f$
declare m public.treasury_bank_movements%rowtype; actor uuid;
begin
 if length(btrim(coalesce(p_reason,''))) not between 10 and 1000 or length(btrim(coalesce(p_reference,''))) not between 3 and 160 then raise exception 'Reference and reason required' using errcode='22023'; end if;
 select * into m from public.treasury_bank_movements where tenant_id=p_tenant_id and id=p_movement_id for update;
 if not found then raise exception 'Movement not found' using errcode='23503'; end if;
 actor:=app_private.assert_treasury_permission(p_tenant_id,'transaction.treasury.reconcile.manage',m.branch_id);
 if m.reconciled_at is null then return m.id; end if;
 if m.statement_reference is distinct from btrim(p_reference) then raise exception 'Reconciliation reference changed' using errcode='55000'; end if;
 update public.treasury_bank_movements set reconciled_at=null,reconciled_by_user_id=null,statement_reference=null where id=m.id;
 perform app_private.write_operational_audit('treasury.movement.unreconciled',p_tenant_id,m.branch_id,m.id,actor,jsonb_build_object('reference',m.statement_reference,'reason',btrim(p_reason))); return m.id;
end;$f$;
alter function public.operational_update_bank_account(uuid,uuid,text,text,text) owner to postgres;
alter function public.operational_unreconcile_bank_movement(uuid,uuid,text,text) owner to postgres;
revoke all on function public.operational_update_bank_account(uuid,uuid,text,text,text),public.operational_unreconcile_bank_movement(uuid,uuid,text,text) from public,anon,authenticated,service_role;
grant execute on function public.operational_update_bank_account(uuid,uuid,text,text,text),public.operational_unreconcile_bank_movement(uuid,uuid,text,text) to authenticated;
commit;
