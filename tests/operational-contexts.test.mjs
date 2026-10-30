import assert from "node:assert/strict";
import test from "node:test";
import { operationalContextMessage } from "../lib/companies/authorized-transaction-context.ts";

test("operational context messages distinguish membership, branch and safe fallback blocks", () => {
  assert.match(operationalContextMessage("no_active_membership"), /vínculo empresarial ativo/);
  assert.match(operationalContextMessage("no_authorized_branch"), /filial ativa autorizada/);
  assert.match(operationalContextMessage("unavailable"), /permanece bloqueado por segurança/);
  assert.equal(operationalContextMessage("ready"), "");
});
