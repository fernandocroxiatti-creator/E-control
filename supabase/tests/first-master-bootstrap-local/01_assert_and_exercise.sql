-- Local synthetic test only. It never refers to a Production identity.
insert into auth.users (id) values
  ('10000000-0000-4000-8000-000000000001'),
  ('20000000-0000-4000-8000-000000000002');

do $install$
declare
  bootstrap oid := 'public.bootstrap_first_master()'::regprocedure;
  candidate oid := 'public.is_current_first_master_bootstrap_candidate()'::regprocedure;
begin
  if exists (select 1 from app_private.master_admins)
     or exists (select 1 from app_private.master_admin_audit_events)
     or exists (select 1 from app_private.first_master_bootstrap_authorization) then
    raise exception 'Installer created grants, audits, or an authorization row';
  end if;
  if not (select relrowsecurity and relforcerowsecurity from pg_class where oid = 'app_private.first_master_bootstrap_authorization'::regclass) then
    raise exception 'Private control table must use FORCE RLS';
  end if;
  if has_function_privilege('anon', bootstrap, 'EXECUTE')
     or has_function_privilege('service_role', bootstrap, 'EXECUTE')
     or not has_function_privilege('authenticated', bootstrap, 'EXECUTE')
     or has_function_privilege('public'::name, bootstrap, 'EXECUTE') then
    raise exception 'Bootstrap EXECUTE ACL is unsafe';
  end if;
  if not (select prosecdef and proowner = 'postgres'::regrole
          and exists (select 1 from unnest(proconfig) value where value = 'search_path=""')
          and exists (select 1 from unnest(proconfig) value where value = 'row_security=off')
          from pg_proc where oid = bootstrap) then
    raise exception 'Bootstrap security settings are unsafe';
  end if;
  if not (select prosecdef and proowner = 'postgres'::regrole
          from pg_proc where oid = candidate) then
    raise exception 'Candidate helper security settings are unsafe';
  end if;
end;
$install$;

set role authenticated;
set request.jwt.claim.sub = '10000000-0000-4000-8000-000000000001';
set request.jwt.claim.role = 'authenticated';
do $disabled$
begin
  if public.is_current_first_master_bootstrap_candidate() then
    raise exception 'Empty installer must not approve any caller';
  end if;
  begin
    perform public.bootstrap_first_master();
    raise exception 'Disabled bootstrap unexpectedly granted Master';
  exception when sqlstate '55000' then null;
  end;
end;
$disabled$;
reset role;

set role authenticated;
reset request.jwt.claim.sub;
reset request.jwt.claim.role;
do $no_session$
begin
  begin
    perform public.bootstrap_first_master();
    raise exception 'Missing synthetic Auth session granted Master';
  exception when sqlstate '28000' then null;
  end;
end;
$no_session$;
reset role;

-- Simulates only the separately approved private authorization action in this disposable DB.
insert into app_private.first_master_bootstrap_authorization (
  target_user_id, approval_reference, authorization_reason, enabled, enabled_at
) values (
  '10000000-0000-4000-8000-000000000001', 'LOCAL-TEST-APPROVAL', 'local test', true, clock_timestamp()
);

set role authenticated;
set request.jwt.claim.sub = '20000000-0000-4000-8000-000000000002';
set request.jwt.claim.role = 'authenticated';
do $wrong_identity$
begin
  if public.is_current_first_master_bootstrap_candidate() then
    raise exception 'Wrong synthetic identity was approved';
  end if;
  begin
    perform public.bootstrap_first_master();
    raise exception 'Wrong synthetic identity granted Master';
  exception when sqlstate '42501' then null;
  end;
end;
$wrong_identity$;
reset role;

set role authenticated;
set request.jwt.claim.sub = '10000000-0000-4000-8000-000000000001';
set request.jwt.claim.role = 'authenticated';
select public.bootstrap_first_master();
reset role;

do $result$
begin
  if (select count(*) from app_private.master_admins) <> 1
     or (select count(*) from app_private.master_admin_audit_events where event_key = 'master.granted') <> 1 then
    raise exception 'Expected exactly one atomic Master grant and audit event';
  end if;
end;
$result$;
