begin;

insert into auth.users (id, email, email_confirmed_at) values
  ('81000000-0000-4000-8000-000000000001', 'master-read@example.test', clock_timestamp()),
  ('81000000-0000-4000-8000-000000000002', 'member-read@example.test', clock_timestamp()),
  ('81000000-0000-4000-8000-000000000003', 'other@example.test', clock_timestamp());
insert into public.user_profiles (user_id, display_name) values
  ('81000000-0000-4000-8000-000000000002', 'Membership test user');
insert into app_private.master_admins (user_id, status, authorized_by_user_id, authorization_reason, approval_reference)
values ('81000000-0000-4000-8000-000000000001', 'active', '81000000-0000-4000-8000-000000000001', 'isolated read API test', 'TEST-READ-01');
insert into public.companies (id, legal_name) values
  ('82000000-0000-4000-8000-000000000001', 'Read API Company A'),
  ('82000000-0000-4000-8000-000000000002', 'Read API Company B');
insert into public.branches (id, tenant_id, code, name) values
  ('83000000-0000-4000-8000-000000000001', '82000000-0000-4000-8000-000000000001', '001', 'Matriz');
insert into public.company_memberships (id, tenant_id, user_id, status, branch_access_mode, created_by_user_id)
values ('84000000-0000-4000-8000-000000000001', '82000000-0000-4000-8000-000000000001', '81000000-0000-4000-8000-000000000002', 'active', 'all_branches', '81000000-0000-4000-8000-000000000001');
insert into public.access_role_definitions (role_key, display_name, scope, approval_state)
values ('company_owner', 'Proprietário empresarial', 'company', 'approved')
on conflict (role_key) do update set approval_state = excluded.approval_state;
insert into public.permission_definitions (permission_key, description, approval_state)
values ('transaction.test.read', 'Read API test permission', 'approved')
on conflict (permission_key) do update set approval_state = excluded.approval_state;
insert into public.role_permission_grants (role_key, permission_key)
values ('company_owner', 'transaction.test.read')
on conflict do nothing;
insert into public.membership_role_assignments (tenant_id, membership_id, role_key, branch_id, assigned_by_user_id)
values ('82000000-0000-4000-8000-000000000001', '84000000-0000-4000-8000-000000000001', 'company_owner', null, '81000000-0000-4000-8000-000000000001');

do $test$
declare
  result jsonb;
begin
  perform set_config('request.jwt.claim.role', 'authenticated', true);
  perform set_config('request.jwt.claim.sub', '81000000-0000-4000-8000-000000000003', true);
  begin
    perform public.master_admin_list_membership_authorizations('82000000-0000-4000-8000-000000000001');
    raise exception 'non-master read access was accepted';
  exception when insufficient_privilege then null;
  end;

  perform set_config('request.jwt.claim.sub', '81000000-0000-4000-8000-000000000001', true);
  select jsonb_agg(jsonb_build_object('display_name', display_name, 'roles', roles)) into result
  from public.master_admin_list_membership_authorizations('82000000-0000-4000-8000-000000000001');
  if result <> jsonb_build_array(jsonb_build_object(
    'display_name', 'Membership test user',
    'roles', jsonb_build_array(jsonb_build_object(
      'role_key', 'company_owner',
      'display_name', 'Proprietário empresarial',
      'scope', 'company',
      'approval_state', 'approved',
      'branch_name', null,
      'granted_permission_keys', jsonb_build_array('transaction.test.read')
    ))
  )) then
    raise exception 'Master sanitized role/grant result does not match the assigned membership';
  end if;
  if exists (select 1 from public.master_admin_list_membership_authorizations('82000000-0000-4000-8000-000000000002')) then
    raise exception 'membership authorizations leaked between companies';
  end if;
  if has_function_privilege('anon', 'public.master_admin_list_membership_authorizations(uuid)', 'execute')
    or has_function_privilege('service_role', 'public.master_admin_list_membership_authorizations(uuid)', 'execute') then
    raise exception 'broad Master read API execute grant detected';
  end if;
end;
$test$;

rollback;
