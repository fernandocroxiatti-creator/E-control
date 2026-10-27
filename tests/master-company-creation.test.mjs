import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { resolve } from "node:path";
import { fileURLToPath } from "node:url";
import test from "node:test";
import {
  createMasterCompany,
  validateMasterCompanyInput,
} from "../lib/master/company-creation.ts";

const projectRoot = resolve(fileURLToPath(new URL("..", import.meta.url)));
const validRequest = {
  legalName: "Empresa de Teste Ltda.",
  requestId: "11111111-1111-4111-8111-111111111111",
};
const companyId = "22222222-2222-4222-8222-222222222222";

function mockClient({ user = { id: "fictitious-user" }, authError = null, rpcData = companyId, rpcError = null } = {}) {
  const calls = [];
  return {
    calls,
    client: {
      auth: { async getUser() { return { data: { user }, error: authError }; } },
      async rpc(name, args) { calls.push({ name, args }); return { data: rpcData, error: rpcError }; },
    },
  };
}

test("validates and normalizes company name and idempotency UUID", () => {
  assert.deepEqual(validateMasterCompanyInput("  Teste Ltda.  ", validRequest.requestId.toUpperCase()), {
    legalName: "Teste Ltda.",
    requestId: validRequest.requestId,
  });
  assert.equal(validateMasterCompanyInput("   ", validRequest.requestId), null);
  assert.equal(validateMasterCompanyInput("x".repeat(201), validRequest.requestId), null);
  assert.equal(validateMasterCompanyInput(validRequest.legalName, "not-a-uuid"), null);
});

test("does not call the RPC when the authenticated session is absent", async () => {
  const mock = mockClient({ user: null });
  assert.deepEqual(await createMasterCompany(mock.client, validRequest), { status: "unauthenticated" });
  assert.equal(mock.calls.length, 0);
});

test("calls only the narrow RPC without an actor identity and returns its company ID", async () => {
  const mock = mockClient();
  assert.deepEqual(await createMasterCompany(mock.client, validRequest), { status: "created", companyId });
  assert.deepEqual(mock.calls, [{
    name: "master_create_company",
    args: { p_request_id: validRequest.requestId, p_legal_name: validRequest.legalName },
  }]);
  assert.equal("p_actor_user_id" in mock.calls[0].args, false);
  assert.equal("user_id" in mock.calls[0].args, false);
});

test("fails closed on authorization errors, RPC errors and malformed results", async () => {
  const denied = mockClient({ rpcError: { code: "42501" } });
  assert.deepEqual(await createMasterCompany(denied.client, validRequest), { status: "denied" });

  const failed = mockClient({ rpcError: { code: "XX000" } });
  assert.deepEqual(await createMasterCompany(failed.client, validRequest), { status: "unavailable" });

  const malformed = mockClient({ rpcData: true });
  assert.deepEqual(await createMasterCompany(malformed.client, validRequest), { status: "unavailable" });
});

test("migration confines persistent idempotency state and company creation to the Master session", () => {
  const migration = readFileSync(resolve(projectRoot, "supabase/migrations/20261022100000_master_create_company.sql"), "utf8");
  assert.match(migration, /auth\.uid\(\)/);
  assert.match(migration, /auth\.role\(\)[\s\S]*authenticated/);
  assert.match(migration, /public\.is_current_user_master\(\) is distinct from true/);
  assert.match(migration, /security definer[\s\S]*set search_path = ''[\s\S]*set row_security = off/i);
  assert.match(migration, /revoke all on function public\.master_create_company\(uuid, text\)[\s\S]*from public, anon, authenticated, service_role/);
  assert.match(migration, /grant execute on function public\.master_create_company\(uuid, text\) to authenticated/);
  assert.match(migration, /aclexplode\([\s\S]*proacl[\s\S]*acldefault/);
  assert.match(migration, /relrowsecurity[\s\S]*relforcerowsecurity/);
  assert.match(migration, /master_company_creation_requests[\s\S]*primary key \(requested_by_user_id, request_id\)/);
  assert.match(migration, /write_provisioning_audit\([\s\S]*'company\.provisioned'/);
  assert.doesNotMatch(migration, /p_actor_user_id|company_memberships|membership_role_assignments/);
  assert.doesNotMatch(migration, /grant execute[^;]*service_role/i);
});

test("server action requires the exact enabled configured target before creating a client", () => {
  const action = readFileSync(resolve(projectRoot, "app/actions/master-company.ts"), "utf8");
  assert.match(action, /isAuthorizedSupabaseTarget\(env\)/);
  assert.match(action, /env\.companyCreationEnabled/);
  assert.ok(action.indexOf("isAuthorizedSupabaseTarget(env)") < action.indexOf("createClient()"));
  assert.match(action, /supabase\.getUser|createMasterCompany\(supabase, input\)/);
});
