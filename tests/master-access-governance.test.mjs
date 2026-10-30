import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { resolve } from "node:path";
import { fileURLToPath } from "node:url";
import test from "node:test";

const root = resolve(fileURLToPath(new URL("..", import.meta.url)));
const read = (file) => readFileSync(resolve(root, file), "utf8");
const migration = read("supabase/migrations/20261030100000_master_access_governance.sql");
const actions = read("app/actions/master-access-governance.ts");
const page = read("app/master/permissoes/page.tsx");
const governanceUi = read("app/master/access-governance.tsx");
const environment = read("lib/supabase/homologation-env.ts");

test("Master governance adds pending stock reads without approving catalog access or creating grants", () => {
  const seed = migration.split("create function public.master_set_access_catalog_approval")[0];
  assert.match(migration, /transaction\.inventory\.stock\.read/);
  assert.match(migration, /on conflict \(permission_key\) do nothing/);
  assert.match(migration, /Migration must not approve or grant operational access automatically/);
  assert.doesNotMatch(seed, /insert into public\.role_permission_grants/);
});

test("approval and role grants are session-derived Master-only audited RPCs with narrow ACLs", () => {
  for (const routine of ["master_set_access_catalog_approval", "master_set_role_permission_grant", "master_list_access_control_matrix"]) {
    assert.match(migration, new RegExp(`create function public\\.${routine}`));
  }
  assert.equal((migration.match(/app_private\.assert_current_master\(\)/g) ?? []).length >= 3, true);
  assert.match(migration, /master_access_catalog\.approval_changed/);
  assert.match(migration, /master_role_permission\.' \|\| p_operation/);
  assert.match(migration, /pg_advisory_xact_lock/);
  assert.match(migration, /Approved role and permission are required before granting/);
  assert.match(migration, /from public, anon, authenticated, service_role/);
  assert.doesNotMatch(migration, /grant execute[\s\S]*to service_role/);
});

test("browser actions require the exact configured target, Master session and an explicit governance flag", () => {
  assert.match(actions, /"use server"/);
  assert.match(actions, /env\.accessGovernanceEnabled/);
  assert.match(actions, /requireMasterUser\(\)/);
  assert.match(actions, /client\.auth\.getUser\(\)/);
  assert.equal((actions.match(/formData\.get\("confirmed"\) !== "on"/g) ?? []).length, 2);
  assert.doesNotMatch(actions, /service_role|SUPABASE_SERVICE_ROLE_KEY|console\.(?:log|error)/i);
  assert.match(environment, /ECONTROLL_PROD_ACCESS_GOVERNANCE_ENABLED/);
  assert.match(page, /AccessGovernance/);
});

test("permission console keeps confirmed governance controls while presenting roles, catalog and audit in business language", () => {
  for (const tab of ["Visão geral", "Papéis", "Permissões e transações", "Concessões", "Histórico", "Disponibilidade empresarial"]) {
    assert.match(governanceUi, new RegExp(tab));
  }
  assert.match(governanceUi, /Proprietário empresarial/);
  assert.match(governanceUi, /Cadastro de produtos/);
  assert.match(governanceUi, /Detalhes avançados/);
  assert.match(governanceUi, /name="confirmed" required/);
  assert.match(governanceUi, /setAccessCatalogApprovalAction/);
  assert.match(governanceUi, /setRolePermissionGrantAction/);
  assert.match(page, /getMasterAudit\(50\)/);
  assert.doesNotMatch(page, /CatalogTable/);
  assert.match(governanceUi, /camada de disponibilidade empresarial ainda não está instalada/i);
});

test("the local isolated suite exercises Master denial, approval, grant, idempotency, revocation and audit", () => {
  const behavior = read("tests/sql/master-access-governance-behavior.sql");
  const runner = read("scripts/test-package-01-postgres.sh");
  assert.match(behavior, /non-master approved a catalog item/);
  assert.match(behavior, /idempotent role grant failed/);
  assert.match(behavior, /master role revoke failed/);
  assert.match(behavior, /expected Master governance audit events/);
  assert.match(runner, /20261030100000_master_access_governance\.sql/);
  assert.match(runner, /master-access-governance-behavior\.sql/);
});
