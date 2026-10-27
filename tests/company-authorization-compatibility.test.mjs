import assert from "node:assert/strict";
import { readFileSync, readdirSync } from "node:fs";
import { resolve } from "node:path";
import { fileURLToPath } from "node:url";
import test from "node:test";

const projectRoot = resolve(fileURLToPath(new URL("..", import.meta.url)));
const migrationRoot = resolve(projectRoot, "supabase/migrations");
const migration = (name) => readFileSync(resolve(migrationRoot, name), "utf8");

const tenantFoundation = migration("20261020000000_multiempresa_access_foundation.sql");
const masterAuthorization = migration("20261021000000_admin_master_authorization.sql");
const firstMasterBootstrap = migration("20261021120000_master_first_bootstrap.sql");
const masterCompanyCreation = migration("20261022100000_master_create_company.sql");
const companyAuthorization = migration("20261022130000_company_authorization_foundation.sql");

test("candidate migration filenames preserve prerequisite chronology", () => {
  const files = readdirSync(migrationRoot).filter((name) => name.endsWith(".sql")).sort();
  assert.ok(files.indexOf("20261020000000_multiempresa_access_foundation.sql") < files.indexOf("20261021000000_admin_master_authorization.sql"));
  assert.ok(files.indexOf("20261021000000_admin_master_authorization.sql") < files.indexOf("20261021120000_master_first_bootstrap.sql"));
  assert.ok(files.indexOf("20261021120000_master_first_bootstrap.sql") < files.indexOf("20261022100000_master_create_company.sql"));
  assert.ok(files.indexOf("20261022100000_master_create_company.sql") < files.indexOf("20261022130000_company_authorization_foundation.sql"));
});

test("company creation remains independent from the actor-parameter legacy routines", () => {
  assert.match(tenantFoundation, /create or replace function app_private\.provision_company\(/);
  assert.match(masterAuthorization, /create or replace function public\.is_current_user_master\(\)/);
  assert.match(firstMasterBootstrap, /bootstrap_first_master/);
  assert.match(masterCompanyCreation, /public\.is_current_user_master\(\) is distinct from true/);
  assert.match(masterCompanyCreation, /insert into public\.companies/);
  assert.doesNotMatch(masterCompanyCreation, /provision_(company|membership|branch)|insert into public\.(company_memberships|membership_role_assignments)/i);
  assert.match(companyAuthorization, /revoke execute on function app_private\.provision_company\(uuid, text, uuid\) from service_role/);
  assert.match(companyAuthorization, /Legacy actor-parameter provisioning routines remain executable by an API role/);
});

test("EC-AUTH-01 does not create or activate the first company administrator", () => {
  assert.match(tenantFoundation, /create table public\.company_memberships/);
  assert.match(tenantFoundation, /approval_state text not null default 'pending_approval'/);
  assert.match(companyAuthorization, /'branch\.manage'[\s\S]*?'pending_approval'/);
  assert.doesNotMatch(companyAuthorization, /insert into public\.(company_memberships|membership_role_assignments|role_permission_grants)/i);
  assert.doesNotMatch(companyAuthorization, /invite|invitation|send.*email|auth\.admin/i);
});

test("legacy service_role provisioning is deliberately unavailable pending a trusted actor contract", () => {
  const legacyFunctions = companyAuthorization.match(/revoke execute on function app_private\.[\s\S]*?from service_role;/g) ?? [];
  assert.equal(legacyFunctions.length, 11);
  assert.match(companyAuthorization, /auth\.uid\(\)/);
  assert.doesNotMatch(companyAuthorization, /grant execute[^;]*service_role/i);
});
