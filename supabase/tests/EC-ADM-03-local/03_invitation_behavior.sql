begin;

insert into auth.users (id, email, email_confirmed_at) values
  ('10000000-0000-4000-8000-000000000001', 'master.synthetic@example.invalid', pg_catalog.now()),
  ('10000000-0000-4000-8000-000000000002', 'first.admin@example.invalid', pg_catalog.now()),
  ('10000000-0000-4000-8000-000000000003', 'other.identity@example.invalid', pg_catalog.now()),
  ('10000000-0000-4000-8000-000000000004', 'revoked.admin@example.invalid', pg_catalog.now()),
  ('10000000-0000-4000-8000-000000000005', 'expired.admin@example.invalid', pg_catalog.now()),
  ('10000000-0000-4000-8000-000000000006', 'sweep.admin@example.invalid', pg_catalog.now());

insert into public.companies (id, legal_name, status) values
  ('20000000-0000-4000-8000-000000000001', 'Synthetic Company A', 'active'),
  ('20000000-0000-4000-8000-000000000002', 'Synthetic Company B', 'active'),
  ('20000000-0000-4000-8000-000000000003', 'Synthetic Company C', 'active'),
  ('20000000-0000-4000-8000-000000000004', 'Synthetic Company D', 'active');

update public.access_role_definitions
set approval_state = 'approved'
where role_key = 'company_owner' and scope = 'company';

insert into app_private.master_admins (
  user_id, status, authorized_by_user_id, authorization_reason, approval_reference
) values (
  '10000000-0000-4000-8000-000000000001', 'active',
  '10000000-0000-4000-8000-000000000001', 'Synthetic local test only', 'EC-ADM-03-LOCAL-TEST'
);

do $test$
declare
  invitation_a uuid;
  token_a text;
  invitation_b uuid;
  token_b text;
  invitation_c uuid;
  token_c text;
  invitation_d uuid;
  token_d text;
  outcome_value text;
  tenant_value uuid;
  error_state text;
