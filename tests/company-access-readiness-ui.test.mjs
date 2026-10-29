import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { resolve } from "node:path";
import { fileURLToPath } from "node:url";
import test from "node:test";

const root = resolve(fileURLToPath(new URL("..", import.meta.url)));
const read = (path) => readFileSync(resolve(root, path), "utf8");

test("all invitation mutations enforce the explicit environment flag on the server", () => {
  const actions = read("app/actions/company-admin-invitations.ts");
  for (const action of [
    "createCompanyAdminInvitationAction",
    "revokeCompanyAdminInvitationAction",
    "expireCompanyAdminInvitationsAction",
  ]) {
    const start = actions.indexOf(`export async function ${action}`);
    const end = actions.indexOf("\nexport async function", start + 1);
    const body = actions.slice(start, end < 0 ? undefined : end);
    assert.match(body, /getInvitationClient\(true\)/);
  }
  const acceptStart = actions.indexOf("export async function acceptCompanyAdminInvitationAction");
  const acceptBody = actions.slice(acceptStart);
  assert.match(acceptBody, /env\.companyManagementEnabled \|\| !env\.companyInvitationsEnabled/);
  assert.match(acceptBody, /client\.auth\.getUser\(\)/);
});

test("disabled invitations do not expose write controls in either invitation route", () => {
  const list = read("app/master/company-admin-invitations.tsx");
  const acceptPage = read("app/convites/aceitar/page.tsx");
  const acceptForm = read("app/convites/aceitar/accept-invitation-form.tsx");
  assert.match(list, /enabled && rows\.some/);
  assert.match(list, /enabled && row\.status === "pending"/);
  assert.match(list, /lista abaixo é somente leitura/);
  assert.match(acceptPage, /companyInvitationsEnabled/);
  assert.match(acceptForm, /enabled && authenticated/);
  assert.match(acceptForm, /convites empresariais estão desativados/);
});

test("membership and catalog screens retain server-authorized data and do not promise unavailable commands", () => {
  const users = read("app/master/administradores/page.tsx");
  const ui = read("app/master/master-data-ui.tsx");
  const permissions = read("app/master/permissoes/page.tsx");
  const transactions = read("app/master/transacoes/page.tsx");
  assert.match(users, /getMasterMemberships\(empresa\)/);
  assert.match(users, /Buscar nos vínculos visíveis/);
  assert.match(users, /Buscar nos convites visíveis/);
  assert.match(users, /filteredInvitations/);
  assert.match(users, /convite\?: string/);
  assert.match(users, /o convite de funcionários/);
  assert.match(users, /Nenhum botão de alteração é exibido/);
  assert.match(ui, /Não expostos pela API segura atual/);
  assert.match(ui, /company_owner: "Administrador principal da empresa"/);
  assert.match(ui, /pending_approval: "Pendente de aprovação"/);
  assert.match(ui, /Nenhum item corresponde à busca/);
  assert.match(permissions, /getMasterAccessCatalog/);
  assert.match(permissions, /filteredCatalog/);
  assert.match(permissions, /Buscar no catálogo/);
  assert.match(permissions, /Nenhuma alteração de papel ou concessão é permitida/);
  assert.match(transactions, /Catálogo instalado, consulta Master pendente/);
  assert.doesNotMatch(transactions, /Não há migration de catálogo instalada/);
});
