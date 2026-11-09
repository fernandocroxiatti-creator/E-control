import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { resolve } from "node:path";
import { fileURLToPath } from "node:url";
import test from "node:test";

const root = resolve(fileURLToPath(new URL("..", import.meta.url)));
const read = (path) => readFileSync(resolve(root, path), "utf8");
const migration = read("supabase/migrations/20261109100000_company_employee_access_management.sql");
const actions = read("app/actions/operational.ts");
const team = read("app/components/operational-catalog.tsx");
const teamPage = read("app/operacional/equipe/page.tsx");
const acceptance = read("app/convites/funcionario/aceitar/accept-employee-invitation-form.tsx");

test("employee lifecycle migration requires company permissions, preserves pending approval, and never seeds access", () => {
  for (const rpc of ["company_list_employee_invitations", "company_revoke_employee_invitation", "company_activate_employee_membership", "company_list_membership_authorizations"]) {
    assert.match(migration, new RegExp(`create function public\\.${rpc}`));
    assert.match(migration, new RegExp(`alter function public\\.${rpc}`));
  }
  assert.match(migration, /assert_company_membership_permission\(p_tenant_id, 'membership\.invite'\)/);
  assert.match(migration, /assert_company_membership_permission\(p_tenant_id, 'membership\.manage'\)/);
  assert.match(migration, /assert_company_membership_permission\(p_tenant_id, 'membership\.read'\)/);
  assert.match(migration, /target_user_id = actor_id/);
  assert.match(migration, /An active assigned branch is required before activation/);
  assert.match(migration, /company_employee_invitation\.revoked/);
  assert.match(migration, /company_membership\.activated/);
  assert.doesNotMatch(migration, /insert into public\.role_permission_grants/i);
  assert.doesNotMatch(migration, /insert into public\.membership_role_assignments/i);
});

test("employee invitation UI remains session-bound, flag-gated, and does not expose privileged credentials", () => {
  for (const action of ["createEmployeeInvitationAction", "revokeEmployeeInvitationAction", "activateEmployeeMembershipAction", "setOperationalMembershipRoleAction", "setOperationalBranchAccessAction", "acceptEmployeeInvitationAction"]) {
    assert.match(actions, new RegExp(`export async function ${action}`));
  }
  assert.match(actions, /env\.operationalEnabled/);
  assert.match(actions, /inviteUrl\.hash/);
  assert.match(actions, /company_create_employee_invitation/);
  assert.match(actions, /accept_company_employee_invitation/);
  assert.doesNotMatch(actions, /service_role|SUPABASE_SERVICE_ROLE_KEY|console\.(?:log|error)/i);
  assert.match(acceptance, /window\.location\.hash/);
  assert.match(acceptance, /history\.replaceState/);
  assert.match(team, /Aprovar vínculo/);
  assert.match(team, /Administrar acesso/);
  assert.match(team, /O banco recusa autoelevação/);
  assert.match(teamPage, /listOperationalEmployeeInvitations/);
  assert.match(teamPage, /managementAvailable/);
});
