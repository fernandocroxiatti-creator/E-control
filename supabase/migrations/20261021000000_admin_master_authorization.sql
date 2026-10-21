-- Permanent Admin Master authorization for eControl.
--
-- This migration creates no administrator assignment and changes no Auth
-- metadata. Permanent Master authorization is stored privately by Auth UUID;
-- temporary tenant/provisioning authorizations remain separate.
--
-- The only Data API surface is public.is_current_user_master(): a zero-argument,
-- read-only function returning the caller's own authorization bit. It is
-- executable only by authenticated and derives identity from auth.uid(). The
-- app should call it through its server-side Supabase SSR client after
-- auth.getUser(); an RPC error must be treated as denial. Do not cache the
-- result across requests or use app_metadata as the authorization source.
--
-- supabase/config.toml currently exposes public and graphql_public, not
-- app_private. This migration does not change Data API configuration. Before
-- applying remotely, confirm the remote API exposes public; if it does not,
-- obtain separate approval before changing that remote configuration.
--
-- This migration does not repair the separate provisioning functions' trust
-- contract around p_actor_user_id; those functions must not be called by a
-- backend that accepts the actor UUID from the browser.
--
-- Future bootstrap (not performed here): an authorized database operator must
-- independently match the intended existing Auth identity to its UUID, obtain
-- the owner's explicit approval for that UUID, then insert one active row with
-- the approver UUID, non-empty reason, and approval reference. The audit event
-- records the database session separately; do not represent a SQL-editor
-- session as an authenticated application user. Revocation is a one-way update
-- with the revoker UUID, reason, and approval reference. Re-grant after
-- revocation requires a new row and a new approval; prior rows remain intact.

begin;

do $$
begin
  if not exists (
    select 1 from pg_catalog.pg_namespace where nspname = 'app_private'
  ) then
    raise exception 'Required schema app_private does not exist';
  end if;
  if not exists (
    select 1 from pg_catalog.pg_roles where rolname = 'postgres'
  ) then
    raise exception 'Required owner role postgres does not exist';
  end if;
  if current_user <> 'postgres' then
    raise exception 'Apply this migration as postgres so SECURITY DEFINER ownership is explicit';
  end if;
end;
$$;

create table app_private.master_admins (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references auth.users(id) on delete restrict,
  status text not null check (status in ('active', 'revoked')),
  granted_at timestamptz not null default clock_timestamp(),
  authorized_by_user_id uuid not null references auth.users(id) on delete restrict,
  authorization_reason text not null
    check (length(pg_catalog.btrim(authorization_reason)) > 0),
  approval_reference text not null
    check (length(pg_catalog.btrim(approval_reference)) > 0),
  revoked_at timestamptz,
  revoked_by_user_id uuid references auth.users(id) on delete restrict,
  revocation_reason text,
  revocation_reference text,
  constraint master_admins_revocation_state_check check (
    (status = 'active'
      and revoked_at is null
      and revoked_by_user_id is null
      and revocation_reason is null
      and revocation_reference is null)
    or
    (status = 'revoked'
      and revoked_at is not null
      and revoked_by_user_id is not null
      and revocation_reason is not null
      and length(pg_catalog.btrim(revocation_reason)) > 0
      and revocation_reference is not null
      and length(pg_catalog.btrim(revocation_reference)) > 0)
  )
);

create unique index master_admins_one_active_grant_per_user
  on app_private.master_admins (user_id)
  where status = 'active';
create index master_admins_user_history_idx
  on app_private.master_admins (user_id, granted_at desc);

create table app_private.master_admin_audit_events (
  id uuid primary key default gen_random_uuid(),
  master_admin_id uuid not null
    references app_private.master_admins(id) on delete restrict,
  subject_user_id uuid not null references auth.users(id) on delete restrict,
  event_key text not null check (event_key in ('master.granted', 'master.revoked')),
  actor_auth_user_id uuid,
  actor_database_session_user text not null,
  actor_database_current_user text not null,
  actor_api_role text,
  responsible_user_id uuid not null references auth.users(id) on delete restrict,
  reason text not null check (length(pg_catalog.btrim(reason)) > 0),
  approval_reference text not null
    check (length(pg_catalog.btrim(approval_reference)) > 0),
  old_status text,
  new_status text not null check (new_status in ('active', 'revoked')),
  details jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default clock_timestamp()
);

alter table app_private.master_admins enable row level security;
alter table app_private.master_admins force row level security;
alter table app_private.master_admin_audit_events enable row level security;
alter table app_private.master_admin_audit_events force row level security;

revoke all on table app_private.master_admins,
  app_private.master_admin_audit_events
  from public, anon, authenticated, service_role;

comment on table app_private.master_admins is
  'Permanent Admin Master grants keyed by auth.users UUID. No Data API DML.';
comment on table app_private.master_admin_audit_events is
  'Append-only audit trail for permanent Admin Master grants and revocations.';

