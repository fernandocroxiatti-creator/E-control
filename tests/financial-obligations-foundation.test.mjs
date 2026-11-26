import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import test from "node:test";

const sql = await readFile(new URL("../supabase/migrations/20261126140000_financial_obligations_foundation.sql", import.meta.url), "utf8");
const literal = (value) => new RegExp(value.replace(/[.*+?^${}()|[\]\\]/g, "\\$&"), "i");

test("financial obligations are tenant scoped, RLS forced, audited and direct tables stay closed", () => {
  for (const value of ["public.financial_obligations", "public.financial_installments", "public.financial_settlements", "enable row level security", "force row level security", "app_private.write_operational_audit", "revoke all on table"]) assert.match(sql, literal(value));
  assert.doesNotMatch(sql, /insert into public\.(cash_|bank_|fiscal_)/i);
});

test("obligation creation and settlement use scoped permissions and divergent replay prevention", () => {
  for (const value of ["transaction.finance.payable.manage", "transaction.finance.receivable.manage", "transaction.finance.settlement.manage", "transaction.finance.read", "ZFI01", "ZFI02", "ZFI03", "ZFI04", "pg_advisory_xact_lock", "Financial request identifier belongs to a different payload", "Settlement exceeds installment balance"]) assert.match(sql, literal(value));
});

test("finance mapping preserves sales transaction mappings for coordinated rollout", () => {
  for (const value of ["transaction.sales.order.create' then array['ZVE01']", "transaction.sales.order.manage' then array['ZVE02']", "transaction.sales.order.read' then array['ZVE03']", "transaction.sales.order.decide' then array['ZVE04']"]) assert.match(sql, literal(value));
});

test("settlement reversals are immutable, idempotent and do not create cash or fiscal ledgers", () => {
  for (const value of ["public.financial_settlement_reversals", "unique(tenant_id,settlement_id)", "operational_reverse_financial_settlement", "Financial reversal request identifier belongs to a different payload", "financial_settlement.reversed"]) assert.match(sql, literal(value));
  assert.doesNotMatch(sql, /insert into public\.(cash|bank|fiscal|ledger)/i);
});

test("finance UI uses only authorized, fail-closed operational RPCs", async () => {
  const [actions, page, model] = await Promise.all([
    readFile(new URL("../app/actions/operational.ts", import.meta.url), "utf8"),
    readFile(new URL("../app/operacional/financeiro/page.tsx", import.meta.url), "utf8"),
    readFile(new URL("../lib/operational/read-model.ts", import.meta.url), "utf8"),
  ]);
  for (const rpc of ["operational_create_financial_obligation", "operational_settle_financial_installment", "operational_reverse_financial_settlement", "operational_list_financial_obligations"]) assert.match(`${actions}\n${page}\n${model}`, literal(rpc));
  assert.match(page, /authorizeRouteTransaction/); assert.match(page, /ZFI04/); assert.doesNotMatch(actions, /service_role/i);
});
