import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { resolve } from "node:path";
import { fileURLToPath } from "node:url";
import test from "node:test";

const root = resolve(fileURLToPath(new URL("..", import.meta.url)));
const read = (file) => readFileSync(resolve(root, file), "utf8");
const migration = read("supabase/migrations/20261109120000_master_membership_authorization_read_api.sql");
const behavior = read("tests/sql/master-membership-authorization-read-api-behavior.sql");
const runner = read("scripts/test-package-01-postgres.sh");

test("Master membership authorization read API is tenant-bounded, authenticated-only and does not seed access", () => {
  assert.match(migration, /create function public\.master_admin_list_membership_authorizations\(p_tenant_id uuid\)/);
  assert.match(migration, /public\.is_current_user_master\(\) is distinct from true/);
  assert.match(migration, /where membership\.tenant_id = p_tenant_id/);
  assert.match(migration, /set search_path = '' set row_security = off/);
  assert.match(migration, /revoke all on function public\.master_admin_list_membership_authorizations\(uuid\) from public, anon, authenticated, service_role/);
  assert.match(migration, /grant execute on function public\.master_admin_list_membership_authorizations\(uuid\) to authenticated/);
  assert.doesNotMatch(migration, /insert into public\.(?:company_memberships|membership_role_assignments|role_permission_grants)/);
  assert.doesNotMatch(migration, /service_role.*grant execute|grant execute.*service_role/i);
});

test("isolated PostgreSQL behavior rejects non-Masters and prevents cross-company role/grant disclosure", () => {
  assert.match(behavior, /non-master read access was accepted/);
  assert.match(behavior, /membership authorizations leaked between companies/);
  assert.match(behavior, /broad Master read API execute grant detected/);
  assert.match(runner, /20261109120000_master_membership_authorization_read_api\.sql/);
  assert.match(runner, /master-membership-authorization-read-api-behavior\.sql/);
});
