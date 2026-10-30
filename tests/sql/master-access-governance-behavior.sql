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

do $test$
declare
  event_count integer;
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
