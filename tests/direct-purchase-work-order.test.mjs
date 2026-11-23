import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import test from "node:test";

const migration = readFileSync(new URL("../supabase/migrations/20261123190000_direct_purchase_work_order.sql", import.meta.url), "utf8");
const actions = readFileSync(new URL("../app/actions/operational.ts", import.meta.url), "utf8");
const reads = readFileSync(new URL("../lib/operational/read-model.ts", import.meta.url), "utf8");
const page = readFileSync(new URL("../app/operacional/ordens-servico/page.tsx", import.meta.url), "utf8");
const ui = readFileSync(new URL("../app/components/operational-catalog.tsx", import.meta.url), "utf8");
const sql = readFileSync(new URL("./sql/phase-02-direct-purchase-work-order.sql", import.meta.url), "utf8");
const runner = readFileSync(new URL("../scripts/test-package-01-postgres.sh", import.meta.url), "utf8");

test("Phase 02 direct purchases are isolated, valued as O.S. cost and never as stock", () => {
  for (const needle of [
    "work_order_direct_purchases", "direct_purchase_total", "force row level security",
    "operational_record_work_order_direct_purchase", "operational_list_work_order_direct_purchases", "operational_list_work_order_direct_purchase_totals",
    "transaction.service_order.update", "Direct-purchase request identifier belongs to a different payload",
    "pg_advisory_xact_lock", "Direct purchases are blocked after work-order closing",
    "revoke all on table public.work_order_direct_purchases",
  ]) assert.ok(migration.includes(needle), needle);
  assert.equal(/insert\s+into\s+public\.inventory_movements/i.test(migration), false);
  assert.equal(/insert\s+into\s+public\.work_order_part_reservations/i.test(migration), false);
});

test("Phase 02 UI and server action fail closed until the protected read API exists", () => {
  for (const needle of ["recordWorkOrderDirectPurchaseAction", "operational_record_work_order_direct_purchase", "A compra direta não movimenta estoque"]) assert.ok(actions.includes(needle), needle);
  for (const needle of ["listOperationalWorkOrderDirectPurchases", "listOperationalWorkOrderDirectPurchaseTotals", "OperationalWorkOrderDirectPurchase", "operational_list_work_order_direct_purchase_totals"]) assert.ok(reads.includes(needle), needle);
  for (const needle of ["directPurchasesAvailable", "Registrar compra direta", "não há entrada, reserva ou baixa de estoque"]) assert.ok(ui.includes(needle), needle);
  assert.ok(page.includes("listOperationalWorkOrderDirectPurchases"));
});

test("Phase 02 SQL suite covers the approved direct-purchase contract", () => {
  for (const needle of [
    "T01", "T02", "T03/T16", "T04", "T05", "T06", "T07", "T08", "T10/T11", "T12", "T13", "T14/T18",
    "Direct purchase FORCE RLS missing", "Direct purchase ACL is broad", "rollback;",
  ]) assert.ok(sql.includes(needle), needle);
  for (const needle of ["T09", "T15", "T17", "T18", "run_phase02_direct_pair", "wait_event_type='Lock'"]) assert.ok(runner.includes(needle), needle);
});
