import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { resolve } from "node:path";
import { fileURLToPath } from "node:url";
import test from "node:test";

const root = resolve(fileURLToPath(new URL("..", import.meta.url)));
const read = (file) => readFileSync(resolve(root, file), "utf8");
const migration = read("supabase/migrations/20261118190000_company_scoped_permission_governance.sql");
const pilotEntitlementsMigration = read("supabase/migrations/20261124110000_company_scoped_pilot_operational_entitlements.sql");
const behavior = read("tests/sql/company-scoped-permission-governance-behavior.sql");
const pilotEntitlementsBehavior = read("tests/sql/company-scoped-pilot-operational-entitlements-behavior.sql");
const runner = read("scripts/test-package-01-postgres.sh");
const actions = read("app/actions/master-access-governance.ts");
const companyAccess = read("app/master/acessos-por-empresa/company-access-console.tsx");
const companyAccessPage = read("app/master/acessos-por-empresa/page.tsx");

test("scoped governance is additive, branch-bound, audited and installs with default denial", () => {
  assert.match(migration, /create table public\.company_role_permission_grants/);
  assert.match(migration, /primary key \(tenant_id, branch_id, role_key, permission_key\)/);
  assert.match(migration, /foreign key \(tenant_id, branch_id\) references public\.branches/);
  assert.match(migration, /enable row level security/);
  assert.match(migration, /force row level security/);
  assert.match(migration, /revoke all on table public\.company_role_permission_grants from public, anon, authenticated, service_role/);
  assert.match(migration, /p_branch_id is not null[\s\S]*company_role_permission_grants/);
  assert.match(migration, /Migration must not grant or enable Phase 1 operations automatically/);
  assert.doesNotMatch(migration, /values\s*\(\s*'company_owner'/i);
});

test("Master RPCs require a textual reason and expose only a Master-scoped read model", () => {
  for (const routine of ["master_set_access_catalog_approval", "master_set_role_permission_grant", "master_set_company_transaction_availability", "master_set_company_role_permission_grant", "master_list_company_scoped_permission_grants"]) {
    assert.match(migration, new RegExp(`(?:create )?function public\\.${routine}`));
  }
  assert.match(migration, /length\(normalized_reason\) not between 10 and 1000/);
  assert.match(migration, /app_private\.assert_current_master\(\)/);
  assert.match(migration, /master_company_role_permission\.' \|\| p_operation/);
  assert.match(migration, /A global grant already exists; a company-scoped duplicate is not permitted/);
  assert.match(migration, /p_role_key <> 'company_owner'[\s\S]*p_permission_key <> 'transaction\.purchasing\.receipt\.manage'/);
  assert.match(migration, /grant execute[\s\S]*to authenticated/);
  assert.doesNotMatch(migration, /grant execute[\s\S]*to service_role/);
  assert.match(actions, /setCompanyScopedRolePermissionGrantAction/);
  assert.match(actions, /p_reason: justification/);
  assert.match(companyAccess, /Permissões por empresa e filial/);
  assert.match(companyAccess, /Justificativa auditável/);
});

test("company access readiness distinguishes no selection from an unavailable selected company", () => {
  assert.match(companyAccessPage, /!selected\?"Selecione uma empresa"/);
  assert.match(companyAccessPage, /"Configuração disponível"/);
  assert.match(companyAccessPage, /"Configuração indisponível"/);
  assert.doesNotMatch(companyAccessPage, /Aguardando ativação/);
});

test("pilot operational entitlements remain company- and branch-scoped", () => {
  for (const permission of [
    "transaction.masterdata.party.manage",
    "transaction.masterdata.catalog.product.manage",
    "transaction.masterdata.catalog.product.update",
    "transaction.masterdata.catalog.product.read",
    "transaction.masterdata.catalog.service.manage",
    "transaction.purchasing.purchase_order.create",
    "transaction.purchasing.purchase_order.read",
    "transaction.purchasing.receipt.manage",
  ]) assert.match(pilotEntitlementsMigration, new RegExp(`'${permission}'`));
  assert.match(pilotEntitlementsMigration, /p_role_key <> 'company_owner'/);
  assert.doesNotMatch(pilotEntitlementsMigration, /transaction\.inventory\.valuation\.initial/);
  assert.match(actions, /transaction\\\.\[a-z0-9_\.\]\{1,127\}/);
  assert.match(companyAccess, /Inventário, transferências, O\.S\. e ZIV01 não são habilitados automaticamente/);
  assert.match(pilotEntitlementsBehavior, /ZIV01 permission was accepted/);
  assert.match(pilotEntitlementsBehavior, /crossed a branch, tenant or ZIV01 boundary/);
  assert.match(runner, /20261124110000_company_scoped_pilot_operational_entitlements\.sql/);
});

test("isolated PostgreSQL behavior covers reason rejection, Master-only writes and tenant/branch denial", () => {
  for (const probe of [
    "unprivileged user approved catalog access",
    "legacy governance RPC signatures remained executable without a justification",
    "catalog approval accepted missing justification",
    "company availability accepted missing justification",
    "scoped grant accepted missing justification",
    "scoped governance accepted a non-ZGR01 permission",
    "scoped grant was not idempotent",
    "scoped grant accidentally became global",
    "branch isolation or ZIV01 default denial failed",
    "company scoped grant leaked to another tenant",
  ]) assert.match(behavior, new RegExp(probe));
  assert.match(runner, /20261118190000_company_scoped_permission_governance\.sql/);
  assert.match(runner, /company-scoped-permission-governance-behavior\.sql/);
});
