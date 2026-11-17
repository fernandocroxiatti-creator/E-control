import assert from "node:assert/strict";
import { createHash } from "node:crypto";
import { readFileSync } from "node:fs";
import test from "node:test";

const migration = readFileSync(new URL("../supabase/migrations/20261116180000_purchase_receipt_inventory_valuation.sql", import.meta.url), "utf8");
const actions = readFileSync(new URL("../app/actions/operational.ts", import.meta.url), "utf8");
const purchases = readFileSync(new URL("../app/operacional/compras/page.tsx", import.meta.url), "utf8");
const stock = readFileSync(new URL("../app/operacional/estoque/page.tsx", import.meta.url), "utf8");
const runner = readFileSync(new URL("../scripts/test-package-01-postgres.sh", import.meta.url), "utf8");
const behavior = readFileSync(new URL("./sql/purchase-receipt-inventory-valuation-behavior.sql", import.meta.url), "utf8");

test("Phase 01 migration preserves explicit authorization and no automatic availability", () => {
  for (const needle of [
    "transaction.purchasing.receipt.manage", "transaction.inventory.valuation.initial",
    "('ZGR01','PUR'", "('ZIV01','INV'", "assert_operational_permission",
    "security definer", "set search_path=''", "force row level security",
    "Phase 01 migration must not grant or enable new operational access",
  ]) assert.ok(migration.includes(needle), needle);
  assert.equal(/insert\s+into\s+public\.role_permission_grants/i.test(migration), false);
  assert.equal(/insert\s+into\s+public\.company_transaction_availability/i.test(migration), false);
});

test("Phase 01 migration implements valued, idempotent receipts and safe reversals", () => {
  for (const needle of [
    "purchase_receipts", "purchase_receipt_reversals", "inventory_valuation_events",
    "operational_receive_purchase_order", "operational_reverse_purchase_receipt",
    "operational_record_initial_inventory_valuation", "purchase_receipt_reversal",
    "pg_advisory_xact_lock", "Purchase receipt request identifier belongs to a different payload",
    "Receipt quantity exceeds the remaining quantity", "would violate reserved or unavailable inventory",
    "average_unit_cost", "stock_value", "partially_received",
  ]) assert.ok(migration.includes(needle), needle);
  for (const needle of [
    "lock_inventory_position", "assert_purchase_receipt_reversal_traceability",
    "later outbound inventory event makes its quantity and value untraceable",
    "order by order_item.item_id", "order by receipt_item.item_id",
    "Receipt reversal is blocked by an active work-order reservation",
  ]) assert.ok(migration.includes(needle), needle);
});

test("new server actions use protected RPCs and routes fail closed until migration availability", () => {
  for (const needle of [
    '"operational_submit_purchase_order"', '"operational_receive_purchase_order"',
    '"operational_reverse_purchase_receipt"', '"operational_record_initial_inventory_valuation"', "operational_record_inventory_movement_valued",
  ]) assert.ok(actions.includes(needle), needle);
  assert.ok(purchases.includes("listOperationalPurchaseReceiving"));
  assert.ok(purchases.includes("API correspondente ainda não está disponível"));
  assert.ok(stock.includes("listOperationalInventoryValuation"));
  assert.ok(stock.includes('"ZIV01"'));
  assert.ok(stock.includes("valuation?.status"));
  assert.ok(actions.includes("O estoque foi alterado após esta contagem"));
  assert.ok(runner.includes("20261116180000_purchase_receipt_inventory_valuation.sql"));
  for (const needle of ["moving average receipt valuation", "over-receipt was accepted", "legacy pending valuation", "broad receipt RPC grant detected", "D05 accepted reversal after later outbound", "D05 accepted reversal after transfer", "D05 accepted reversal with active reservation"]) assert.ok(behavior.includes(needle), needle);
  for (const needle of ["receipt-reversal", "multi-receipt-one", "multi-reversal-one", "transfer/reversal D05 handling"]) assert.ok(runner.includes(needle), needle);
});

test("migration digest is stable for this local review", () => {
  assert.equal(createHash("sha256").update(migration).digest("hex"), "f8838d357e68556db1c0fa36ec333b5f0ccde7de449c1b968ca0ea3fb67318d2");
});
