begin;
update public.permission_definitions set approval_state='approved' where permission_key='transaction.inventory.stock.move';
update public.erp_transaction_authorization_catalog set approval_state='approved' where transaction_code='MIGO';
insert into public.company_module_availability(tenant_id,module_code,enabled,changed_by_user_id) values('e1100000-0000-4000-8000-000000000001','INV',true,'e1300000-0000-4000-8000-000000000001') on conflict(tenant_id,module_code) do update set enabled=true;
insert into public.company_transaction_availability(tenant_id,transaction_code,enabled,changed_by_user_id) values('e1100000-0000-4000-8000-000000000001','MIGO',true,'e1300000-0000-4000-8000-000000000001') on conflict(tenant_id,transaction_code) do update set enabled=true;
insert into public.company_role_permission_grants(tenant_id,branch_id,grant_scope,role_key,permission_key,reason,created_by_user_id) select 'e1100000-0000-4000-8000-000000000001','e1200000-0000-4000-8000-000000000001','branch',role_key,'transaction.inventory.stock.move','Isolated final-chain regression','e1300000-0000-4000-8000-000000000001' from public.membership_role_assignments where tenant_id='e1100000-0000-4000-8000-000000000001' limit 1;
select set_config('request.jwt.claim.role','authenticated',false);
select set_config('request.jwt.claim.sub','e1300000-0000-4000-8000-000000000001',false);
do $$ begin
 perform public.operational_list_inventory_balances('e1100000-0000-4000-8000-000000000001','e1200000-0000-4000-8000-000000000001',null,25,0);
 perform public.operational_list_inventory_movements('e1100000-0000-4000-8000-000000000001','e1200000-0000-4000-8000-000000000001',null,null,null,null,25,0);
 begin
  perform public.operational_list_inventory_balances('e1100000-0000-4000-8000-000000000002','e1200000-0000-4000-8000-000000000001',null,25,0);
  raise exception 'Cross-tenant stock read accepted';
 exception when insufficient_privilege then null; end;
end $$;
rollback;
