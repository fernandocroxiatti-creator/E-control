begin;

do $test$
declare
  tenant_a constant uuid := 'e2000000-0000-4000-8000-000000000001';
  tenant_b constant uuid := 'e2000000-0000-4000-8000-000000000002';
  branch_a constant uuid := 'e3000000-0000-4000-8000-000000000001';
  branch_b constant uuid := 'e3000000-0000-4000-8000-000000000002';
  master_user constant uuid := 'e1000000-0000-4000-8000-000000000001';
  owner_a constant uuid := 'e1000000-0000-4000-8000-000000000002';
  listed_company_grants integer;
  listed_branch_grants integer;
begin
  if exists (select 1 from public.role_permission_grants where permission_key like 'transaction.%') then
    raise exception 'legacy global operational grants remained after transition';
  end if;

  if not exists (
    select 1 from public.company_role_permission_grants
    where tenant_id = tenant_a and branch_id is null and grant_scope = 'company'
      and role_key = 'company_owner' and permission_key = 'transaction.masterdata.party.manage'
  ) then
    raise exception 'legacy company-scope grant was not materialized';
  end if;
  if not exists (
    select 1 from public.company_role_permission_grants
    where tenant_id = tenant_a and branch_id = branch_a and grant_scope = 'branch'
      and role_key = 'company_owner' and permission_key = 'transaction.inventory.stock.read'
  ) then
    raise exception 'legacy branch-scope grant was not materialized';
  end if;
  if not exists (
    select 1 from app_private.provisioning_audit_events
    where event_key = 'master_legacy_global_grant.materialized' and tenant_id = tenant_a
  ) then
    raise exception 'legacy grant materialization is missing audit evidence';
  end if;

  perform set_config('request.jwt.claim.role', 'authenticated', true);
  perform set_config('request.jwt.claim.sub', owner_a::text, true);
  if not app_private.has_tenant_permission(tenant_a, 'transaction.masterdata.party.manage')
    or not app_private.has_tenant_permission(tenant_a, 'transaction.masterdata.party.manage', branch_a)
    or app_private.has_tenant_permission(tenant_b, 'transaction.masterdata.party.manage')
    or app_private.has_tenant_permission(tenant_a, 'transaction.inventory.stock.read', branch_b) then
    raise exception 'transition changed the effective company or branch boundaries';
  end if;

  perform set_config('request.jwt.claim.sub', master_user::text, true);
  if public.master_set_company_role_permission_grant(
    tenant_a, null, 'company_owner', 'transaction.masterdata.party.manage', 'grant', 'Company-scoped grant idempotency verification'
  ) <> 'unchanged' then
    raise exception 'company scoped grant did not preserve idempotency';
  end if;
  begin
    perform public.master_set_company_role_permission_grant(
      tenant_a, branch_a, 'company_owner', 'transaction.masterdata.party.manage', 'grant', 'Company grant supplied with a branch must fail'
    );
    raise exception 'company scoped permission accepted a branch';
  exception when invalid_parameter_value then null;
  end;
  begin
    perform public.master_set_company_role_permission_grant(
      tenant_a, null, 'company_owner', 'transaction.inventory.stock.read', 'grant', 'Branch grant supplied without branch must fail'
    );
    raise exception 'branch scoped permission accepted no branch';
  exception when invalid_parameter_value then null;
  end;
  begin
    perform public.master_set_role_permission_grant(
      'company_owner', 'transaction.masterdata.party.manage', 'grant', 'Global operational grant must remain prohibited'
    );
    raise exception 'global operational grant was accepted after transition';
  exception when object_not_in_prerequisite_state then null;
  end;

  select count(*) into listed_company_grants
  from public.master_list_company_scoped_permission_grants(tenant_a)
  where grant_scope = 'company' and branch_id is null;
  select count(*) into listed_branch_grants
  from public.master_list_company_scoped_permission_grants(tenant_a)
  where grant_scope = 'branch' and branch_id is not null;
  if listed_company_grants < 1 or listed_branch_grants < 1 then
    raise exception 'Master read model did not expose both operational grant scopes';
  end if;
end;
$test$;

rollback;
