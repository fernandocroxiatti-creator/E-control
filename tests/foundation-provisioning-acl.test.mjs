import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { resolve } from "node:path";
import { fileURLToPath } from "node:url";
import test from "node:test";

const projectRoot = resolve(fileURLToPath(new URL("..", import.meta.url)));
const migration = readFileSync(
  resolve(projectRoot, "supabase/migrations/20261020000000_multiempresa_access_foundation.sql"),
  "utf8",
);

const actorParameterFunctions = [
  "assert_provisioning_authorized(uuid, text, uuid)",
  "write_provisioning_audit(text, uuid, uuid, uuid, jsonb)",
  "provision_company(uuid, text, uuid)",
  "provision_branch(uuid, uuid, text, text)",
  "provision_membership(uuid, uuid, uuid)",
  "activate_membership(uuid, uuid, uuid)",
  "set_membership_status(uuid, uuid, uuid, text)",
  "grant_branch_access(uuid, uuid, uuid, uuid)",
  "set_branch_access_status(uuid, uuid, uuid, text)",
  "assign_membership_role(uuid, uuid, uuid, text, uuid)",
  "revoke_membership_role(uuid, uuid, uuid, text, uuid)",
  "grant_role_permission(uuid, text, text)",
  "revoke_role_permission(uuid, text, text)",
];

const signaturePattern = (signature) => {
  const separator = signature.indexOf("(");
  const name = signature.slice(0, separator);
  const args = signature
    .slice(separator + 1, -1)
    .split(", ")
    .map((argument) => argument.replace(/[.*+?^${}()|[\]\\]/g, "\\$&"))
    .join("\\s*,\\s*");
  return `app_private\\.${name}\\(${args}\\)`;
};

test("actor-parameter administrative routines have no API-role EXECUTE grants", () => {
  for (const signature of actorParameterFunctions) {
    const functionPattern = signaturePattern(signature);
    assert.match(
      migration,
      new RegExp(`revoke all on function ${functionPattern} from public, anon, authenticated, service_role;`, "i"),
      `expected complete revoke for ${signature}`,
    );
    assert.doesNotMatch(
      migration,
      new RegExp(`grant\\s+execute\\s+on\\s+function\\s+${functionPattern}\\s+to\\s+(?:public|anon|authenticated|service_role)`, "i"),
      `unexpected EXECUTE grant for ${signature}`,
    );
  }
});

test("migration asserts effective ACLs including inherited privileges and PUBLIC", () => {
  assert.match(migration, /pg_catalog\.has_function_privilege\('anon',\s*function_oid,\s*'EXECUTE'\)/i);
  assert.match(migration, /pg_catalog\.has_function_privilege\('authenticated',\s*function_oid,\s*'EXECUTE'\)/i);
  assert.match(migration, /pg_catalog\.has_function_privilege\('service_role',\s*function_oid,\s*'EXECUTE'\)/i);
  assert.match(migration, /pg_catalog\.aclexplode\([\s\S]*?pg_catalog\.acldefault\('f',\s*routine\.proowner\)/i);
  assert.match(migration, /acl_entry\.grantee\s*=\s*0[\s\S]*?acl_entry\.privilege_type\s*=\s*'EXECUTE'/i);
});

test("read-only authorization helpers retain their authenticated-only grants", () => {
  for (const signature of [
    "is_active_company_member(uuid)",
    "can_access_branch(uuid, uuid)",
    "has_tenant_permission(uuid, text, uuid)",
  ]) {
    const functionPattern = signaturePattern(signature);
    assert.match(
      migration,
      new RegExp(`grant execute on function ${functionPattern} to authenticated;`, "i"),
      `missing authenticated read helper grant for ${signature}`,
    );
  }
});
