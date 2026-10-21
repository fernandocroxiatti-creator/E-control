import assert from "node:assert/strict";
import { readFileSync, readdirSync, statSync } from "node:fs";
import { join, relative, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import test from "node:test";
import { checkMasterAuthorization } from "../lib/master/authorization-check.ts";

const projectRoot = resolve(fileURLToPath(new URL("..", import.meta.url)));
const user = { id: "test-user-id", email: "test@example.invalid" };

function mockClient({ authResult, authError, rpcResult, rpcError, authThrows, rpcThrows }) {
  let rpcCalls = 0;
  return {
    client: {
      auth: {
        async getUser() {
          if (authThrows) throw new Error("auth unavailable");
          return { data: { user: authError ? null : authResult }, error: authError ?? null };
        },
      },
      async rpc(name) {
        rpcCalls += 1;
        assert.equal(name, "is_current_user_master");
        if (rpcThrows) throw new Error("rpc unavailable");
        return { data: rpcResult, error: rpcError ?? null };
      },
    },
    rpcCalls: () => rpcCalls,
  };
}

test("returns unauthenticated without calling the RPC when no user exists", async () => {
  const mock = mockClient({ authResult: null });
  assert.deepEqual(await checkMasterAuthorization(mock.client), { status: "unauthenticated" });
  assert.equal(mock.rpcCalls(), 0);
});

test("denies an authenticated user when the RPC returns false", async () => {
  const mock = mockClient({ authResult: user, rpcResult: false });
  assert.deepEqual(await checkMasterAuthorization(mock.client), { status: "denied" });
});

test("allows only an authenticated user when the RPC returns exactly true", async () => {
  const mock = mockClient({ authResult: user, rpcResult: true });
  assert.deepEqual(await checkMasterAuthorization(mock.client), { status: "authorized", user });
});

test("denies when the RPC reports an error", async () => {
  const mock = mockClient({ authResult: user, rpcResult: true, rpcError: new Error("denied") });
  assert.deepEqual(await checkMasterAuthorization(mock.client), { status: "denied" });
});

test("denies unexpected truthy RPC values", async () => {
  for (const rpcResult of ["true", 1, { authorized: true }, null]) {
    const mock = mockClient({ authResult: user, rpcResult });
    assert.deepEqual(await checkMasterAuthorization(mock.client), { status: "denied" });
  }
});

test("fails closed when authentication or the RPC throws", async () => {
  const authFailure = mockClient({ authThrows: true });
  assert.deepEqual(await checkMasterAuthorization(authFailure.client), { status: "unauthenticated" });

  const rpcFailure = mockClient({ authResult: user, rpcThrows: true });
  assert.deepEqual(await checkMasterAuthorization(rpcFailure.client), { status: "denied" });
});

test("all Admin Master pages inherit the guarded, uncached server layout", () => {
  const masterRoot = join(projectRoot, "app/master");
  const layout = readFileSync(join(masterRoot, "layout.tsx"), "utf8");
  assert.match(layout, /requireMasterUser\(\)/);
  assert.match(layout, /dynamic\s*=\s*["']force-dynamic["']/);
  assert.match(layout, /revalidate\s*=\s*0/);

  const pageFiles = [];
  const visit = (directory) => {
    for (const entry of readdirSync(directory)) {
      const path = join(directory, entry);
      if (statSync(path).isDirectory()) visit(path);
      else if (entry === "page.tsx") pageFiles.push(relative(masterRoot, path));
    }
  };
  visit(masterRoot);
  assert.ok(pageFiles.length > 0);
  assert.deepEqual(pageFiles.sort(), [
    "administradores/page.tsx",
    "auditoria/page.tsx",
    "configuracoes/page.tsx",
    "empresas/page.tsx",
    "modulos/page.tsx",
    "page.tsx",
    "planos/page.tsx",
    "solicitacoes/page.tsx",
    "suporte/page.tsx",
    "transacoes/page.tsx",
  ]);
});
