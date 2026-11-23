import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import test from "node:test";

const migration = readFileSync(new URL("../supabase/migrations/20261123200000_direct_purchase_work_order_reversal.sql", import.meta.url), "utf8");
const actions = readFileSync(new URL("../app/actions/operational.ts", import.meta.url), "utf8");
const reads = readFileSync(new URL("../lib/operational/read-model.ts", import.meta.url), "utf8");
const ui = readFileSync(new URL("../app/components/operational-catalog.tsx", import.meta.url), "utf8");
const sql = readFileSync(new URL("./sql/phase-02-direct-purchase-work-order-reversal.sql", import.meta.url), "utf8");
const runner = readFileSync(new URL("../scripts/test-package-01-postgres.sh", import.meta.url), "utf8");

test("T18 reversal model preserves immutable facts and closes access", () => {
  for (const needle of [
    "work_order_direct_purchase_reversals", "unique (tenant_id,direct_purchase_id)",
    "force row level security", "operational_reverse_work_order_direct_purchase",
    "work_order.direct_purchase.reversed", "direct_purchase_total=direct_purchase_total-purchase.total_cost",
    "pg_advisory_xact_lock", "revoke all on table public.work_order_direct_purchase_reversals",
  ]) assert.ok(migration.includes(needle), needle);
  assert.equal(/insert\s+into\s+public\.inventory_movements/i.test(migration), false);
});

test("T18 fails closed without a trustworthy billing contract", () => {
  for (const needle of [
    "assert_work_order_not_billed", "billing status contract is installed",
    "only while the work order is open", "transaction.service_order.update",
  ]) assert.ok(migration.includes(needle), needle);
  for (const needle of ["T18.02", "T18.03/T18.04", "T18.05/T18.06", "T18.16", "T18.17 other-branch", "T18.18 unauthorised", "T18.07–T18.11"]) assert.ok(sql.includes(needle), needle);
  for (const needle of ["run_phase02_direct_reversal", "p02-reversal-first", "p02-reversal-second"]) assert.ok(runner.includes(needle), needle);
});

test("T18 UI reports reversal state and does not bypass billing eligibility", () => {
  for (const needle of ["reverseWorkOrderDirectPurchaseAction", "operational_reverse_work_order_direct_purchase"]) assert.ok(actions.includes(needle), needle);
  for (const needle of ["OperationalWorkOrderDirectPurchaseReversal", "listOperationalWorkOrderDirectPurchaseReversals"]) assert.ok(reads.includes(needle), needle);
  for (const needle of ["Estornar compra direta", "estado de faturamento comprovadamente não faturado", "Estornada"]) assert.ok(ui.includes(needle), needle);
});
