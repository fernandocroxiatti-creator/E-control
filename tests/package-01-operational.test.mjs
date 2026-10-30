import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { resolve } from "node:path";
import { fileURLToPath } from "node:url";
import test from "node:test";

const root = resolve(fileURLToPath(new URL("..", import.meta.url)));
const read = (file) => readFileSync(resolve(root, file), "utf8");
const erp = read("supabase/migrations/20261029130000_operational_erp_foundation.sql");
const members = read("supabase/migrations/20261029140000_company_membership_operational_management.sql");
const actions = read("app/actions/operational.ts");
const catalog = read("app/components/operational-catalog.tsx");
const team = read("app/operacional/equipe/page.tsx");
const catalogPage = read("app/operacional/cadastros/page.tsx");
const stockPage = read("app/operacional/estoque/page.tsx");
const operationalReadModel = read("lib/operational/read-model.ts");
const dashboard = read("app/components/erp-dashboard.tsx");
const dashboardPage = read("app/dashboard/page.tsx");

test("operational foundation is tenant-scoped, append-audited and direct-table closed", () => {
  for (const table of ["business_parties", "catalog_items", "catalog_item_cost_history", "inventory_balances", "inventory_movements"]) {
    assert.match(erp, new RegExp(`create table public\\.${table}`));
    assert.match(erp, new RegExp(`alter table public\\.${table} enable row level security`));
    assert.match(erp, new RegExp(`alter table public\\.${table} force row level security`));
  }
  assert.match(erp, /revoke all on table public\.business_parties, public\.catalog_items/);
  assert.match(erp, /create table app_private\.operational_audit_events/);
  assert.match(erp, /catalog_item_cost_history/);
  assert.match(erp, /'MM01', 'MDM', 'transaction\.masterdata\.catalog\.product\.manage'/);
  assert.match(erp, /'SV01', 'MDM', 'transaction\.masterdata\.catalog\.service\.manage'/);
  assert.match(erp, /selling_price numeric\(18,4\).*check \(selling_price >= 0\)/);
  assert.match(erp, /constraint catalog_items_type_stock_check/);
  assert.match(erp, /inventory_movements_tenant_request_unique unique/);
  assert.match(erp, /Negative inventory is not allowed/);
  assert.match(erp, /Initial stock was already recorded/);
  assert.match(erp, /catalog_items_type_stock_check/);
  assert.match(erp, /catalog_item_cost_history/);
  assert.match(erp, /'MM01', 'MDM', 'transaction\.masterdata\.catalog\.product\.manage'/);
  assert.match(erp, /'SV01', 'MDM', 'transaction\.masterdata\.catalog\.service\.manage'/);
  assert.match(erp, /business_party\.status_changed/);
  assert.match(erp, /catalog_item\.status_changed/);
  assert.match(erp, /returning movement\.id,movement\.balance_after into movement_id,balance_after/);
});

test("operational write RPCs derive auth identity, use strict SECURITY DEFINER and keep grants narrow", () => {
  for (const name of ["operational_create_business_party", "operational_create_catalog_item", "operational_update_business_party", "operational_set_business_party_status", "operational_update_catalog_item", "operational_set_catalog_item_status", "operational_record_inventory_movement"]) {
    assert.match(erp, new RegExp(`create function public\\.${name}`));
  }
  assert.match(erp, /assert_operational_permission/);
  assert.match(erp, /coalesce\(auth\.role\(\), ''\) <> 'authenticated'/);
  assert.match(erp, /auth\.uid\(\)/);
  assert.match(erp, /set search_path = '' set row_security = off/g);
  assert.match(erp, /revoke all on function public\.operational_list_business_parties[\s\S]*from public,anon,authenticated,service_role/);
  assert.doesNotMatch(erp, /grant execute[\s\S]*to service_role/);
  assert.match(erp, /pending_approval/);
});

test("employee invitations are single-use, email-bound, branch-scoped and do not activate or assign a role", () => {
  assert.match(members, /company_employee_invitations/);
  assert.match(members, /token_digest bytea not null unique/);
  assert.match(members, /interval '7 days'/);
  assert.match(members, /email_confirmed_at is not null/);
  assert.match(members, /actor_email<>invitation\.recipient_email/);
  assert.match(members, /'pending','assigned_only'/);
  assert.match(members, /company_employee_invitation\.accepted/);
  assert.match(members, /membership\.manage/);
  assert.match(members, /p_status not in \('suspended','revoked'\)/);
  assert.match(members, /company_list_memberships/);
  assert.doesNotMatch(members, /insert into public\.membership_role_assignments/);
});

test("browser-facing operational actions remain server-session and explicit-flag gated", () => {
  assert.match(actions, /"use server"/);
  assert.match(actions, /env\.operationalEnabled/);
  assert.match(actions, /client\.auth\.getUser\(\)/);
  assert.match(actions, /isAuthorizedSupabaseTarget\(env\)/);
  assert.doesNotMatch(actions, /service_role|SUPABASE_SERVICE_ROLE_KEY|console\.(?:log|error)/i);
  assert.match(catalog, /Operações/);
  assert.match(catalog, /Aguardando ativação|Bloqueadas/);
  assert.match(catalog, /InventoryMovementForm/);
  assert.match(catalog, /OperationalTeam/);
  assert.match(actions, /setOperationalMembershipStatusAction/);
  assert.match(team, /listOperationalMemberships/);
});

test("dashboard exposes an authorized business context without bypassing the operational flag", () => {
  assert.match(dashboard, /operationalEnabled = false/);
  assert.match(dashboard, /const operationalReady = operationalEnabled && Boolean\(activeContext\)/);
  assert.match(dashboard, /Acesso empresarial ativo/);
  assert.match(dashboard, /Operações aguardando habilitação/);
  assert.match(dashboard, /Acesso operacional bloqueado/);
  assert.match(dashboard, /companyName.*branchCode.*branchName/s);
  assert.match(dashboardPage, /transactionContexts=\{transactionContexts\}/);
  assert.match(dashboardPage, /operationalEnabled=\{Boolean\(getSupabaseEnv\(\)\?\.operationalEnabled\)\}/);
});

test("operational catalog uses the approved update RPCs and bounded server-side pagination", () => {
  assert.match(actions, /operational_update_business_party/);
  assert.match(actions, /operational_update_catalog_item/);
  assert.match(actions, /updateBusinessPartyAction/);
  assert.match(actions, /updateCatalogItemAction/);
  assert.match(catalog, /Editar cadastro/);
  assert.match(catalog, /Editar item/);
  assert.match(catalogPage, /party_type/);
  assert.match(catalogPage, /item_status/);
  assert.match(catalogPage, /Pagination/);
  assert.match(operationalReadModel, /const PAGE_SIZE = 25/);
  assert.match(operationalReadModel, /p_limit: PAGE_SIZE \+ 1/);
  assert.match(operationalReadModel, /p_offset: \(currentPage - 1\) \* PAGE_SIZE/);
  assert.match(stockPage, /Paginação de saldo/);
  assert.match(stockPage, /Paginação de movimentações/);
  assert.doesNotMatch(actions, /service_role|SUPABASE_SERVICE_ROLE_KEY|console\.(?:log|error)/i);
});
