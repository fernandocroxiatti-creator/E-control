-- eControl DEV-02: fundação local para identidade, tenants e acesso a filiais.
-- Destino futuro: Supabase PostgreSQL. Não aplicar em projeto remoto sem autorização.
-- Papéis/permissões sem aprovação ficam em estado pending_approval e sem grants.

begin;

create schema if not exists app_private;
revoke all on schema app_private from public, anon, authenticated, service_role;
grant usage on schema app_private to authenticated;

create table public.companies (
  id uuid primary key default gen_random_uuid(),
  legal_name text not null check (length(btrim(legal_name)) between 1 and 200),
  status text not null default 'active'
    check (status in ('active', 'suspended', 'closed')),
  created_at timestamptz not null default now()
);

create table public.branches (
  id uuid primary key default gen_random_uuid(),
  tenant_id uuid not null references public.companies(id) on delete restrict,
  code text not null check (length(btrim(code)) between 1 and 40),
  name text not null check (length(btrim(name)) between 1 and 160),
  status text not null default 'active' check (status in ('active', 'inactive')),
  created_at timestamptz not null default now(),
  constraint branches_tenant_id_id_unique unique (tenant_id, id),
  constraint branches_tenant_code_unique unique (tenant_id, code)
);

create table public.user_profiles (
  user_id uuid primary key references auth.users(id) on delete restrict,
  display_name text check (display_name is null or length(btrim(display_name)) <= 120),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create table public.company_memberships (
  id uuid primary key default gen_random_uuid(),
  tenant_id uuid not null references public.companies(id) on delete restrict,
  user_id uuid not null references auth.users(id) on delete restrict,
  status text not null default 'pending'
    check (status in ('pending', 'active', 'suspended', 'revoked')),
  -- Company-wide branch scope is an administrative grant, never self-service.
  -- Branch-level business semantics remain subject to owner approval.
  branch_access_mode text not null default 'assigned_only'
    check (branch_access_mode in ('assigned_only', 'all_branches')),
  created_by_user_id uuid not null references auth.users(id) on delete restrict,
  created_at timestamptz not null default now(),
  constraint company_memberships_tenant_user_unique unique (tenant_id, user_id),
  constraint company_memberships_tenant_id_id_unique unique (tenant_id, id)
);

create table public.branch_access (
  id uuid primary key default gen_random_uuid(),
  tenant_id uuid not null,
  branch_id uuid not null,
  membership_id uuid not null,
  status text not null default 'active'
    check (status in ('active', 'suspended', 'revoked')),
  granted_by_user_id uuid not null references auth.users(id) on delete restrict,
  created_at timestamptz not null default now(),
  constraint branch_access_tenant_branch_fk
    foreign key (tenant_id, branch_id)
    references public.branches(tenant_id, id) on delete restrict,
  constraint branch_access_tenant_membership_fk
    foreign key (tenant_id, membership_id)
    references public.company_memberships(tenant_id, id) on delete restrict,
  constraint branch_access_membership_branch_unique unique (membership_id, branch_id),
  constraint branch_access_tenant_id_id_unique unique (tenant_id, id)
);

-- These are an initial technical registry, not an approved business role catalog.
-- No role or permission is active or granted by this migration.
create table public.access_role_definitions (
  role_key text primary key check (role_key ~ '^[a-z][a-z0-9_]{1,63}$'),
  display_name text not null check (length(btrim(display_name)) between 1 and 100),
  scope text not null check (scope in ('company', 'branch')),
  approval_state text not null default 'pending_approval'
    check (approval_state in ('pending_approval', 'approved', 'retired')),
  created_at timestamptz not null default now()
);

create table public.permission_definitions (
  permission_key text primary key check (permission_key ~ '^[a-z][a-z0-9_.]{1,127}$'),
  description text not null,
  approval_state text not null default 'pending_approval'
    check (approval_state in ('pending_approval', 'approved', 'retired')),
  created_at timestamptz not null default now()
);

create table public.role_permission_grants (
  role_key text not null references public.access_role_definitions(role_key) on delete restrict,
  permission_key text not null references public.permission_definitions(permission_key) on delete restrict,
  created_at timestamptz not null default now(),
  primary key (role_key, permission_key)
);

create table public.membership_role_assignments (
  id uuid primary key default gen_random_uuid(),
  tenant_id uuid not null,
  membership_id uuid not null,
  role_key text not null references public.access_role_definitions(role_key) on delete restrict,
  branch_id uuid,
  assigned_by_user_id uuid not null references auth.users(id) on delete restrict,
  created_at timestamptz not null default now(),
  constraint membership_role_assignments_tenant_membership_fk
    foreign key (tenant_id, membership_id)
    references public.company_memberships(tenant_id, id) on delete restrict,
  constraint membership_role_assignments_tenant_branch_fk
    foreign key (tenant_id, branch_id)
    references public.branches(tenant_id, id) on delete restrict
);

-- Provisioning authority is an explicit, database-operator-managed allowlist.
-- It is intentionally empty: no Master or user receives administrative access
-- merely by existing in Auth. Tenant-scoped scopes require a tenant_id.
create table app_private.provisioning_admin_authorizations (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references auth.users(id) on delete restrict,
  scope_key text not null check (scope_key in (
    'company.create',
    'tenant.branch.manage',
    'tenant.membership.manage',
    'tenant.role.manage',
    'role_catalog.manage'
  )),
  tenant_id uuid references public.companies(id) on delete restrict,
  status text not null default 'active'
    check (status in ('active', 'suspended', 'revoked')),
  authorized_by_user_id uuid not null references auth.users(id) on delete restrict,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint provisioning_admin_scope_tenant_check check (
    (scope_key in ('company.create', 'role_catalog.manage') and tenant_id is null)
    or
    (scope_key in (
      'tenant.branch.manage',
      'tenant.membership.manage',
      'tenant.role.manage'
    ) and tenant_id is not null)
  )
);

create unique index provisioning_admin_global_scope_unique
  on app_private.provisioning_admin_authorizations (user_id, scope_key)
  where tenant_id is null;
create unique index provisioning_admin_tenant_scope_unique
  on app_private.provisioning_admin_authorizations (user_id, scope_key, tenant_id)
  where tenant_id is not null;

-- Append-only audit records for privileged provisioning operations.
create table app_private.provisioning_audit_events (
  id uuid primary key default gen_random_uuid(),
  event_key text not null,
  tenant_id uuid,
  subject_user_id uuid,
  actor_user_id uuid,
  actor_database_role text not null,
  actor_api_role text,
  details jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default now()
);

alter table app_private.provisioning_admin_authorizations enable row level security;
alter table app_private.provisioning_admin_authorizations force row level security;
alter table app_private.provisioning_audit_events enable row level security;
alter table app_private.provisioning_audit_events force row level security;

create unique index membership_role_assignments_company_unique
  on public.membership_role_assignments (tenant_id, membership_id, role_key)
  where branch_id is null;

create unique index membership_role_assignments_branch_unique
  on public.membership_role_assignments (tenant_id, membership_id, role_key, branch_id)
  where branch_id is not null;

insert into public.access_role_definitions (role_key, display_name, scope)
values
  ('company_owner', 'Proprietário da empresa (proposta)', 'company'),
  ('company_member', 'Usuário da empresa (proposta)', 'company'),
  ('branch_member', 'Usuário de filial (proposta)', 'branch');

insert into public.permission_definitions (permission_key, description)
values
  ('tenant.read', 'Leitura de metadados da própria empresa, limitada por vínculo ativo.'),
  ('branch.read', 'Leitura de filial dentro do escopo explicitamente autorizado.'),
  ('membership.read', 'Leitura dos próprios vínculos empresariais.'),
  ('branch_access.read', 'Leitura dos próprios vínculos de acesso a filiais.'),
  ('branch_access.manage', 'Administrar concessões de acesso a filiais; autoridade pendente.'),
  ('period.close', 'Fechar período; permissão independente de reabertura (C25).'),
  ('period.reopen', 'Reabrir período; atribuição sujeita às regras C23–C25.'),
  ('period.reopen.grant', 'Conceder permissão de reabertura conforme C23.'),
  ('period.post_reopened', 'Lançar em período reaberto quando autorizado conforme C24.');

create index branches_tenant_status_idx on public.branches (tenant_id, status);
create index company_memberships_user_status_idx
  on public.company_memberships (user_id, status, tenant_id);
create index company_memberships_tenant_status_idx
  on public.company_memberships (tenant_id, status, user_id);
create index branch_access_membership_status_idx
  on public.branch_access (membership_id, status, branch_id);
create index branch_access_tenant_branch_status_idx
  on public.branch_access (tenant_id, branch_id, status);
create index membership_role_assignments_membership_idx
  on public.membership_role_assignments (tenant_id, membership_id, role_key);

create or replace function app_private.touch_updated_at()
returns trigger
language plpgsql
set search_path = pg_catalog
as $$
begin
  new.updated_at := now();
  return new;
end;
$$;

create trigger user_profiles_touch_updated_at
before update on public.user_profiles
for each row execute function app_private.touch_updated_at();

create or replace function app_private.is_active_company_member(p_tenant_id uuid)
returns boolean
language sql
stable
security definer
set search_path = ''
set row_security = off
as $$
  select exists (
    select 1
    from public.company_memberships as membership
    join public.companies as company on company.id = membership.tenant_id
    where membership.tenant_id = p_tenant_id
      and membership.user_id = auth.uid()
      and membership.status = 'active'
      and company.status = 'active'
  );
$$;

create or replace function app_private.can_access_branch(
  p_tenant_id uuid,
  p_branch_id uuid
)
returns boolean
language sql
stable
security definer
set search_path = ''
set row_security = off
as $$
  select exists (
    select 1
    from public.company_memberships as membership
    join public.companies as company on company.id = membership.tenant_id
    join public.branches as branch
      on branch.tenant_id = membership.tenant_id
     and branch.id = p_branch_id
    where membership.tenant_id = p_tenant_id
      and membership.user_id = auth.uid()
      and membership.status = 'active'
      and company.status = 'active'
      and (
        membership.branch_access_mode = 'all_branches'
        or exists (
          select 1
          from public.branch_access as access_link
          where access_link.tenant_id = membership.tenant_id
            and access_link.branch_id = branch.id
            and access_link.membership_id = membership.id
            and access_link.status = 'active'
        )
      )
  );
$$;

create or replace function app_private.has_tenant_permission(
  p_tenant_id uuid,
  p_permission_key text,
  p_branch_id uuid default null
)
returns boolean
language sql
stable
security definer
set search_path = ''
set row_security = off
as $$
  select exists (
    select 1
    from public.company_memberships as membership
    join public.companies as company
      on company.id = membership.tenant_id
     and company.status = 'active'
    join public.membership_role_assignments as assignment
      on assignment.tenant_id = membership.tenant_id
     and assignment.membership_id = membership.id
    join public.access_role_definitions as role_definition
      on role_definition.role_key = assignment.role_key
     and role_definition.approval_state = 'approved'
    join public.role_permission_grants as role_grant
      on role_grant.role_key = role_definition.role_key
    join public.permission_definitions as permission
      on permission.permission_key = role_grant.permission_key
     and permission.approval_state = 'approved'
    where membership.tenant_id = p_tenant_id
      and membership.user_id = auth.uid()
      and membership.status = 'active'
      and role_grant.permission_key = p_permission_key
      and (
        (role_definition.scope = 'company' and assignment.branch_id is null)
        or (
          role_definition.scope = 'branch'
          and p_branch_id is not null
          and assignment.branch_id = p_branch_id
        )
      )
      and (p_branch_id is null or app_private.can_access_branch(p_tenant_id, p_branch_id))
  );
$$;

create or replace function app_private.validate_role_assignment_scope()
returns trigger
language plpgsql
set search_path = pg_catalog
as $$
declare
  role_scope text;
  role_state text;
begin
  select definition.scope, definition.approval_state
    into role_scope, role_state
  from public.access_role_definitions as definition
  where definition.role_key = new.role_key;

  if role_scope is null or role_state is distinct from 'approved' then
    raise exception 'Role is unknown or not approved for assignment';
  end if;

  if not exists (
    select 1
    from public.company_memberships as membership
    where membership.id = new.membership_id
      and membership.tenant_id = new.tenant_id
      and membership.status = 'active'
  ) then
    raise exception 'Role can only be assigned to an active company membership';
  end if;

  if role_scope = 'company' and new.branch_id is not null then
    raise exception 'Company-scoped role cannot be assigned to a branch';
  end if;

  if role_scope = 'branch' and new.branch_id is null then
    raise exception 'Branch-scoped role requires an explicit branch';
  end if;

  if new.branch_id is not null and not exists (
    select 1
    from public.branch_access as access_link
    where access_link.tenant_id = new.tenant_id
      and access_link.membership_id = new.membership_id
      and access_link.branch_id = new.branch_id
      and access_link.status = 'active'
  ) then
    raise exception 'Branch-scoped role requires an active branch access link';
  end if;

  return new;
end;
$$;

create trigger membership_role_assignments_validate_scope
before insert or update on public.membership_role_assignments
for each row execute function app_private.validate_role_assignment_scope();

-- SECURITY DEFINER routines are owned by the role applying this migration.
-- They fail closed if that owner cannot bypass FORCE RLS. The trusted service
-- identity is the signed Supabase service_role JWT; each operation also checks
-- an explicit user-and-scope authorization in the private allowlist.
create or replace function app_private.assert_provisioning_authorized(
  p_actor_user_id uuid,
  p_scope_key text,
  p_tenant_id uuid default null
)
returns void
language plpgsql
security definer
set search_path = ''
set row_security = off
as $$
begin
  if coalesce(auth.role(), '') <> 'service_role' then
    raise exception 'Trusted service identity required' using errcode = '42501';
  end if;

  if p_actor_user_id is null or not exists (
    select 1
    from app_private.provisioning_admin_authorizations as admin_auth
    where admin_auth.user_id = p_actor_user_id
      and admin_auth.scope_key = p_scope_key
      and admin_auth.tenant_id is not distinct from p_tenant_id
      and admin_auth.status = 'active'
  ) then
    raise exception 'No active provisioning authorization for requested scope'
      using errcode = '42501';
  end if;
end;
$$;

create or replace function app_private.write_provisioning_audit(
  p_event_key text,
  p_tenant_id uuid,
  p_subject_user_id uuid,
  p_actor_user_id uuid,
  p_details jsonb
)
returns void
language sql
set search_path = ''
set row_security = off
as $$
  insert into app_private.provisioning_audit_events (
    event_key,
    tenant_id,
    subject_user_id,
    actor_user_id,
    actor_database_role,
    actor_api_role,
    details
  ) values (
    p_event_key,
    p_tenant_id,
    p_subject_user_id,
    p_actor_user_id,
    session_user::text,
    nullif(auth.role(), ''),
    coalesce(p_details, '{}'::jsonb)
  );
$$;

-- Changes to the allowlist itself are audited as database-operator actions.
create or replace function app_private.audit_provisioning_authorization_change()
returns trigger
language plpgsql
security definer
set search_path = ''
set row_security = off
as $$
declare
  authorization_row app_private.provisioning_admin_authorizations%rowtype;
  operation_key text;
begin
  if tg_op = 'DELETE' then
    authorization_row := old;
    operation_key := 'provisioning.authorization.revoked_by_operator';
  else
    authorization_row := new;
    operation_key := case when tg_op = 'INSERT'
      then 'provisioning.authorization.created_by_operator'
      else 'provisioning.authorization.changed_by_operator'
    end;
  end if;

  perform app_private.write_provisioning_audit(
    operation_key,
    authorization_row.tenant_id,
    authorization_row.user_id,
    auth.uid(),
    pg_catalog.jsonb_build_object(
      'authorization_id', authorization_row.id,
      'scope_key', authorization_row.scope_key,
      'status', authorization_row.status,
      'authorized_by_user_id', authorization_row.authorized_by_user_id,
      'database_actor', session_user::text
    )
  );

  if tg_op = 'DELETE' then return old; end if;
  return new;
end;
$$;

create trigger provisioning_admin_authorizations_audit
after insert or update or delete on app_private.provisioning_admin_authorizations
for each row execute function app_private.audit_provisioning_authorization_change();

create or replace function app_private.prevent_provisioning_audit_mutation()
returns trigger
language plpgsql
set search_path = pg_catalog
as $$
begin
  raise exception 'Provisioning audit events are append-only' using errcode = '55000';
end;
$$;

create trigger provisioning_audit_events_append_only
before update or delete on app_private.provisioning_audit_events
for each row execute function app_private.prevent_provisioning_audit_mutation();

create or replace function app_private.provision_company(
  p_actor_user_id uuid,
  p_legal_name text,
  p_initial_owner_user_id uuid default null
)
returns uuid
language plpgsql
security definer
set search_path = ''
set row_security = off
as $$
declare
  new_tenant_id uuid;
  new_membership_id uuid;
begin
  perform app_private.assert_provisioning_authorized(
    p_actor_user_id, 'company.create', null
  );

  insert into public.companies (legal_name)
  values (p_legal_name)
  returning id into new_tenant_id;

  if p_initial_owner_user_id is not null then
    insert into public.company_memberships (
      tenant_id, user_id, status, branch_access_mode, created_by_user_id
    ) values (
      new_tenant_id, p_initial_owner_user_id, 'pending', 'assigned_only', p_actor_user_id
    ) returning id into new_membership_id;
  end if;

  perform app_private.write_provisioning_audit(
    'company.provisioned',
    new_tenant_id,
    p_initial_owner_user_id,
    p_actor_user_id,
    pg_catalog.jsonb_build_object(
      'company_id', new_tenant_id,
      'initial_membership_id', new_membership_id,
      'initial_membership_status', case when new_membership_id is null then null else 'pending' end
    )
  );
  return new_tenant_id;
end;
$$;

create or replace function app_private.provision_branch(
  p_actor_user_id uuid,
  p_tenant_id uuid,
  p_code text,
  p_name text
)
returns uuid
language plpgsql
security definer
set search_path = ''
set row_security = off
as $$
declare
  new_branch_id uuid;
begin
  perform app_private.assert_provisioning_authorized(
    p_actor_user_id, 'tenant.branch.manage', p_tenant_id
  );
  if not exists (
    select 1 from public.companies as company
    where company.id = p_tenant_id and company.status = 'active'
  ) then
    raise exception 'Active tenant not found' using errcode = '23503';
  end if;

  insert into public.branches (tenant_id, code, name)
  values (p_tenant_id, p_code, p_name)
  returning id into new_branch_id;

  perform app_private.write_provisioning_audit(
    'branch.provisioned', p_tenant_id, null, p_actor_user_id,
    pg_catalog.jsonb_build_object('branch_id', new_branch_id, 'code', p_code)
  );
  return new_branch_id;
end;
$$;

create or replace function app_private.provision_membership(
  p_actor_user_id uuid,
  p_tenant_id uuid,
  p_target_user_id uuid
)
returns uuid
language plpgsql
security definer
set search_path = ''
set row_security = off
as $$
declare
  new_membership_id uuid;
begin
  perform app_private.assert_provisioning_authorized(
    p_actor_user_id, 'tenant.membership.manage', p_tenant_id
  );
  if p_actor_user_id = p_target_user_id then
    raise exception 'An administrator cannot provision their own membership'
      using errcode = '42501';
  end if;
  if not exists (
    select 1 from public.companies as company
    where company.id = p_tenant_id and company.status = 'active'
  ) then
    raise exception 'Active tenant not found' using errcode = '23503';
  end if;

  insert into public.company_memberships (
    tenant_id, user_id, status, branch_access_mode, created_by_user_id
  ) values (
    p_tenant_id, p_target_user_id, 'pending', 'assigned_only', p_actor_user_id
  ) returning id into new_membership_id;

  perform app_private.write_provisioning_audit(
    'membership.provisioned_pending', p_tenant_id, p_target_user_id, p_actor_user_id,
    pg_catalog.jsonb_build_object('membership_id', new_membership_id, 'status', 'pending')
  );
  return new_membership_id;
end;
$$;

create or replace function app_private.activate_membership(
  p_actor_user_id uuid,
  p_tenant_id uuid,
  p_membership_id uuid
)
returns void
language plpgsql
security definer
set search_path = ''
set row_security = off
as $$
declare
  target_user_id uuid;
  old_status text;
begin
  perform app_private.assert_provisioning_authorized(
    p_actor_user_id, 'tenant.membership.manage', p_tenant_id
  );
  select membership.user_id, membership.status
    into target_user_id, old_status
  from public.company_memberships as membership
  join public.companies as company
    on company.id = membership.tenant_id and company.status = 'active'
  where membership.id = p_membership_id and membership.tenant_id = p_tenant_id
  for update;
  if not found then
    raise exception 'Membership not found in authorized tenant' using errcode = '23503';
  end if;
  if target_user_id = p_actor_user_id then
    raise exception 'An administrator cannot activate their own membership'
      using errcode = '42501';
  end if;
  if old_status <> 'pending' then
    raise exception 'Only pending memberships can be activated' using errcode = '55000';
  end if;

  update public.company_memberships
  set status = 'active'
  where id = p_membership_id and tenant_id = p_tenant_id;

  perform app_private.write_provisioning_audit(
    'membership.activated', p_tenant_id, target_user_id, p_actor_user_id,
    pg_catalog.jsonb_build_object(
      'membership_id', p_membership_id, 'old_status', old_status, 'new_status', 'active'
    )
  );
end;
$$;

create or replace function app_private.set_membership_status(
  p_actor_user_id uuid,
  p_tenant_id uuid,
  p_membership_id uuid,
  p_new_status text
)
returns void
language plpgsql
security definer
set search_path = ''
set row_security = off
as $$
declare
  target_user_id uuid;
  old_status text;
begin
  perform app_private.assert_provisioning_authorized(
    p_actor_user_id, 'tenant.membership.manage', p_tenant_id
  );
  if p_new_status is null or p_new_status not in ('suspended', 'revoked') then
    raise exception 'Only suspension or revocation is supported by this routine'
      using errcode = '22023';
  end if;
  select membership.user_id, membership.status
    into target_user_id, old_status
  from public.company_memberships as membership
  join public.companies as company
    on company.id = membership.tenant_id and company.status = 'active'
  where membership.id = p_membership_id and membership.tenant_id = p_tenant_id
  for update;
  if not found then
    raise exception 'Membership not found in active authorized tenant'
      using errcode = '23503';
  end if;
  if target_user_id = p_actor_user_id then
    raise exception 'An administrator cannot change their own membership status'
      using errcode = '42501';
  end if;
  if old_status = p_new_status then
    raise exception 'Membership already has requested status' using errcode = '55000';
  end if;

  update public.company_memberships
  set status = p_new_status
  where id = p_membership_id and tenant_id = p_tenant_id;

  perform app_private.write_provisioning_audit(
    'membership.status_changed', p_tenant_id, target_user_id, p_actor_user_id,
    pg_catalog.jsonb_build_object(
      'membership_id', p_membership_id,
      'old_status', old_status,
      'new_status', p_new_status
    )
  );
end;
$$;

create or replace function app_private.grant_branch_access(
  p_actor_user_id uuid,
  p_tenant_id uuid,
  p_membership_id uuid,
  p_branch_id uuid
)
returns uuid
language plpgsql
security definer
set search_path = ''
set row_security = off
as $$
declare
  target_user_id uuid;
  new_access_id uuid;
begin
  perform app_private.assert_provisioning_authorized(
    p_actor_user_id, 'tenant.membership.manage', p_tenant_id
  );
  select membership.user_id into target_user_id
  from public.company_memberships as membership
  join public.companies as company
    on company.id = membership.tenant_id and company.status = 'active'
  join public.branches as branch
    on branch.tenant_id = membership.tenant_id
   and branch.id = p_branch_id
   and branch.status = 'active'
  where membership.id = p_membership_id
    and membership.tenant_id = p_tenant_id
    and membership.status = 'active';
  if not found then
    raise exception 'Active membership and branch in authorized tenant are required'
      using errcode = '23503';
  end if;
  if target_user_id = p_actor_user_id then
    raise exception 'An administrator cannot grant branch access to themselves'
      using errcode = '42501';
  end if;

  insert into public.branch_access (
    tenant_id, branch_id, membership_id, status, granted_by_user_id
  ) values (
    p_tenant_id, p_branch_id, p_membership_id, 'active', p_actor_user_id
  ) returning id into new_access_id;

  perform app_private.write_provisioning_audit(
    'branch_access.granted', p_tenant_id, target_user_id, p_actor_user_id,
    pg_catalog.jsonb_build_object(
      'branch_access_id', new_access_id,
      'membership_id', p_membership_id,
      'branch_id', p_branch_id
    )
  );
  return new_access_id;
end;
$$;

create or replace function app_private.set_branch_access_status(
  p_actor_user_id uuid,
  p_tenant_id uuid,
  p_branch_access_id uuid,
  p_new_status text
)
returns void
language plpgsql
security definer
set search_path = ''
set row_security = off
as $$
declare
  target_user_id uuid;
  old_status text;
begin
  perform app_private.assert_provisioning_authorized(
    p_actor_user_id, 'tenant.membership.manage', p_tenant_id
  );
  if p_new_status is null or p_new_status not in ('active', 'suspended', 'revoked') then
    raise exception 'Invalid branch access status' using errcode = '22023';
  end if;
  select membership.user_id, access_link.status
    into target_user_id, old_status
  from public.branch_access as access_link
  join public.company_memberships as membership
    on membership.id = access_link.membership_id
   and membership.tenant_id = access_link.tenant_id
  where access_link.id = p_branch_access_id and access_link.tenant_id = p_tenant_id
  for update of access_link;
  if not found then
    raise exception 'Branch access not found in authorized tenant' using errcode = '23503';
  end if;
  if target_user_id = p_actor_user_id then
    raise exception 'An administrator cannot change their own branch access'
      using errcode = '42501';
  end if;
  if p_new_status = 'active' and not exists (
    select 1
    from public.branch_access as access_link
    join public.branches as branch
      on branch.tenant_id = access_link.tenant_id
     and branch.id = access_link.branch_id
    join public.company_memberships as membership
      on membership.tenant_id = access_link.tenant_id
     and membership.id = access_link.membership_id
    join public.companies as company
      on company.id = access_link.tenant_id
    where access_link.id = p_branch_access_id
      and access_link.tenant_id = p_tenant_id
      and branch.status = 'active'
      and membership.status = 'active'
      and company.status = 'active'
  ) then
    raise exception 'Cannot activate access for an inactive branch or membership'
      using errcode = '55000';
  end if;

  update public.branch_access
  set status = p_new_status
  where id = p_branch_access_id and tenant_id = p_tenant_id;

  perform app_private.write_provisioning_audit(
    'branch_access.status_changed', p_tenant_id, target_user_id, p_actor_user_id,
    pg_catalog.jsonb_build_object(
      'branch_access_id', p_branch_access_id,
      'old_status', old_status,
      'new_status', p_new_status
    )
  );
end;
$$;

create or replace function app_private.assign_membership_role(
  p_actor_user_id uuid,
  p_tenant_id uuid,
  p_membership_id uuid,
  p_role_key text,
  p_branch_id uuid default null
)
returns uuid
language plpgsql
security definer
set search_path = ''
set row_security = off
as $$
declare
  target_user_id uuid;
  new_assignment_id uuid;
begin
  perform app_private.assert_provisioning_authorized(
    p_actor_user_id, 'tenant.role.manage', p_tenant_id
  );
  select membership.user_id into target_user_id
  from public.company_memberships as membership
  join public.companies as company
    on company.id = membership.tenant_id and company.status = 'active'
  where membership.id = p_membership_id
    and membership.tenant_id = p_tenant_id
    and membership.status = 'active';
  if not found then
    raise exception 'Active membership not found in authorized tenant' using errcode = '23503';
  end if;
  if target_user_id = p_actor_user_id then
    raise exception 'An administrator cannot assign a role to themselves'
      using errcode = '42501';
  end if;
  if not exists (
    select 1 from public.access_role_definitions as role_definition
    where role_definition.role_key = p_role_key
      and role_definition.approval_state = 'approved'
  ) then
    raise exception 'Role must exist and be approved before assignment'
      using errcode = '55000';
  end if;

  insert into public.membership_role_assignments (
    tenant_id, membership_id, role_key, branch_id, assigned_by_user_id
  ) values (
    p_tenant_id, p_membership_id, p_role_key, p_branch_id, p_actor_user_id
  ) returning id into new_assignment_id;

  perform app_private.write_provisioning_audit(
    'membership_role.assigned', p_tenant_id, target_user_id, p_actor_user_id,
    pg_catalog.jsonb_build_object(
      'assignment_id', new_assignment_id,
      'membership_id', p_membership_id,
      'role_key', p_role_key,
      'branch_id', p_branch_id
    )
  );
  return new_assignment_id;
end;
$$;

create or replace function app_private.revoke_membership_role(
  p_actor_user_id uuid,
  p_tenant_id uuid,
  p_membership_id uuid,
  p_role_key text,
  p_branch_id uuid default null
)
returns void
language plpgsql
security definer
set search_path = ''
set row_security = off
as $$
declare
  target_user_id uuid;
  removed_assignment_id uuid;
begin
  perform app_private.assert_provisioning_authorized(
    p_actor_user_id, 'tenant.role.manage', p_tenant_id
  );
  select membership.user_id into target_user_id
  from public.company_memberships as membership
  where membership.id = p_membership_id and membership.tenant_id = p_tenant_id;
  if not found then
    raise exception 'Membership not found in authorized tenant' using errcode = '23503';
  end if;
  if target_user_id = p_actor_user_id then
    raise exception 'An administrator cannot change their own role assignment'
      using errcode = '42501';
  end if;

  delete from public.membership_role_assignments as assignment
  where assignment.tenant_id = p_tenant_id
    and assignment.membership_id = p_membership_id
    and assignment.role_key = p_role_key
    and assignment.branch_id is not distinct from p_branch_id
  returning assignment.id into removed_assignment_id;
  if not found then
    raise exception 'Role assignment not found in authorized tenant' using errcode = 'P0002';
  end if;

  perform app_private.write_provisioning_audit(
    'membership_role.revoked', p_tenant_id, target_user_id, p_actor_user_id,
    pg_catalog.jsonb_build_object(
      'assignment_id', removed_assignment_id,
      'membership_id', p_membership_id,
      'role_key', p_role_key,
      'branch_id', p_branch_id
    )
  );
end;
$$;

create or replace function app_private.grant_role_permission(
  p_actor_user_id uuid,
  p_role_key text,
  p_permission_key text
)
returns void
language plpgsql
security definer
set search_path = ''
set row_security = off
as $$
begin
  perform app_private.assert_provisioning_authorized(
    p_actor_user_id, 'role_catalog.manage', null
  );
  if not exists (
    select 1 from public.access_role_definitions as role_definition
    where role_definition.role_key = p_role_key
      and role_definition.approval_state = 'approved'
  ) or not exists (
    select 1 from public.permission_definitions as permission
    where permission.permission_key = p_permission_key
      and permission.approval_state = 'approved'
  ) then
    raise exception 'Role and permission must both be approved before granting'
      using errcode = '55000';
  end if;
  if exists (
    select 1
    from public.membership_role_assignments as assignment
    join public.company_memberships as membership
      on membership.tenant_id = assignment.tenant_id
     and membership.id = assignment.membership_id
    where membership.user_id = p_actor_user_id and assignment.role_key = p_role_key
  ) then
    raise exception 'An administrator cannot add permissions to a role assigned to themselves'
      using errcode = '42501';
  end if;
  if not exists (
    select 1 from public.role_permission_grants as existing_grant
    where existing_grant.role_key = p_role_key
      and existing_grant.permission_key = p_permission_key
  ) then
    insert into public.role_permission_grants (role_key, permission_key)
    values (p_role_key, p_permission_key);
    perform app_private.write_provisioning_audit(
      'role_permission.granted', null, null, p_actor_user_id,
      pg_catalog.jsonb_build_object(
        'role_key', p_role_key, 'permission_key', p_permission_key
      )
    );
  end if;
end;
$$;

create or replace function app_private.revoke_role_permission(
  p_actor_user_id uuid,
  p_role_key text,
  p_permission_key text
)
returns void
language plpgsql
security definer
set search_path = ''
set row_security = off
as $$
begin
  perform app_private.assert_provisioning_authorized(
    p_actor_user_id, 'role_catalog.manage', null
  );
  delete from public.role_permission_grants as existing_grant
  where existing_grant.role_key = p_role_key
    and existing_grant.permission_key = p_permission_key;
  if found then
    perform app_private.write_provisioning_audit(
      'role_permission.revoked', null, null, p_actor_user_id,
      pg_catalog.jsonb_build_object(
        'role_key', p_role_key, 'permission_key', p_permission_key
      )
    );
  end if;
end;
$$;

alter table public.companies enable row level security;
alter table public.companies force row level security;
alter table public.branches enable row level security;
alter table public.branches force row level security;
alter table public.user_profiles enable row level security;
alter table public.user_profiles force row level security;
alter table public.company_memberships enable row level security;
alter table public.company_memberships force row level security;
alter table public.branch_access enable row level security;
alter table public.branch_access force row level security;
alter table public.access_role_definitions enable row level security;
alter table public.access_role_definitions force row level security;
alter table public.permission_definitions enable row level security;
alter table public.permission_definitions force row level security;
alter table public.role_permission_grants enable row level security;
alter table public.role_permission_grants force row level security;
alter table public.membership_role_assignments enable row level security;
alter table public.membership_role_assignments force row level security;

revoke all on table
  public.companies,
  public.branches,
  public.user_profiles,
  public.company_memberships,
  public.branch_access,
  public.access_role_definitions,
  public.permission_definitions,
  public.role_permission_grants,
  public.membership_role_assignments,
  app_private.provisioning_admin_authorizations,
  app_private.provisioning_audit_events
from public, anon, authenticated, service_role;

grant usage on schema public to authenticated;
-- service_role gets schema/function access only; it receives no direct table DML.
-- Keep app_private out of PostgREST's exposed-schema configuration.
grant usage on schema app_private to service_role;
grant select on table public.companies, public.branches, public.user_profiles,
  public.company_memberships, public.branch_access to authenticated;
grant update (display_name) on table public.user_profiles to authenticated;

create policy companies_select_active_member
  on public.companies for select to authenticated
  using (app_private.is_active_company_member(id));

create policy branches_select_authorized_scope
  on public.branches for select to authenticated
  using (app_private.can_access_branch(tenant_id, id));

create policy user_profiles_select_self
  on public.user_profiles for select to authenticated
  using (user_id = (select auth.uid()));

create policy user_profiles_update_self_display_name
  on public.user_profiles for update to authenticated
  using (user_id = (select auth.uid()))
  with check (user_id = (select auth.uid()));

create policy company_memberships_select_self
  on public.company_memberships for select to authenticated
  using (user_id = (select auth.uid()));

create policy branch_access_select_self
  on public.branch_access for select to authenticated
  using (
    exists (
      select 1
      from public.company_memberships as membership
      where membership.id = branch_access.membership_id
        and membership.tenant_id = branch_access.tenant_id
        and membership.user_id = (select auth.uid())
        and membership.status = 'active'
    )
  );

revoke all on function app_private.touch_updated_at() from public, anon, authenticated, service_role;
revoke all on function app_private.is_active_company_member(uuid) from public, anon, authenticated, service_role;
revoke all on function app_private.can_access_branch(uuid, uuid) from public, anon, authenticated, service_role;
revoke all on function app_private.has_tenant_permission(uuid, text, uuid) from public, anon, authenticated, service_role;
revoke all on function app_private.validate_role_assignment_scope() from public, anon, authenticated, service_role;
revoke all on function app_private.assert_provisioning_authorized(uuid, text, uuid) from public, anon, authenticated, service_role;
revoke all on function app_private.write_provisioning_audit(text, uuid, uuid, uuid, jsonb) from public, anon, authenticated, service_role;
revoke all on function app_private.audit_provisioning_authorization_change() from public, anon, authenticated, service_role;
revoke all on function app_private.prevent_provisioning_audit_mutation() from public, anon, authenticated, service_role;
revoke all on function app_private.provision_company(uuid, text, uuid) from public, anon, authenticated, service_role;
revoke all on function app_private.provision_branch(uuid, uuid, text, text) from public, anon, authenticated, service_role;
revoke all on function app_private.provision_membership(uuid, uuid, uuid) from public, anon, authenticated, service_role;
revoke all on function app_private.activate_membership(uuid, uuid, uuid) from public, anon, authenticated, service_role;
revoke all on function app_private.set_membership_status(uuid, uuid, uuid, text) from public, anon, authenticated, service_role;
revoke all on function app_private.grant_branch_access(uuid, uuid, uuid, uuid) from public, anon, authenticated, service_role;
revoke all on function app_private.set_branch_access_status(uuid, uuid, uuid, text) from public, anon, authenticated, service_role;
revoke all on function app_private.assign_membership_role(uuid, uuid, uuid, text, uuid) from public, anon, authenticated, service_role;
revoke all on function app_private.revoke_membership_role(uuid, uuid, uuid, text, uuid) from public, anon, authenticated, service_role;
revoke all on function app_private.grant_role_permission(uuid, text, text) from public, anon, authenticated, service_role;
revoke all on function app_private.revoke_role_permission(uuid, text, text) from public, anon, authenticated, service_role;
grant execute on function app_private.is_active_company_member(uuid) to authenticated;
grant execute on function app_private.can_access_branch(uuid, uuid) to authenticated;
grant execute on function app_private.has_tenant_permission(uuid, text, uuid) to authenticated;
grant execute on function app_private.provision_company(uuid, text, uuid) to service_role;
grant execute on function app_private.provision_branch(uuid, uuid, text, text) to service_role;
grant execute on function app_private.provision_membership(uuid, uuid, uuid) to service_role;
grant execute on function app_private.activate_membership(uuid, uuid, uuid) to service_role;
grant execute on function app_private.set_membership_status(uuid, uuid, uuid, text) to service_role;
grant execute on function app_private.grant_branch_access(uuid, uuid, uuid, uuid) to service_role;
grant execute on function app_private.set_branch_access_status(uuid, uuid, uuid, text) to service_role;
grant execute on function app_private.assign_membership_role(uuid, uuid, uuid, text, uuid) to service_role;
grant execute on function app_private.revoke_membership_role(uuid, uuid, uuid, text, uuid) to service_role;
grant execute on function app_private.grant_role_permission(uuid, text, text) to service_role;
grant execute on function app_private.revoke_role_permission(uuid, text, text) to service_role;

commit;