create or replace function app_private.guard_master_admin_change()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  if tg_op = 'DELETE' then
    raise exception 'Master authorization history cannot be deleted'
      using errcode = '55000';
  end if;

  if tg_op = 'INSERT' and new.status <> 'active' then
    raise exception 'A new Master authorization must start active'
      using errcode = '23514';
  end if;

  if tg_op = 'UPDATE' then
    if old.status <> 'active' or new.status <> 'revoked'
      or new.id is distinct from old.id
      or new.user_id is distinct from old.user_id
      or new.granted_at is distinct from old.granted_at
      or new.authorized_by_user_id is distinct from old.authorized_by_user_id
      or new.authorization_reason is distinct from old.authorization_reason
      or new.approval_reference is distinct from old.approval_reference then
      raise exception 'Only one-way active-to-revoked transition is allowed'
        using errcode = '55000';
    end if;
  end if;

  return new;
end;
$$;

create trigger master_admins_guard_change
before insert or update or delete on app_private.master_admins
for each row execute function app_private.guard_master_admin_change();

create or replace function app_private.audit_master_admin_change()
returns trigger
language plpgsql
security definer
set search_path = ''
set row_security = off
as $$
declare
  change_user_id uuid;
  change_reason text;
  change_reference text;
  change_event text;
  previous_status text;
begin
  if tg_op = 'INSERT' then
    if new.status <> 'active' then
      raise exception 'A grant audit event requires an active authorization'
        using errcode = '23514';
    end if;
    change_user_id := new.authorized_by_user_id;
    change_reason := new.authorization_reason;
    change_reference := new.approval_reference;
    change_event := 'master.granted';
    previous_status := null;
  elsif tg_op = 'UPDATE' and old.status = 'active' and new.status = 'revoked' then
    change_user_id := new.revoked_by_user_id;
    change_reason := new.revocation_reason;
    change_reference := new.revocation_reference;
    change_event := 'master.revoked';
    previous_status := old.status;
  else
    raise exception 'Unsupported Master authorization audit transition'
      using errcode = '55000';
  end if;

  insert into app_private.master_admin_audit_events (
    master_admin_id,
    subject_user_id,
    event_key,
    actor_auth_user_id,
    actor_database_session_user,
    actor_database_current_user,
    actor_api_role,
    responsible_user_id,
    reason,
    approval_reference,
    old_status,
    new_status,
    details
  ) values (
    new.id,
    new.user_id,
    change_event,
    auth.uid(),
    session_user::text,
    current_user::text,
    nullif(auth.role(), ''),
    change_user_id,
    change_reason,
    change_reference,
    previous_status,
    new.status,
    pg_catalog.jsonb_build_object('grant_id', new.id)
  );

  return new;
end;
$$;

create trigger master_admins_audit_change
after insert or update on app_private.master_admins
for each row execute function app_private.audit_master_admin_change();

create or replace function app_private.prevent_master_audit_mutation()
returns trigger
language plpgsql
set search_path = pg_catalog
as $$
begin
  raise exception 'Master authorization audit is append-only'
    using errcode = '55000';
end;
$$;

create trigger master_admin_audit_append_only
before update or delete on app_private.master_admin_audit_events
for each row execute function app_private.prevent_master_audit_mutation();

-- This public-schema wrapper is the only API-visible authorization surface.
-- It accepts no identity input and reveals no role row or tenant data.
create or replace function public.is_current_user_master()
returns boolean
language plpgsql
stable
security definer
set search_path = ''
set row_security = off
as $$
declare
  current_user_id uuid;
begin
  current_user_id := auth.uid();
  if current_user_id is null then
    return false;
  end if;

  return exists (
    select 1
    from app_private.master_admins as master_grant
    where master_grant.user_id = current_user_id
      and master_grant.status = 'active'
  );
exception
  when others then
    -- Any database error becomes a denial; application RPC errors must also
    -- be handled as denial rather than falling back to metadata or email.
    return false;
end;
$$;

alter table app_private.master_admins owner to postgres;
alter table app_private.master_admin_audit_events owner to postgres;
alter function app_private.guard_master_admin_change() owner to postgres;
alter function app_private.audit_master_admin_change() owner to postgres;
alter function app_private.prevent_master_audit_mutation() owner to postgres;
alter function public.is_current_user_master() owner to postgres;

revoke all on function app_private.guard_master_admin_change()
  from public, anon, authenticated, service_role;
revoke all on function app_private.audit_master_admin_change()
  from public, anon, authenticated, service_role;
revoke all on function app_private.prevent_master_audit_mutation()
  from public, anon, authenticated, service_role;
revoke all on function public.is_current_user_master()
  from public, anon, authenticated, service_role;
grant usage on schema public to authenticated;
grant execute on function public.is_current_user_master() to authenticated;

commit;
