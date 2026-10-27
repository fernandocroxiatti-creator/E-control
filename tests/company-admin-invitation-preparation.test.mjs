import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { resolve } from "node:path";
import { fileURLToPath } from "node:url";
import test from "node:test";

const root = resolve(fileURLToPath(new URL("..", import.meta.url)));
const page = readFileSync(resolve(root, "app/master/administradores/page.tsx"), "utf8");
const actions = readFileSync(resolve(root, "app/actions/company-admin-invitations.ts"), "utf8");
const migration = readFileSync(resolve(root, "supabase/migrations/20261027180000_company_admin_invitations.sql"), "utf8");

test("administrator screen retains membership reads and exposes the invitation flow", () => {
  assert.match(page, /getMasterCompanies/);
  assert.match(page, /getMasterMemberships/);
  assert.match(page, /CompanyAdminInvitationForm/);
  assert.match(page, /getCompanyAdminInvitations/);
});

test("invitation actions use the SSR session and do not use privileged credentials", () => {
  assert.match(actions, /requireMasterUser\(\)/);
  assert.match(actions, /createClient\(\)/);
  assert.match(actions, /client\.auth\.getUser\(\)/);
  assert.doesNotMatch(actions, /service_role|SUPABASE_SERVICE_ROLE_KEY|console\.(?:log|error)/i);
});

test("database contract keeps the business role fixed and requires its prior approval", () => {
  assert.match(migration, /role_key = 'company_owner'/);
  assert.match(migration, /role_definition\.approval_state = 'approved'/);
  assert.match(migration, /auth\.uid\(\)/);
  assert.match(migration, /token_digest bytea not null unique/);
});
