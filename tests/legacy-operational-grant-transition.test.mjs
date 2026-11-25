import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { resolve } from "node:path";
import { fileURLToPath } from "node:url";
import test from "node:test";

const root = resolve(fileURLToPath(new URL("..", import.meta.url)));
const read = (file) => readFileSync(resolve(root, file), "utf8");
const migration = read("supabase/migrations/20261124120000_transition_legacy_operational_grants.sql");
const behavior = read("tests/sql/legacy-operational-grant-transition-behavior.sql");
const runner = read("scripts/test-package-01-postgres.sh");
const actions = read("app/actions/master-access-governance.ts");
const accessConsole = read("app/master/acessos-por-empresa/company-access-console.tsx");

test("legacy operational grants transition atomically to company and branch scopes", () => {
  assert.match(migration, /lock table public\.role_permission_grants in share row exclusive mode/);
  assert.match(migration, /add column grant_scope text not null default 'branch'/);
  assert.match(migration, /grant_scope = 'company'/);
  assert.match(migration, /unique nulls not distinct \(tenant_id, branch_id, role_key, permission_key\)/);
  assert.match(migration, /Legacy company-scoped operational grant coverage is incomplete/);
  assert.match(migration, /Legacy branch-scoped operational grant coverage is incomplete/);
  assert.match(migration, /delete from public\.role_permission_grants where permission_key like 'transaction\.%'/);
  assert.match(migration, /master_legacy_global_grant\.materialized/);
});

test("authorization removes the global operational fallback and respects permission scope", () => {
  assert.match(migration, /permission\.permission_key not like 'transaction\.%'/);
  assert.match(migration, /permission\.grant_scope = 'company'/);
  assert.match(migration, /permission\.grant_scope = 'branch'/);
  assert.match(migration, /Operational permissions must be administered by company or branch/);
  assert.match(migration, /Permission scope does not match the selected company or branch/);
  assert.match(migration, /security definer/);
  assert.match(migration, /set search_path = ''/);
  assert.match(migration, /set row_security = off/);
});

test("database runner and behavior suite exercise materialization, denial and Master read model", () => {
  assert.match(runner, /20261124120000_transition_legacy_operational_grants\.sql/);
  assert.match(runner, /legacy-operational-grant-transition-behavior\.sql/);
  for (const probe of [
    "legacy global operational grants remained after transition",
    "legacy company-scope grant was not materialized",
    "legacy branch-scope grant was not materialized",
    "transition changed the effective company or branch boundaries",
    "global operational grant was accepted after transition",
  ]) assert.match(behavior, new RegExp(probe));
});

test("Admin Master client keeps the company and branch grant paths explicit", () => {
  assert.match(actions, /setCompanyScopedRolePermissionGrantAction/);
  assert.match(accessConsole, /Permissões por empresa e filial/);
});
