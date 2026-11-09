import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import test from "node:test";

const read = (file) => readFileSync(new URL(`../${file}`, import.meta.url), "utf8");
const catalogPage = read("app/operacional/cadastros/page.tsx");
const purchasesPage = read("app/operacional/compras/page.tsx");
const inventoryPage = read("app/operacional/estoque/page.tsx");
const dashboard = read("app/components/erp-dashboard.tsx");
const proxy = read("proxy.ts");
const migration = read("supabase/migrations/20261109130000_operational_read_authorization_alignment.sql");
const transactionCatalog = read("lib/master/transaction-resolution.ts");
const focus = read("lib/operational/transaction-focus.ts");

test("each published SAP transaction carries a focused route", () => {
  for (const code of ["BP01", "MM01", "SV01", "MIGO", "ME21N", "ME23N"]) assert.match(transactionCatalog, new RegExp(`${code}:[\\s\\S]{0,400}tx=${code}`));
  assert.match(focus, /routeTransactions = new Set<OperationalRouteTransaction>\(\["BP01", "MM01", "SV01", "MIGO", "ME21N", "ME23N"\]\)/);
  assert.match(focus, /return code && routeTransactions\.has/);
});

test("focused pages authorize the requested transaction on the server", () => {
  for (const source of [catalogPage, purchasesPage, inventoryPage]) {
    assert.match(source, /authorizeRouteTransaction/);
    assert.match(source, /A URL não substitui a autorização|URL não substitui a autorização/);
  }
  assert.match(catalogPage, /focusFor/);
  assert.match(purchasesPage, /allowCreate/);
  assert.match(purchasesPage, /allowRead/);
});

test("inventory requires MIGO even on its generic route and uses only MIGO-authorized read models", () => {
  assert.match(inventoryPage, /authorizeRouteTransaction\(client, "MIGO"/);
  assert.doesNotMatch(inventoryPage, /listOperationalProductOptions/);
  assert.match(inventoryPage, /Não foi possível carregar o saldo da filial selecionada/);
  assert.doesNotMatch(inventoryPage, /migration de alinhamento de leitura preparada/);
});

test("menu active state follows the current operational route", () => {
  assert.match(dashboard, /usePathname/);
  for (const section of ["cadastros", "estoque", "compras", "ordens-servico"]) assert.match(dashboard, new RegExp(`/operacional/${section}`));
  assert.match(dashboard, /Abrir e validar a transação conforme suas permissões efetivas/);
  assert.match(dashboard, /withOperationalContext/);
  assert.match(dashboard, /overview-tile-action/);
  assert.match(dashboard, /\/operacional\/estoque\?tx=MIGO/);
  assert.match(dashboard, /Em desenvolvimento/);
});

test("unauthenticated operational routes preserve their exact internal return path", () => {
  assert.match(proxy, /pathname\.startsWith\("\/operacional\/"\)/);
  assert.match(proxy, /loginUrl\.searchParams\.set\("next", `\$\{request\.nextUrl\.pathname\}\$\{request\.nextUrl\.search\}`\)/);
});

test("read-alignment migration is narrow, authenticated and fail-closed", () => {
  assert.match(migration, /Prepared only\. Do not apply remotely/);
  assert.match(migration, /transaction\.masterdata\.party\.manage/);
  assert.match(migration, /transaction\.masterdata\.catalog\.product\.manage/);
  assert.match(migration, /transaction\.inventory\.stock\.move/);
  assert.match(migration, /p_item_type='product'/);
  assert.match(migration, /p_item_type='service'/);
  assert.match(migration, /transaction\.masterdata\.catalog\.read/);
  assert.match(migration, /revoke all on function[\s\S]*service_role/);
  assert.match(migration, /grant execute[\s\S]*to authenticated/);
  assert.doesNotMatch(migration, /insert into public\.role_permission_grants/i);
  assert.doesNotMatch(migration, /insert into public\.company_transaction_availability/i);
});
