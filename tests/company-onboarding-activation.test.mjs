import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { fileURLToPath } from "node:url";
import { resolve } from "node:path";
import test from "node:test";

const root = resolve(fileURLToPath(new URL("..", import.meta.url)));
const read = (file) => readFileSync(resolve(root, file), "utf8");
const migration = read("supabase/migrations/20261110120000_company_onboarding_activation.sql");
const companyActions = read("app/actions/company-admin-invitations.ts");
const operationalActions = read("app/actions/operational.ts");
const authAdmin = read("lib/supabase/auth-admin.ts");
const reset = read("app/reset-password/page.tsx");
const authActions = read("app/actions/auth.ts");
const runner = read("scripts/test-package-01-postgres.sh");

test("onboarding reuses invitation ledgers and accepts only the confirmed Auth identity", () => {
  assert.match(migration, /app_private\.company_admin_invitations/);
  assert.match(migration, /app_private\.company_employee_invitations/);
  assert.doesNotMatch(migration, /create table app_private\.company_member_invitations/);
  assert.match(migration, /auth_user\.email_confirmed_at is not null/);
  assert.match(migration, /create function public\.accept_current_company_admin_invitation\(\)/);
  assert.match(migration, /create function public\.accept_current_company_employee_invitation\(\)/);
  assert.match(migration, /create function public\.company_reactivate_employee_membership/);
  assert.match(migration, /Users cannot reactivate their own membership/);
  assert.match(migration, /invitation_count <> 1/);
  assert.match(migration, /'ambiguous'/);
  assert.match(migration, /'pending', 'assigned_only'/);
  assert.match(migration, /company_memberships\.tenant_id = invitation\.tenant_id/);
  assert.doesNotMatch(migration, /where tenant_id = invitation\.tenant_id/);
  assert.match(migration, /company_owner/);
  assert.match(migration, /grant execute on function public\.accept_current_company_admin_invitation\(\) to authenticated/);
  assert.doesNotMatch(migration, /grant execute[^;]*service_role/i);
  assert.doesNotMatch(migration, /accept_current_company_(?:admin|employee)_invitation\([^)]*(?:uuid|text)/i);
});

test("activation delivery is server-only, explicitly gated, and password setup returns to the invitation", () => {
  assert.match(authAdmin, /import "server-only"/);
  assert.match(authAdmin, /SUPABASE_SERVICE_ROLE_KEY/);
  assert.match(authAdmin, /ECONTROLL_AUTH_INVITATIONS_ENABLED/);
  assert.match(companyActions, /auth\.admin\.inviteUserByEmail/);
  assert.match(operationalActions, /auth\.admin\.inviteUserByEmail/);
  assert.match(companyActions, /accept_current_company_admin_invitation/);
  assert.match(operationalActions, /accept_current_company_employee_invitation/);
  assert.match(operationalActions, /reactivateEmployeeMembershipAction/);
  assert.match(reset, /safeInternalPath\(next, "\/dashboard"\)/);
  assert.match(authActions, /destination\.searchParams\.set\("password", "updated"\)/);
  assert.doesNotMatch(companyActions, /console\.(?:log|error)/);
  assert.doesNotMatch(operationalActions, /console\.(?:log|error)/);
});

test("isolated PostgreSQL suite covers confirmed identity, replay, expiry, pending approval and audit", () => {
  const behavior = read("tests/sql/company-onboarding-activation-behavior.sql");
  assert.match(behavior, /wrong confirmed identity accepted owner invitation/);
  assert.match(behavior, /owner invitation replay was accepted/);
  assert.match(behavior, /pending approval/);
  assert.match(behavior, /expired Auth-bound employee invitation was accepted/);
  assert.match(behavior, /suspended employee was not reactivated/);
  assert.match(behavior, /onboarding acceptance audit trail is incomplete/);
  assert.match(runner, /20261110120000_company_onboarding_activation\.sql/);
  assert.match(runner, /company-onboarding-activation-behavior\.sql/);
  assert.match(runner, /run_onboarding_accept/);
  assert.match(runner, /concurrent onboarding acceptance did not produce exactly one accepted result/);
});
