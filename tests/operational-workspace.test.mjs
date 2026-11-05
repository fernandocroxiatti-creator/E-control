import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { resolve } from "node:path";
import { fileURLToPath } from "node:url";
import test from "node:test";

const root = resolve(fileURLToPath(new URL("..", import.meta.url)));
const read = (file) => readFileSync(resolve(root, file), "utf8");

test("business workspace renders only session-authorized companies and branches, without placeholder forms", () => {
  const workspace = read("app/components/companies-workspace.tsx");
  const companies = read("app/empresas/page.tsx");
  const branches = read("app/empresas/filiais/page.tsx");
  const layout = read("app/empresas/layout.tsx");
  assert.match(workspace, /Empresas e filiais visíveis exclusivamente pelo vínculo empresarial/);
  assert.match(workspace, /contexts: AuthorizedTransactionContext\[\]/);
  assert.match(workspace, /operationalContextMessage\(accessStatus\)/);
  assert.match(workspace, /Nenhum formulário demonstrativo foi exibido/);
  assert.doesNotMatch(workspace, /A lista de empresas reais será conectada/);
  assert.match(companies, /getOperationalTransactionContexts/);
  assert.match(branches, /getOperationalTransactionContexts/);
  assert.match(layout, /operationalContextStatus=\{access\.status\}/);
});

test("dashboard distinguishes a pending business context from an operational feature gate", () => {
  const dashboard = read("app/components/erp-dashboard.tsx");
  assert.match(dashboard, /Acesso empresarial pendente/);
  assert.match(dashboard, /operationalContextMessage\(operationalContextStatus\)/);
  assert.match(dashboard, /Contexto empresarial reconhecido · operações protegidas/);
  assert.doesNotMatch(dashboard, /Ambiente em preparação/);
});
