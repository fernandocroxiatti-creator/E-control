import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import test from "node:test";

const root = new URL("../", import.meta.url);
const sql = await readFile(new URL("supabase/migrations/20261126140500_sales_inventory_fulfillment.sql", root), "utf8");
const salesActions = await readFile(new URL("app/actions/operational.ts", root), "utf8");
const salesUi = await readFile(new URL("app/components/sales-orders.tsx", root), "utf8");
const catalog = await readFile(new URL("lib/master/transaction-resolution.ts", root), "utf8");
const literal = (value) => new RegExp(value.replace(/[.*+?^${}()|[\]\\]/g, "\\$&"), "i");

test("sales inventory facts are tenant scoped, RLS-protected and closed by default", () => {
  for (const value of ["sales_order_inventory_reservations", "sales_order_inventory_requests", "sales_order_inventory_returns", "enable row level security", "force row level security", "revoke all on table", "from public,anon,authenticated,service_role"]) assert.match(sql, literal(value));
  assert.doesNotMatch(sql, /grant\s+(?:all|select|insert|update|delete)\s+on\s+table/i);
});

test("reserve, fulfil, release and return have distinct scoped transaction gates", () => {
  for (const value of ["ZVE05", "ZVE06", "ZVE07", "transaction.sales.inventory.reserve", "transaction.sales.inventory.fulfill", "transaction.sales.inventory.return", "operational_reserve_sales_order_inventory", "operational_fulfill_sales_order", "operational_release_sales_order_inventory", "operational_return_sales_order_inventory"]) assert.match(sql, literal(value));
  for (const value of ["ZVE05", "ZVE06", "ZVE07"]) assert.match(catalog, literal(value));
});

test("stock delivery and return preserve valuation, replay protection and fail closed reversal", () => {
  for (const value of ["sales_delivery", "sales_return", "fulfilled_unit_cost", "pg_advisory_xact_lock", "lock_inventory_position", "unique(tenant_id,request_id)", "belongs to a different payload", "later outbound stock event", "Negative inventory is not allowed", "app_private.write_operational_audit"]) assert.match(sql, literal(value));
  assert.doesNotMatch(sql, /accounts_(?:receivable|payable)|cash_|fiscal_/i);
});

test("server actions and interface use dedicated RPCs rather than a client-side bypass", () => {
  for (const value of ["operational_reserve_sales_order_inventory", "operational_fulfill_sales_order", "operational_release_sales_order_inventory", "operational_return_sales_order_inventory"]) assert.match(salesActions, literal(value));
  for (const value of ["reserveSalesOrderInventoryAction", "fulfillSalesOrderAction", "releaseSalesOrderInventoryAction", "returnSalesOrderInventoryAction"]) assert.match(salesUi, literal(value));
  assert.doesNotMatch(salesUi, /\.rpc\s*\(/i);
});
