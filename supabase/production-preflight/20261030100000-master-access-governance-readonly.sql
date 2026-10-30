-- Read-only preflight for Production wlqsjwofypqxwleacsvh.
-- No data rows or identities are selected.
select jsonb_build_object(
  'database', current_database(),
  'server_version_num', current_setting('server_version_num'),
  'required_tables', jsonb_build_object(
    'access_role_definitions', to_regclass('public.access_role_definitions') is not null,
    'permission_definitions', to_regclass('public.permission_definitions') is not null,
    'role_permission_grants', to_regclass('public.role_permission_grants') is not null,
    'transaction_catalog', to_regclass('public.erp_transaction_authorization_catalog') is not null,
    'provisioning_audit_events', to_regclass('app_private.provisioning_audit_events') is not null
  ),
  'required_functions', jsonb_build_object(
    'assert_current_master', to_regprocedure('app_private.assert_current_master()') is not null,
    'write_provisioning_audit', to_regprocedure('app_private.write_provisioning_audit(text,uuid,uuid,uuid,jsonb)') is not null,
    'is_current_user_master', to_regprocedure('public.is_current_user_master()') is not null
  ),
  'governance_objects_absent', jsonb_build_object(
    'master_set_access_catalog_approval', to_regprocedure('public.master_set_access_catalog_approval(text,text,text)') is null,
    'master_set_role_permission_grant', to_regprocedure('public.master_set_role_permission_grant(text,text,text)') is null,
    'master_list_access_control_matrix', to_regprocedure('public.master_list_access_control_matrix()') is null
  ),
  'authorization_catalog_rls_forced', (
    select bool_and(relrowsecurity and relforcerowsecurity)
    from pg_class
    where oid in (
      'public.access_role_definitions'::regclass,
      'public.permission_definitions'::regclass,
      'public.role_permission_grants'::regclass,
      'public.erp_transaction_authorization_catalog'::regclass
    )
  ),
  'effective_role_permission_grants', (select count(*) from public.role_permission_grants),
  'approved_roles', (select count(*) from public.access_role_definitions where approval_state = 'approved'),
  'approved_permissions', (select count(*) from public.permission_definitions where approval_state = 'approved'),
  'approved_transactions', (select count(*) from public.erp_transaction_authorization_catalog where approval_state = 'approved')
)::text;
