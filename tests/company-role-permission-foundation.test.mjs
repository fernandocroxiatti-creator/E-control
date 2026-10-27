import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { resolve } from "node:path";
import { fileURLToPath } from "node:url";
import test from "node:test";

const root = resolve(fileURLToPath(new URL("..", import.meta.url)));
const migration = readFileSync(resolve(root, "supabase/migrations/20261027190000_company_role_permission_authorization.sql"), "utf8");
const behavior = readFileSync(resolve(root, "supabase/tests/EC-ROLE-01-local/01_role_permission_behavior.sql"), "utf8");
const runner = readFileSync(resolve(root, "supabase/tests/EC-ADM-03-local/run-local-invitation-test.sh"), "utf8");

test("role and permission proposals stay pending and no effective role grants are seeded", () => {
  assert.match(migration, /on conflict \(role_key\) do nothing/);
  assert.match(migration, /on conflict \(permission_key\) do nothing/);
  assert.match(migration, /approval_state <> 'pending_approval'/);
  assert.match(migration, /proposed company roles must not receive permission grants/i);
  assert.doesNotMatch(migration, /insert into public\.role_permission_grants/i);
  assert.match(migration, /company_owner may only be established through the one-time Master invitation flow/i);
});

test("transaction checks are Auth-bound, tenant/branch-scoped and fail closed for unknown catalog entries", () => {
  assert.match(migration, /public\.authorize_company_transaction\([\s\S]*?auth\.role\(\)[\s\S]*?auth\.uid\(\)/);
  assert.match(migration, /catalog\.approval_state = 'approved'/);
  assert.match(migration, /app_private\.has_tenant_permission\(p_tenant_id, required_permission, p_branch_id\)/);
  assert.match(migration, /app_private\.can_access_branch\(p_tenant_id, p_branch_id\)/);
  assert.match(migration, /returns boolean[\s\S]*?return false/);
  assert.match(migration, /'ME21N', 'PUR', 'transaction\.purchasing\.purchase_order\.create'/);
});

test("role delegation is bounded by actor entitlements; branch access stays tenant-bound and audited", () => {
  assert.match(migration, /app_private\.has_tenant_permission\(p_tenant_id, 'membership\.role\.assign', p_branch_id\)/);
  assert.match(migration, /not app_private\.has_tenant_permission\(p_tenant_id, role_grant\.permission_key, p_branch_id\)/);
  assert.match(migration, /Users cannot change their own role assignment/);
  assert.match(migration, /company_owner may only be established through the one-time Master invitation flow/i);
  assert.match(migration, /app_private\.has_tenant_permission\(p_tenant_id, 'branch_access\.manage', p_branch_id\)/);
  assert.match(migration, /assignment\.tenant_id = p_tenant_id/);
  assert.match(migration, /membership\.tenant_id = p_tenant_id/);
  assert.match(behavior, /Role Test Company A/);
  assert.match(behavior, /revoked branch access still authorizes transaction/);
  assert.match(behavior, /revoked company role still authorizes transaction/);
  assert.match(behavior, /audit event counts mismatch/);
  assert.match(behavior, /unassigned branch/);
  assert.match(behavior, /unlinked user received transaction access/);
  assert.match(runner, /20261027190000_company_role_permission_authorization\.sql/);
  assert.match(runner, /01_role_permission_behavior\.sql/);
  assert.doesNotMatch(runner, /20261021120000_master_first_bootstrap\.sql/);
});

test("RPCs use strict SECURITY DEFINER settings and authenticated-only ACLs", () => {
  assert.equal((migration.match(/security definer/gi) ?? []).length, 4);
  assert.equal((migration.match(/set search_path = '' set row_security = off/gi) ?? []).length, 4);
  assert.equal((migration.match(/grant execute on function public\.(?:authorize_company_transaction|assign_company_membership_role|revoke_company_membership_role|set_company_member_branch_access)/gi) ?? []).length, 4);
  assert.match(migration, /from public, anon, authenticated, service_role/);
  assert.match(migration, /has_function_privilege\('anon'/);
  assert.match(migration, /has_function_privilege\('service_role'/);
  assert.match(migration, /function_acl\.grantee = 0/);
});
