import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import test from "node:test";

const sql = await readFile(new URL("../supabase/migrations/20261126130000_sales_order_foundation.sql", import.meta.url), "utf8");
const literal = (value) => new RegExp(value.replace(/[.*+?^${}()|[\]\\]/g, "\\$&"), "i");

test("sales orders are tenant-scoped, audited and do not create stock, fiscal or financial facts", () => {
  for (const value of ["public.sales_orders", "public.sales_order_lines", "public.sales_order_events", "enable row level security", "force row level security", "app_private.write_operational_audit", "transaction.sales.order.create", "transaction.sales.order.decide"]) assert.match(sql, literal(value));
  assert.doesNotMatch(sql, /insert into public\.(inventory_movements|inventory_balances|accounts_receivable|cash_|fiscal_)/i);
});

test("sales creation, mutation and quotation conversion are idempotent with immutable snapshots", () => {
  for (const value of ["unique(tenant_id,request_id)", "pg_advisory_xact_lock", "Sales-order request identifier belongs to a different payload", "unit_cost_snapshot", "operational_update_sales_order", "Only independent draft sales orders may be edited", "operational_convert_quotation_to_sales_order", "quotation_sales_order_conversions"]) assert.match(sql, literal(value));
});

test("sales authorization is explicitly mapped to ZVE01 through ZVE04", () => {
  for (const value of ["('ZVE01','SAL'", "('ZVE02','SAL'", "('ZVE03','SAL'", "('ZVE04','SAL'", "when p_permission_key='transaction.sales.order.create' then array['ZVE01']", "when p_permission_key='transaction.sales.order.manage' then array['ZVE02']", "when p_permission_key='transaction.sales.order.read' then array['ZVE03']", "when p_permission_key='transaction.sales.order.decide' then array['ZVE04']"]) assert.match(sql, literal(value));
});
