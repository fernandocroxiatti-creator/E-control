begin;

-- Reuse the isolated Phase 05 tenant and actor, adding only scoped CSH access.
do $setup$
declare v_tenant_id constant uuid := '91000000-0000-4000-8000-000000000001'; v_branch_id constant uuid := '92000000-0000-4000-8000-000000000001'; v_actor_id constant uuid := '93000000-0000-4000-8000-000000000001';
begin
  insert into public.access_role_definitions(role_key,display_name,scope,approval_state) values('phase07_owner','Phase 07 owner','company','approved');
  insert into public.membership_role_assignments(tenant_id,membership_id,role_key,branch_id,assigned_by_user_id)
    select v_tenant_id,m.id,'phase07_owner',null,v_actor_id from public.company_memberships m where m.tenant_id=v_tenant_id and m.user_id=v_actor_id;
  update public.permission_definitions set approval_state='approved' where permission_key like 'transaction.cash.%';
  update public.erp_transaction_authorization_catalog set approval_state='approved' where transaction_code in ('ZCX01','ZCX02','ZCX03','ZCX04');
  insert into public.company_module_availability(tenant_id,module_code,enabled,changed_by_user_id) values(v_tenant_id,'CSH',true,v_actor_id) on conflict(tenant_id,module_code) do update set enabled=true;
  insert into public.company_transaction_availability(tenant_id,transaction_code,enabled,changed_by_user_id) values
    (v_tenant_id,'ZCX01',true,v_actor_id),(v_tenant_id,'ZCX02',true,v_actor_id),(v_tenant_id,'ZCX03',true,v_actor_id),(v_tenant_id,'ZCX04',true,v_actor_id)
    on conflict(tenant_id,transaction_code) do update set enabled=true;
  insert into public.company_role_permission_grants(tenant_id,branch_id,grant_scope,role_key,permission_key,reason,created_by_user_id) values
    (v_tenant_id,v_branch_id,'branch','phase07_owner','transaction.cash.register.open','Phase 07 isolated test',v_actor_id),
    (v_tenant_id,v_branch_id,'branch','phase07_owner','transaction.cash.register.move','Phase 07 isolated test',v_actor_id),
    (v_tenant_id,v_branch_id,'branch','phase07_owner','transaction.cash.register.close','Phase 07 isolated test',v_actor_id),
    (v_tenant_id,v_branch_id,'branch','phase07_owner','transaction.cash.register.read','Phase 07 isolated test',v_actor_id);
end $setup$;

select set_config('request.jwt.claim.role','authenticated',false); select set_config('request.jwt.claim.sub','93000000-0000-4000-8000-000000000001',false);

do $test$
declare v_tenant_id constant uuid := '91000000-0000-4000-8000-000000000001'; v_branch_id constant uuid := '92000000-0000-4000-8000-000000000001'; register_id uuid; session_id uuid; movement_id uuid; settlements_before integer; movement_count integer;
begin
  select public.operational_create_cash_register(v_tenant_id,v_branch_id,'CX01','Caixa fase 07','97000000-0000-4000-8000-000000000001') into register_id;
  if public.operational_create_cash_register(v_tenant_id,v_branch_id,'CX01','Caixa fase 07','97000000-0000-4000-8000-000000000001')<>register_id then raise exception 'cash register replay failed'; end if;
  begin perform public.operational_create_cash_register(v_tenant_id,v_branch_id,'CX02','Outro caixa','97000000-0000-4000-8000-000000000001'); raise exception 'divergent register replay accepted'; exception when unique_violation then null; end;
  select public.operational_open_cash_session(v_tenant_id,v_branch_id,register_id,10,'97000000-0000-4000-8000-000000000002') into session_id;
  if public.operational_open_cash_session(v_tenant_id,v_branch_id,register_id,10,'97000000-0000-4000-8000-000000000002')<>session_id then raise exception 'cash opening replay failed'; end if;
  begin perform public.operational_open_cash_session(v_tenant_id,v_branch_id,register_id,10,'97000000-0000-4000-8000-000000000003'); raise exception 'second open session accepted'; exception when object_not_in_prerequisite_state then null; end;
  begin perform public.operational_record_cash_movement(v_tenant_id,session_id,'supply','out',2,'direction check','97000000-0000-4000-8000-000000000004'); raise exception 'invalid direction accepted'; exception when check_violation then null; end;
  select count(*) into settlements_before from public.financial_settlements where tenant_id=v_tenant_id;
  select public.operational_record_cash_movement(v_tenant_id,session_id,'supply','in',5,'Suprimento de teste','97000000-0000-4000-8000-000000000005') into movement_id;
  if public.operational_record_cash_movement(v_tenant_id,session_id,'supply','in',5,'Suprimento de teste','97000000-0000-4000-8000-000000000005')<>movement_id then raise exception 'cash movement replay failed'; end if;
  begin perform public.operational_record_cash_movement(v_tenant_id,session_id,'supply','in',6,'Suprimento divergente','97000000-0000-4000-8000-000000000005'); raise exception 'divergent movement replay accepted'; exception when unique_violation then null; end;
  if (select count(*) from public.financial_settlements where tenant_id=v_tenant_id)<>settlements_before then raise exception 'cash movement created financial settlement'; end if;
  if public.operational_close_cash_session(v_tenant_id,session_id,15,'97000000-0000-4000-8000-000000000006')<>'closed' then raise exception 'cash close failed'; end if;
  begin perform public.operational_record_cash_movement(v_tenant_id,session_id,'withdrawal','out',1,'closed session','97000000-0000-4000-8000-000000000007'); raise exception 'movement in closed session accepted'; exception when object_not_in_prerequisite_state then null; end;
  select count(*) into movement_count from public.cash_movements m where m.tenant_id=v_tenant_id and m.cash_session_id=session_id;
  if movement_count<>1 or (select expected_amount from public.cash_sessions where id=session_id)<>15 then raise exception 'cash ledger total wrong'; end if;
end $test$;

do $security$
begin
  if not (select relrowsecurity and relforcerowsecurity from pg_class where oid='public.cash_movements'::regclass)
    or has_table_privilege('authenticated','public.cash_movements','select')
    or has_function_privilege('anon','public.operational_open_cash_session(uuid,uuid,uuid,numeric,uuid)','execute') then raise exception 'cash RLS or ACL hardening failed'; end if;
end $security$;

rollback;
