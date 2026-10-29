import assert from "node:assert/strict";
import { readdirSync, readFileSync } from "node:fs";
import { resolve } from "node:path";
import { fileURLToPath } from "node:url";
import test from "node:test";

const projectRoot = resolve(fileURLToPath(new URL("..", import.meta.url)));
const foundationMigration = readFileSync(
  resolve(projectRoot, "supabase/migrations/20261020000000_multiempresa_access_foundation.sql"),
  "utf8",
);
const authorizationFoundationMigration = readFileSync(
  resolve(projectRoot, "supabase/migrations/20261022130000_company_authorization_foundation.sql"),
  "utf8",
);
const canonicalMigrations = readdirSync(resolve(projectRoot, "supabase/migrations"))
  .filter((name) => /^\d+_.+\.sql$/.test(name))
  .sort()
  .map((name) => ({ name, sql: readFileSync(resolve(projectRoot, "supabase/migrations", name), "utf8") }));

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

const legacyServiceRoleFunctions = actorParameterFunctions.filter((signature) => ![
  "assert_provisioning_authorized(uuid, text, uuid)",
  "write_provisioning_audit(text, uuid, uuid, uuid, jsonb)",
].includes(signature));

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

test("the canonical migration sequence closes legacy service_role EXECUTE grants", () => {
  for (const signature of actorParameterFunctions) {
    const functionPattern = signaturePattern(signature);
    assert.match(
      foundationMigration,
      new RegExp(`revoke all on function ${functionPattern} from public, anon, authenticated, service_role;`, "i"),
      `expected complete revoke for ${signature}`,
    );
  }
  for (const signature of legacyServiceRoleFunctions) {
    const functionPattern = signaturePattern(signature);
    // The historical foundation granted these operator routines to service_role.
    // The later canonical authorization migration is the security boundary that
    // revokes the grant after the newer auth.uid()-derived APIs are available.
    assert.match(
      foundationMigration,
      new RegExp(`grant\\s+execute\\s+on\\s+function\\s+${functionPattern}\\s+to\\s+service_role`, "i"),
      `expected documented legacy grant for ${signature}`,
    );
    assert.match(
      authorizationFoundationMigration,
      new RegExp(`revoke\\s+execute\\s+on\\s+function\\s+${functionPattern}\\s+from\\s+service_role`, "i"),
      `missing canonical ACL closure for ${signature}`,
    );
    const finalRelevantStatement = canonicalMigrations
      .flatMap(({ name, sql }) => [...sql.matchAll(new RegExp(`(?:grant|revoke)\\s+execute\\s+on\\s+function\\s+${functionPattern}\\s+(?:to|from)\\s+service_role`, "ig"))]
        .map((match) => ({ name, statement: match[0].toLowerCase() })))
      .at(-1);
    assert.ok(finalRelevantStatement, `missing final ACL statement for ${signature}`);
    assert.match(finalRelevantStatement.statement, /^revoke\s+execute/, `later migration reopens ${signature}`);
  }
});

test("migration asserts effective ACLs including inherited privileges and PUBLIC", () => {
  assert.match(authorizationFoundationMigration, /pg_catalog\.has_function_privilege\('anon',\s*legacy_function\.function_oid,\s*'EXECUTE'\)/i);
  assert.match(authorizationFoundationMigration, /pg_catalog\.has_function_privilege\('authenticated',\s*legacy_function\.function_oid,\s*'EXECUTE'\)/i);
  assert.match(authorizationFoundationMigration, /pg_catalog\.has_function_privilege\('service_role',\s*legacy_function\.function_oid,\s*'EXECUTE'\)/i);
  assert.match(authorizationFoundationMigration, /pg_catalog\.aclexplode\([\s\S]*?pg_catalog\.acldefault\('f',\s*procedure_row\.proowner\)/i);
  assert.match(authorizationFoundationMigration, /function_acl\.grantee\s*<>\s*owner_oid/i);
});

test("read-only authorization helpers retain their authenticated-only grants", () => {
  for (const signature of [
    "is_active_company_member(uuid)",
    "can_access_branch(uuid, uuid)",
    "has_tenant_permission(uuid, text, uuid)",
  ]) {
    const functionPattern = signaturePattern(signature);
    assert.match(
      foundationMigration,
      new RegExp(`grant execute on function ${functionPattern} to authenticated;`, "i"),
      `missing authenticated read helper grant for ${signature}`,
    );
  }
});
