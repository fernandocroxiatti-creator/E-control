import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { resolve } from "node:path";
import { fileURLToPath } from "node:url";
import test from "node:test";

const root = resolve(fileURLToPath(new URL("..", import.meta.url)));
const read = (file) => readFileSync(resolve(root, file), "utf8");
const migration = read("supabase/migrations/20261029160000_inventory_history_purchase_foundation.sql");
const actions = read("app/actions/operational.ts");
const inventory = read("app/operacional/estoque/page.tsx");
const purchases = read("app/operacional/compras/page.tsx");
const ui = read("app/components/operational-catalog.tsx");
const runner = read("scripts/test-package-01-postgres.sh");

test("inventory history stays branch-scoped, authenticated and bounded", () => {
  assert.match(migration, /create function public\.operational_list_inventory_movements/);
  assert.match(migration, /transaction\.inventory\.stock\.read/);
  assert.match(migration, /m\.tenant_id=p_tenant_id and m\.branch_id=p_branch_id/);
  assert.match(migration, /p_movement_type.*initial.*adjustment_negative/s);
  assert.match(migration, /p_from > p_to/);
  assert.match(migration, /order by m\.created_at desc,m\.id desc limit p_limit offset p_offset/);
  assert.match(migration, /security definer set search_path = '' set row_security = off/);
});

test("purchase orders are tenant-and-branch scoped draft records without automatic effects", () => {
  for (const table of ["purchase_orders", "purchase_order_items"]) {
    assert.match(migration, new RegExp(`create table public\\.${table}`));
    assert.match(migration, new RegExp(`alter table public\\.${table} enable row level security`));
    assert.match(migration, new RegExp(`alter table public\\.${table} force row level security`));
  }
  assert.match(migration, /transaction\.purchasing\.purchase_order\.read/);
  assert.match(migration, /\('ME23N', 'PUR', 'transaction\.purchasing\.purchase_order\.read'\)/);
  assert.match(migration, /status in \('draft','submitted','cancelled'\)/);
  assert.match(migration, /purchase_order\.created/);
  assert.match(migration, /purchase_order\.updated/);
  assert.match(migration, /purchase_order_update_requests/);
  assert.match(migration, /pg_advisory_xact_lock/);
  assert.doesNotMatch(migration, /operational_record_inventory_movement\(/);
  assert.doesNotMatch(migration, /accounts_payable|financial_posting/i);
});

test("new operational RPCs have narrow ACLs and no automatic grants", () => {
  assert.match(migration, /revoke all on function public\.operational_list_inventory_movements[\s\S]*from public,anon,authenticated,service_role/);
  assert.match(migration, /grant execute on function public\.operational_list_inventory_movements[\s\S]*to authenticated/);
  assert.doesNotMatch(migration, /grant execute[\s\S]*to service_role/);
  assert.doesNotMatch(migration, /insert into public\.role_permission_grants/);
  assert.match(runner, /20261029160000_inventory_history_purchase_foundation\.sql/);
  assert.match(runner, /purchase order idempotency failed/);
  assert.match(runner, /unauthenticated inventory history was accepted/);
});

test("browser code uses server actions, the production flag and the authorized RPC contract", () => {
  for (const action of ["createPurchaseOrderAction", "updatePurchaseOrderAction"]) assert.match(actions, new RegExp(`export async function ${action}`));
  assert.match(actions, /env\.operationalEnabled/);
  assert.match(actions, /operational_create_purchase_order/);
  assert.match(actions, /operational_update_purchase_order/);
  assert.doesNotMatch(actions, /service_role|SUPABASE_SERVICE_ROLE_KEY|console\.(?:log|error)/i);
  assert.match(inventory, /listOperationalInventoryMovements/);
  assert.match(inventory, /Produto no histórico/);
  assert.match(inventory, /Tipo de movimento/);
  assert.match(ui, /InventoryMovementHistory/);
  assert.match(purchases, /PurchaseOrders/);
  assert.match(purchases, /ME21N e ME23N aprovadas/);
});