begin
  perform pg_catalog.set_config('request.jwt.claim.role', 'authenticated', true);
  perform pg_catalog.set_config('request.jwt.claim.sub', '10000000-0000-4000-8000-000000000001', true);
  if public.is_current_user_master() is distinct from true then
    raise exception 'synthetic Master session was not recognized';
  end if;

  -- A normal user cannot issue an invitation, even with a valid tenant ID.
  perform pg_catalog.set_config('request.jwt.claim.sub', '10000000-0000-4000-8000-000000000003', true);
  begin
    perform * from public.master_create_company_admin_invitation(
      '20000000-0000-4000-8000-000000000001', 'first.admin@example.invalid',
      '30000000-0000-4000-8000-000000000001'
    );
    raise exception 'ordinary user unexpectedly issued an invitation';
  exception when insufficient_privilege then
    null;
  end;
  if exists (select 1 from app_private.company_admin_invitations) then
    raise exception 'unauthorized attempt created an invitation';
  end if;

  -- Master creates an invite for Company A; tenant association is stored by DB.
  perform pg_catalog.set_config('request.jwt.claim.sub', '10000000-0000-4000-8000-000000000001', true);
  select created.invitation_id, created.invitation_token
    into invitation_a, token_a
  from public.master_create_company_admin_invitation(
    '20000000-0000-4000-8000-000000000001', 'first.admin@example.invalid',
    '30000000-0000-4000-8000-000000000002'
  ) as created;
  if token_a !~ '^[0-9a-f]{64}$' then raise exception 'issued token format invalid'; end if;
  if exists (
    select 1 from app_private.company_admin_invitations
    where id = invitation_a and token_digest = pg_catalog.sha256(pg_catalog.convert_to(token_a, 'UTF8'))
      and tenant_id = '20000000-0000-4000-8000-000000000002'
  ) then raise exception 'token crossed into Company B'; end if;

  -- Same invitation used by a different authenticated identity is rejected and remains pending.
  perform pg_catalog.set_config('request.jwt.claim.sub', '10000000-0000-4000-8000-000000000003', true);
  select accepted.outcome into outcome_value
  from public.accept_company_admin_invitation(token_a) as accepted;
  if outcome_value <> 'rejected' then raise exception 'wrong identity was not rejected'; end if;
  if (select status from app_private.company_admin_invitations where id = invitation_a) <> 'pending' then
    raise exception 'wrong identity changed invitation state';
  end if;
  if exists (select 1 from public.company_memberships where user_id = '10000000-0000-4000-8000-000000000003') then
    raise exception 'wrong identity acquired a membership';
  end if;

  -- Correct confirmed identity accepts; the membership is bound only to Company A.
  perform pg_catalog.set_config('request.jwt.claim.sub', '10000000-0000-4000-8000-000000000002', true);
  select accepted.outcome, accepted.tenant_id into outcome_value, tenant_value
  from public.accept_company_admin_invitation(token_a) as accepted;
  if outcome_value <> 'accepted' or tenant_value <> '20000000-0000-4000-8000-000000000001' then
    raise exception 'authorized acceptance failed or returned a different tenant';
  end if;
  if (select count(*) from public.company_memberships
      where user_id = '10000000-0000-4000-8000-000000000002'
        and tenant_id = '20000000-0000-4000-8000-000000000001' and status = 'active') <> 1
     or exists (select 1 from public.company_memberships
      where user_id = '10000000-0000-4000-8000-000000000002'
        and tenant_id <> '20000000-0000-4000-8000-000000000001') then
    raise exception 'membership tenant isolation failed';
  end if;
  if (select count(*) from public.membership_role_assignments assignment
      join public.company_memberships membership on membership.id = assignment.membership_id
      where membership.user_id = '10000000-0000-4000-8000-000000000002'
        and assignment.role_key = 'company_owner' and assignment.branch_id is null) <> 1 then
    raise exception 'fixed company role was not assigned exactly once';
  end if;
  if public.is_current_user_master() is distinct from false then
    raise exception 'company administrator was promoted to Master';
  end if;
  if app_private.has_tenant_permission(
      '20000000-0000-4000-8000-000000000001', 'tenant.read', null
    ) is distinct from false then
    raise exception 'invitation granted an unapproved company permission';
  end if;

  -- Replay is rejected and creates neither a second membership nor audit event.
  select accepted.outcome into outcome_value
  from public.accept_company_admin_invitation(token_a) as accepted;
  if outcome_value <> 'rejected' then raise exception 'replayed invitation was not rejected'; end if;
  if (select count(*) from public.company_memberships where user_id = '10000000-0000-4000-8000-000000000002') <> 1 then
    raise exception 'replay created another membership';
  end if;

  -- A pending invitation for Company B cannot be accepted by another identity,
  -- then the Master revokes it and the recipient remains unlinked.
  perform pg_catalog.set_config('request.jwt.claim.sub', '10000000-0000-4000-8000-000000000001', true);
  select created.invitation_id, created.invitation_token into invitation_b, token_b
  from public.master_create_company_admin_invitation(
    '20000000-0000-4000-8000-000000000002', 'revoked.admin@example.invalid',
    '30000000-0000-4000-8000-000000000003'
  ) as created;
  perform pg_catalog.set_config('request.jwt.claim.sub', '10000000-0000-4000-8000-000000000002', true);
  select accepted.outcome into outcome_value from public.accept_company_admin_invitation(token_b) as accepted;
  if outcome_value <> 'rejected' then raise exception 'cross-identity/company token use was accepted'; end if;
  perform pg_catalog.set_config('request.jwt.claim.sub', '10000000-0000-4000-8000-000000000001', true);
  if public.master_revoke_company_admin_invitation(invitation_b) <> 'revoked' then
    raise exception 'Master could not revoke a pending invitation';
  end if;
  perform pg_catalog.set_config('request.jwt.claim.sub', '10000000-0000-4000-8000-000000000004', true);
  select accepted.outcome into outcome_value from public.accept_company_admin_invitation(token_b) as accepted;
  if outcome_value <> 'rejected' or exists (
    select 1 from public.company_memberships where user_id = '10000000-0000-4000-8000-000000000004'
  ) then raise exception 'revoked invitation was usable'; end if;

  -- Expiration is persisted and audited when the expired bearer is presented.
  perform pg_catalog.set_config('request.jwt.claim.sub', '10000000-0000-4000-8000-000000000001', true);
  select created.invitation_id, created.invitation_token into invitation_c, token_c
  from public.master_create_company_admin_invitation(
    '20000000-0000-4000-8000-000000000003', 'expired.admin@example.invalid',
    '30000000-0000-4000-8000-000000000004'
  ) as created;
  update app_private.company_admin_invitations
  set created_at = pg_catalog.now() - interval '8 days', expires_at = pg_catalog.now() - interval '1 day'
  where id = invitation_c;
  perform pg_catalog.set_config('request.jwt.claim.sub', '10000000-0000-4000-8000-000000000005', true);
  select accepted.outcome into outcome_value from public.accept_company_admin_invitation(token_c) as accepted;
  if outcome_value <> 'expired' or
    (select status from app_private.company_admin_invitations where id = invitation_c) <> 'expired' then
    raise exception 'expired invitation was not rejected and persisted';
  end if;

  perform pg_catalog.set_config('request.jwt.claim.sub', '10000000-0000-4000-8000-000000000001', true);
  select created.invitation_id, created.invitation_token into invitation_d, token_d
  from public.master_create_company_admin_invitation(
    '20000000-0000-4000-8000-000000000004', 'sweep.admin@example.invalid',
    '30000000-0000-4000-8000-000000000005'
  ) as created;
  update app_private.company_admin_invitations
  set created_at = pg_catalog.now() - interval '8 days', expires_at = pg_catalog.now() - interval '1 day'
  where id = invitation_d;
  if public.master_expire_company_admin_invitations('20000000-0000-4000-8000-000000000004') <> 1 then
    raise exception 'Master expiry sweep did not process exactly one invitation';
  end if;
  perform pg_catalog.set_config('request.jwt.claim.sub', '10000000-0000-4000-8000-000000000006', true);
  select accepted.outcome into outcome_value from public.accept_company_admin_invitation(token_d) as accepted;
  if outcome_value <> 'rejected' then raise exception 'swept expiration remained usable'; end if;

  -- Anonymous claims cannot accept, even when the token is syntactically valid.
  perform pg_catalog.set_config('request.jwt.claim.role', '', true);
  begin
    perform * from public.accept_company_admin_invitation(token_c);
    raise exception 'no-session caller unexpectedly reached acceptance';
  exception when insufficient_privilege then
    null;
  end;

  if (select count(*) from app_private.provisioning_audit_events
      where event_key = 'company_admin_invitation.issued') <> 4
     or (select count(*) from app_private.provisioning_audit_events
      where event_key = 'company_admin_invitation.accepted') <> 1
     or (select count(*) from app_private.provisioning_audit_events
      where event_key = 'company_admin_invitation.revoked') <> 1
     or (select count(*) from app_private.provisioning_audit_events
      where event_key = 'company_admin_invitation.expired') <> 2 then
    raise exception 'invitation audit event counts do not match expected lifecycle';
  end if;
  if (select count(*) from app_private.master_admins where status = 'active') <> 1 then
    raise exception 'invitation flow changed Master authorization state';
  end if;
end;
$test$;

rollback;
