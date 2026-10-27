import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { resolve } from "node:path";
import { fileURLToPath } from "node:url";
import test from "node:test";
import {
  normalizeTransactionInput,
  transactionCatalog,
  transactionHasExecutableRoute,
  validateTransactionContext,
  resolveTransactionForSession,
} from "../lib/master/transaction-resolution.ts";

const root = resolve(fileURLToPath(new URL("..", import.meta.url)));
const company = "11111111-1111-4111-8111-111111111111";
const branch = "22222222-2222-4222-8222-222222222222";

function authClient({ user = { id: "user-session" }, error = null, throws = false } = {}) {
  return { auth: { async getUser() { if (throws) throw new Error("private auth error"); return { data: { user }, error }; } } };
}

test("transaction code is normalized and constrained without accepting a route", () => {
  assert.equal(normalizeTransactionInput(" me21n "), "ME21N");
  assert.equal(normalizeTransactionInput("../../admin"), null);
  assert.equal(normalizeTransactionInput(""), null);
  assert.equal(transactionHasExecutableRoute("ME21N"), false);
  assert.equal(transactionCatalog.ME21N.enabled, false);
  assert.equal(transactionCatalog.ME21N.route, null);
});

test("transaction context requires valid company and branch UUIDs", () => {
  assert.equal(validateTransactionContext(company, branch), true);
  assert.equal(validateTransactionContext(company, "other-company-branch"), false);
  assert.equal(validateTransactionContext(null, branch), false);
});

test("transaction lookup denies absent sessions and does not reveal auth errors", async () => {
  assert.deepEqual(await resolveTransactionForSession(authClient({ user: null }), "ME21N"), { status: "unauthenticated" });
  assert.deepEqual(await resolveTransactionForSession(authClient({ error: new Error("sensitive") }), "ME21N"), { status: "unauthenticated" });
  assert.deepEqual(await resolveTransactionForSession(authClient({ throws: true }), "ME21N"), { status: "unauthenticated" });
});

test("transaction lookup requires future tenant/branch authorization and never navigates", async () => {
  assert.deepEqual(await resolveTransactionForSession(authClient(), "ME21N"), { status: "context_required" });
  assert.deepEqual(await resolveTransactionForSession(authClient(), "ZZ999"), { status: "unknown" });
  assert.deepEqual(await resolveTransactionForSession(authClient(), "bad route"), { status: "invalid" });
});

test("transaction authorization calls the authenticated tenant RPC only with valid context", async () => {
  const calls = [];
  const client = {
    ...authClient(),
    async rpc(name, args) {
      calls.push({ name, args });
      return { data: true, error: null };
    },
  };
  assert.deepEqual(await resolveTransactionForSession(client, "me21n", company, branch), { status: "authorized" });
  assert.deepEqual(calls, [{
    name: "authorize_company_transaction",
    args: { p_tenant_id: company, p_branch_id: branch, p_transaction_code: "ME21N" },
  }]);
});

test("transaction authorization fails closed on denied, malformed or failed RPC responses", async () => {
  const context = [company, branch];
  const clientWithRpc = (rpc) => ({ ...authClient(), rpc });
  assert.deepEqual(await resolveTransactionForSession(clientWithRpc(async () => ({ data: false, error: null })), "ME21N", ...context), { status: "denied" });
  assert.deepEqual(await resolveTransactionForSession(clientWithRpc(async () => ({ data: "true", error: null })), "ME21N", ...context), { status: "unavailable" });
  assert.deepEqual(await resolveTransactionForSession(clientWithRpc(async () => ({ data: null, error: new Error("private") })), "ME21N", ...context), { status: "unavailable" });
  assert.deepEqual(await resolveTransactionForSession(clientWithRpc(async () => { throw new Error("private"); }), "ME21N", ...context), { status: "unavailable" });
});

test("read API migration is read-only, session-bound, Master-gated and ACL-restricted", () => {
  const migration = readFileSync(resolve(root, "supabase/migrations/20261023160000_master_admin_read_api.sql"), "utf8");
  assert.match(migration, /auth\.uid\(\)/);
  assert.match(migration, /auth\.role\(\)[\s\S]*authenticated/);
  assert.match(migration, /public\.is_current_user_master\(\) is distinct from true/);
  assert.match(migration, /security definer[\s\S]*set search_path = ''[\s\S]*set row_security = off/i);
  assert.match(migration, /revoke all on function public\.master_admin_summary\(\) from public, anon, authenticated, service_role/i);
  assert.match(migration, /grant execute on function public\.master_admin_summary\(\) to authenticated/i);
  assert.match(migration, /aclexplode\([\s\S]*proacl[\s\S]*acldefault/);
  assert.match(migration, /relrowsecurity[\s\S]*relforcerowsecurity/);
  assert.doesNotMatch(migration, /\b(insert into|update\s+public\.|delete from|truncate)\b/i);
  assert.doesNotMatch(migration, /grant execute on function[^;]*service_role/i);
});

test("Master read UI uses server RPC model and keeps sensitive mutations absent", () => {
  const pages = ["app/master/page.tsx", "app/master/empresas/page.tsx", "app/master/filiais/page.tsx", "app/master/administradores/page.tsx", "app/master/permissoes/page.tsx", "app/master/auditoria/page.tsx"];
  for (const file of pages) assert.ok(readFileSync(resolve(root, file), "utf8").length > 0);
  const model = readFileSync(resolve(root, "lib/master/read-model.ts"), "utf8");
  assert.match(model, /requireMasterUser\(\)/);
  assert.match(model, /client\.rpc\(name/);
  assert.doesNotMatch(model, /\.from\(/);
  const temporaryBootstrapPath = resolve(root, "app/homologation-master-bootstrap/page.tsx");
  assert.throws(() => readFileSync(temporaryBootstrapPath, "utf8"));
});
