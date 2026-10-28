import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { resolve } from "node:path";
import test from "node:test";

const root = resolve(import.meta.dirname, "..");
const migration = readFileSync(resolve(root, "supabase/migrations/20261028120000_install_first_master_bootstrap_disabled.sql"), "utf8");
const page = readFileSync(resolve(root, "app/first-master-bootstrap/page.tsx"), "utf8");
const action = readFileSync(resolve(root, "app/first-master-bootstrap/actions.ts"), "utf8");
const helper = readFileSync(resolve(root, "lib/first-master-bootstrap.ts"), "utf8");

test("installer is disabled by construction and does not embed a production identity", () => {
  assert.match(migration, /create table app_private\.first_master_bootstrap_authorization/);
  assert.match(migration, /enabled boolean not null default false/);
  assert.match(migration, /create function public\.bootstrap_first_master\(\)/);
  assert.match(migration, /auth\.uid\(\)/);
  assert.match(migration, /lock table app_private\.master_admins in exclusive mode/);
  assert.match(migration, /master\.granted/);
  assert.match(migration, /revoke all on function public\.bootstrap_first_master\(\)[\s\S]*?service_role/);
  assert.match(migration, /grant execute on function public\.bootstrap_first_master\(\) to authenticated/);
  assert.doesNotMatch(migration, /c9f9add3|2ffc7a1f|GRANT-APPROVED|INSERT INTO app_private\.first_master_bootstrap_authorization/i);
});

test("temporary invoker is production-only, session-derived, confirmed, and disabled by default", () => {
  assert.match(helper, /ECONTROLL_PROD_FIRST_MASTER_BOOTSTRAP_INVOKER_ENABLED === "true"/);
  assert.match(helper, /target\?\.target === "production"/);
  assert.match(helper, /auth\.getUser\(\)/);
  assert.match(helper, /is_current_first_master_bootstrap_candidate/);
  assert.match(helper, /origin === site\.origin/);
  assert.match(page, /if \(!isFirstMasterBootstrapInvokerEnabled\(\)\) notFound\(\)/);
  assert.match(page, /auth\.getUser\(\)/);
  assert.match(action, /confirm-first-master/);
  assert.match(action, /assertFirstMasterBootstrapCsrf/);
  assert.match(action, /bootstrap_first_master/);
  assert.doesNotMatch(`${page}\n${action}\n${helper}`, /c9f9add3|2ffc7a1f|GRANT-APPROVED|service_role/);
});
