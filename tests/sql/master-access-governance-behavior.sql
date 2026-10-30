begin;

insert into auth.users (id, email, email_confirmed_at) values
  ('71000000-0000-4000-8000-000000000001', 'master@example.test', clock_timestamp()),
  ('71000000-0000-4000-8000-000000000002', 'common@example.test', clock_timestamp());
insert into app_private.master_admins (
  user_id, status, authorized_by_user_id, authorization_reason, approval_reference
)
values (
  '71000000-0000-4000-8000-000000000001', 'active',
  '71000000-0000-4000-8000-000000000001', 'isolated governance test', 'TEST-GOV-01'
);
insert into public.access_role_definitions (role_key, display_name, scope)
values ('company_owner', 'Proprietário empresarial', 'company')
on conflict (role_key) do nothing;
insert into public.companies (id, legal_name) values
  ('72000000-0000-4000-8000-000000000001', 'Company Access A'),
  ('72000000-0000-4000-8000-000000000002', 'Company Access B');

do $test$
declare
  event_count integer;
  migo_permission text;
  module_enabled boolean;
  transaction_enabled boolean;
begin
  perform set_config('request.jwt.claim.role', 'authenticated', true);
  perform set_config('request.jwt.claim.sub', '71000000-0000-4000-8000-000000000002', true);
  begin
    perform public.master_set_access_catalog_approval('role', 'company_owner', 'approved');
    raise exception 'non-master approved a catalog item';
  exception when insufficient_privilege then null;
  end;

  perform set_config('request.jwt.claim.sub', '71000000-0000-4000-8000-000000000001', true);
  if public.master_set_access_catalog_approval('role', 'company_owner', 'approved') <> 'approved' then
    raise exception 'master role approval failed';
  end if;
  if public.master_set_access_catalog_approval('permission', 'transaction.inventory.stock.read', 'approved') <> 'approved' then
    raise exception 'master permission approval failed';
  end if;
  if public.master_set_access_catalog_approval('transaction', 'MIGO', 'approved') <> 'approved' then
    raise exception 'master transaction approval failed';
  end if;
  select permission_key into migo_permission from public.erp_transaction_authorization_catalog where transaction_code='MIGO';
  if public.master_set_access_catalog_approval('permission', migo_permission, 'approved') <> 'approved' then
    raise exception 'permission associated with MIGO approval failed';
  end if;
  if public.master_set_company_transaction_availability('72000000-0000-4000-8000-000000000001', array['MIGO']) <> 'updated' then
    raise exception 'company transaction availability update failed';
  end if;
  if not public.authorize_company_transaction('72000000-0000-4000-8000-000000000001', '73000000-0000-4000-8000-000000000001', 'MIGO') then
    raise exception 'approved and enabled transaction was not authorized';
  end if;
  if exists (select 1 from public.company_transaction_availability where tenant_id='72000000-0000-4000-8000-000000000002') then
    raise exception 'company availability leaked to another company';
  end if;
  if public.master_set_company_transaction_availability('72000000-0000-4000-8000-000000000001', array[]::text[]) <> 'updated' then
    raise exception 'company transaction revocation RPC failed';
  end if;
  select enabled into module_enabled from public.company_module_availability where tenant_id='72000000-0000-4000-8000-000000000001' and module_code='INV';
  select enabled into transaction_enabled from public.company_transaction_availability where tenant_id='72000000-0000-4000-8000-000000000001' and transaction_code='MIGO';
  if public.authorize_company_transaction('72000000-0000-4000-8000-000000000001', '73000000-0000-4000-8000-000000000001', 'MIGO') then
    raise exception 'company transaction revocation failed: module=%, transaction=%', module_enabled, transaction_enabled;
  end if;
  begin
    perform public.master_set_company_transaction_availability('72000000-0000-4000-8000-000000000001', array['BP01']);
    raise exception 'pending transaction became company eligible';
  exception when invalid_parameter_value then null;
  end;
  if public.master_set_role_permission_grant('company_owner', 'transaction.inventory.stock.read', 'grant') <> 'grant' then
    raise exception 'master role grant failed';
  end if;
  if public.master_set_role_permission_grant('company_owner', 'transaction.inventory.stock.read', 'grant') <> 'unchanged' then
    raise exception 'idempotent role grant failed';
  end if;
  if public.master_set_role_permission_grant('company_owner', 'transaction.inventory.stock.read', 'revoke') <> 'revoke' then
    raise exception 'master role revoke failed';
  end if;
  if exists (select 1 from public.role_permission_grants where role_key='company_owner' and permission_key='transaction.inventory.stock.read') then
    raise exception 'role grant persisted after revocation';
  end if;
  select count(*) into event_count
  from app_private.provisioning_audit_events
  where actor_user_id='71000000-0000-4000-8000-000000000001'
    and event_key in ('master_access_catalog.approval_changed','master_role_permission.grant','master_role_permission.revoke');
  if event_count < 5 then raise exception 'expected Master governance audit events'; end if;
end;
$test$;

rollback;
