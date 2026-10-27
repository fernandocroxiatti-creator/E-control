import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { resolve } from "node:path";
import { fileURLToPath } from "node:url";
import test from "node:test";

const projectRoot = resolve(fileURLToPath(new URL("..", import.meta.url)));
const migration = readFileSync(
  resolve(projectRoot, "supabase/migrations/20261022130000_company_authorization_foundation.sql"),
  "utf8",
);

test("authorization derives the actor only from the authenticated Supabase identity", () => {
  const createBranch = migration.slice(
    migration.indexOf("create function public.create_branch"),
    migration.indexOf("alter function public.create_branch"),
  );
  assert.match(createBranch, /auth\.role\(\)[\s\S]*<>\s*'authenticated'/);
  assert.match(createBranch, /actor_id\s*:=\s*auth\.uid\(\)/);
  assert.match(createBranch, /membership\.user_id\s*=\s*actor_id/);
  assert.doesNotMatch(createBranch, /p_actor_user_id|p_actor_id/i);
  assert.doesNotMatch(createBranch, /app_metadata|econtrol_role|is_current_user_master/);
});

test("tenant selector is bound to a persistent tenant-scoped authorization", () => {
  assert.match(migration, /permission_key, description, approval_state\)[\s\S]*?'branch\.manage'[\s\S]*?'pending_approval'/);
  assert.match(migration, /app_private\.has_tenant_permission\(p_tenant_id, 'branch\.manage', null\)/);
  assert.match(migration, /membership\.tenant_id\s*=\s*p_tenant_id/);
  assert.match(migration, /membership\.user_id\s*=\s*actor_id/);
  assert.match(migration, /company\.status\s*=\s*'active'/);
  assert.match(migration, /for share of membership, company, assignment, role_definition, role_grant, permission/i);
  assert.match(migration, /privileged_role\.rolsuper or privileged_role\.rolbypassrls/);
  assert.match(migration, /revoke execute on function app_private\.provision_branch[\s\S]*from service_role/);
});

test("unauthenticated, unauthorized and inactive identities fail closed", () => {
  const createBranch = migration.slice(
    migration.indexOf("create function public.create_branch"),
    migration.indexOf("alter function public.create_branch"),
  );
  assert.match(createBranch, /if coalesce\(auth\.role\(\), ''\) <> 'authenticated'[\s\S]*?using errcode = '42501'/);
  assert.match(createBranch, /if actor_id is null[\s\S]*?using errcode = '42501'/);
  assert.match(createBranch, /membership\.status = 'active'/);
  assert.match(createBranch, /permission\.approval_state = 'approved'/);
  assert.match(createBranch, /company\.status = 'active'/);
  assert.match(createBranch, /No active branch-management permission for this company/);
});

test("metadata reads remain RLS-scoped and operational memberships are not granted", () => {
  assert.match(migration, /create policy companies_select_branch_manager[\s\S]*for select to authenticated/);
  assert.match(migration, /create policy branches_select_branch_manager[\s\S]*for select to authenticated/);
  assert.match(migration, /alter table app_private\.branch_creation_requests enable row level security/);
  assert.match(migration, /alter table app_private\.branch_creation_requests force row level security/);
  assert.match(migration, /aclexplode\([\s\S]*?acldefault\('r', relation_row\.relowner\)/);
  assert.match(migration, /Private idempotency table ownership, RLS, policies or ACL is invalid/);
  assert.doesNotMatch(migration, /insert into public\.(company_memberships|branch_access|membership_role_assignments|role_permission_grants)/i);
  assert.doesNotMatch(migration, /grant\s+(insert|update|delete|all)\s+on\s+table\s+public\.(companies|branches|company_memberships|branch_access)/i);
});

test("Admin Master receives no automatic tenant membership or operational access", () => {
  assert.doesNotMatch(migration, /master_admins|is_current_user_master|econtrol_role|app_metadata/i);
  assert.doesNotMatch(migration, /insert into public\.(company_memberships|branch_access|membership_role_assignments|role_permission_grants)/i);
  assert.match(migration, /does not grant membership or operational access|grants no membership or operational access/i);
  assert.match(migration, /actor_id\s*:=\s*auth\.uid\(\)/);
});

test("branch creation is authenticated-only, narrow, idempotent and audited atomically", () => {
  assert.match(migration, /create function public\.create_branch\(\s*p_tenant_id uuid,\s*p_request_id uuid,\s*p_code text,\s*p_name text/s);
  assert.match(migration, /security definer[\s\S]*set search_path = ''[\s\S]*set row_security = off/i);
  assert.match(migration, /primary key \(actor_user_id, tenant_id, request_id\)/);
  assert.match(migration, /Request key was already used for different branch data/);
  assert.match(migration, /insert into app_private\.branch_creation_requests/);
  assert.match(migration, /perform app_private\.write_provisioning_audit\([\s\S]*'branch\.provisioned'/);
  assert.match(migration, /begin;[\s\S]*commit;/i);
  assert.match(migration, /revoke all on function public\.create_branch\(uuid, uuid, text, text\)[\s\S]*from public, anon, authenticated, service_role/);
  assert.match(migration, /grant execute on function public\.create_branch\(uuid, uuid, text, text\) to authenticated/);
  assert.doesNotMatch(migration, /grant execute[^;]*service_role/i);
});

test("authorization changes are audited by private always-enabled row triggers", () => {
  assert.match(migration, /create function app_private\.audit_company_authorization_change\(\)[\s\S]*security definer[\s\S]*set search_path = ''[\s\S]*set row_security = off/);
  assert.match(migration, /auth\.uid\(\)[\s\S]*app_private\.write_provisioning_audit/);
  assert.match(migration, /create trigger authorization_memberships_audit[\s\S]*after insert or update or delete on public\.company_memberships[\s\S]*for each row/i);
  assert.match(migration, /create trigger authorization_role_assignments_audit[\s\S]*after insert or update or delete on public\.membership_role_assignments[\s\S]*for each row/i);
  assert.match(migration, /create trigger authorization_role_permission_grants_audit[\s\S]*after insert or update or delete on public\.role_permission_grants[\s\S]*for each row/i);
  assert.match(migration, /alter table public\.company_memberships enable always trigger authorization_memberships_audit/i);
  assert.match(migration, /Authorization audit triggers or their function ACL are invalid/);
  assert.match(migration, /authorization\.permission_definition\.seeded/);
});

test("legacy actor-parameter routines are not left executable to service_role", () => {
  const revokes = migration.match(/revoke execute on function app_private\.[\s\S]*?from service_role;/g) ?? [];
  assert.equal(revokes.length, 11);
  assert.match(migration, /has_function_privilege\('service_role', legacy_function\.function_oid, 'EXECUTE'\)/);
  assert.match(migration, /Legacy actor-parameter provisioning routines remain executable by an API role/);
});

test("branch creation UI stays disabled pending real database integration validation", () => {
  const component = readFileSync(resolve(projectRoot, "app/components/companies-workspace.tsx"), "utf8");
  assert.match(component, /type=\{isBranchForm \? "button" : "submit"\} disabled=\{isBranchForm\}/);
  assert.match(component, /A gravação permanece bloqueada até existir autorização empresarial persistente/);
});
