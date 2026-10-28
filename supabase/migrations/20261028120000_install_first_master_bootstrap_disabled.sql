-- Installs a disabled, one-time first-Master bootstrap mechanism.
-- This migration deliberately creates NO authorization record and NO Master grant.
-- A later, separately approved private operator action must record the approved
-- Auth UUID and formal approval reference before the RPC can ever succeed.

begin;

do $$
declare
  required_function oid;
begin
  if current_user <> 'postgres' then
    raise exception 'Apply this migration as postgres so SECURITY DEFINER ownership is explicit';
  end if;

  if exists (
    select 1 from pg_catalog.pg_proc p
    join pg_catalog.pg_namespace n on n.oid = p.pronamespace
    where n.nspname = 'public' and p.proname = 'bootstrap_first_master'
      and p.pronargs = 0
  ) then
    raise exception 'public.bootstrap_first_master() already exists';
  end if;

  if exists (select 1 from app_private.master_admins)
     or exists (select 1 from app_private.master_admin_audit_events) then
    raise exception 'First-Master bootstrap installation requires no prior Master grant or audit history';
  end if;

  select p.oid into required_function
  from pg_catalog.pg_proc p
  join pg_catalog.pg_namespace n on n.oid = p.pronamespace
  where n.nspname = 'app_private' and p.proname = 'audit_master_admin_change'
    and p.pronargs = 0;
  if required_function is null
     or not exists (
       select 1 from pg_catalog.pg_proc p
       where p.oid = required_function
         and p.prosecdef
         and p.proowner = 'postgres'::regrole
         and coalesce(array_to_string(p.proconfig, ','), '') like '%search_path=""%'
         and coalesce(array_to_string(p.proconfig, ','), '') like '%row_security=off%'
     ) then
    raise exception 'Required Master audit function security contract is absent';
  end if;

  if not exists (
    select 1 from pg_catalog.pg_trigger t
    where t.tgrelid = 'app_private.master_admins'::regclass
      and t.tgname = 'master_admins_guard_change' and t.tgenabled = 'O'
      and not t.tgisinternal
  ) or not exists (
    select 1 from pg_catalog.pg_trigger t
    where t.tgrelid = 'app_private.master_admins'::regclass
      and t.tgname = 'master_admins_audit_change' and t.tgenabled = 'O'
      and not t.tgisinternal
  ) then
    raise exception 'Required Master guard or audit trigger is absent or disabled';
  end if;
end;
$$;

create table app_private.first_master_bootstrap_authorization (
  singleton boolean primary key default true check (singleton),
  target_user_id uuid not null references auth.users(id) on delete restrict,
  approval_reference text not null check (length(pg_catalog.btrim(approval_reference)) > 0),
  authorization_reason text not null check (length(pg_catalog.btrim(authorization_reason)) > 0),
  enabled boolean not null default false,
  created_at timestamptz not null default clock_timestamp(),
  enabled_at timestamptz
);

alter table app_private.first_master_bootstrap_authorization enable row level security;
alter table app_private.first_master_bootstrap_authorization force row level security;
alter table app_private.first_master_bootstrap_authorization owner to postgres;
revoke all on table app_private.first_master_bootstrap_authorization
  from public, anon, authenticated, service_role;

comment on table app_private.first_master_bootstrap_authorization is
  'Private, empty-by-default, one-time authorization control for the first Admin Master. No API access.';

create function public.is_current_first_master_bootstrap_candidate()
returns boolean
language plpgsql
stable
security definer
set search_path = ''
set row_security = off
as $$
declare
  caller_id uuid;
begin
  caller_id := auth.uid();
  if caller_id is null then
    return false;
  end if;

  return not exists (select 1 from app_private.master_admins)
    and not exists (select 1 from app_private.master_admin_audit_events)
    and exists (
      select 1
      from app_private.first_master_bootstrap_authorization a
      where a.singleton
        and a.enabled
        and a.target_user_id = caller_id
    );
exception when others then
  return false;
end;
$$;

create function public.bootstrap_first_master()
returns void
language plpgsql
security definer
set search_path = ''
set row_security = off
as $$
declare
  caller_id uuid;
  approved_user_id uuid;
  approved_reference text;
  approved_reason text;
  audit_events integer;
begin
  caller_id := auth.uid();
  if caller_id is null then
    raise exception 'An authenticated session is required' using errcode = '28000';
  end if;

  lock table app_private.master_admins in exclusive mode;

  if exists (select 1 from app_private.master_admins)
     or exists (select 1 from app_private.master_admin_audit_events) then
    raise exception 'First Master bootstrap has already been consumed or history exists' using errcode = '55000';
  end if;

  select a.target_user_id, a.approval_reference, a.authorization_reason
    into approved_user_id, approved_reference, approved_reason
  from app_private.first_master_bootstrap_authorization a
  where a.singleton and a.enabled
  for share;

  if not found then
    raise exception 'First Master bootstrap is not enabled' using errcode = '55000';
  end if;
  if approved_user_id is distinct from caller_id then
    raise exception 'The authenticated user is not approved for the first Master grant' using errcode = '42501';
  end if;

  insert into app_private.master_admins (
    user_id, status, authorized_by_user_id, authorization_reason, approval_reference
  ) values (
    caller_id, 'active', caller_id, approved_reason, approved_reference
  );

  select count(*) into audit_events
  from app_private.master_admin_audit_events
  where subject_user_id = caller_id
    and event_key = 'master.granted'
    and new_status = 'active'
    and approval_reference = approved_reference;
  if audit_events <> 1 then
    raise exception 'First Master audit contract failed' using errcode = '55000';
  end if;
end;
$$;

alter function public.is_current_first_master_bootstrap_candidate() owner to postgres;
alter function public.bootstrap_first_master() owner to postgres;
revoke all on function public.is_current_first_master_bootstrap_candidate()
  from public, anon, authenticated, service_role;
revoke all on function public.bootstrap_first_master()
  from public, anon, authenticated, service_role;
grant usage on schema public to authenticated;
grant execute on function public.is_current_first_master_bootstrap_candidate() to authenticated;
grant execute on function public.bootstrap_first_master() to authenticated;

commit;
