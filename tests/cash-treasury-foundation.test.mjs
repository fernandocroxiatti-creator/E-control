import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import test from "node:test";

const root = new URL("../", import.meta.url);
const read = (path) => readFile(new URL(path, root), "utf8");

test("cash migrations preserve tenant isolation, idempotency and a closed direct-table surface", async () => {
  const [foundation, operations, reads] = await Promise.all([
    read("supabase/migrations/20261126142000_cash_treasury_foundation.sql"),
    read("supabase/migrations/20261126142100_cash_treasury_operations.sql"),
    read("supabase/migrations/20261126142200_cash_treasury_read_models.sql"),
  ]);
  for (const value of ["cash_registers", "cash_sessions", "cash_movements", "enable row level security", "force row level security", "revoke all on table", "ZCX01", "ZCX02", "ZCX03", "ZCX04"]) assert.match(foundation, new RegExp(value, "i"));
  for (const value of ["request_payload", "pg_advisory_xact_lock", "Cash register already has an open session", "Cash session is closed", "Cash movement type and direction do not match", "source_obligation_id", "write_operational_audit"]) assert.match(operations, new RegExp(value, "i"));
  for (const value of ["operational_create_cash_register", "operational_list_cash_registers", "operational_list_cash_sessions", "operational_list_cash_movements", "transaction.cash.register.read", "grant execute", "revoke all on function"]) assert.match(reads, new RegExp(value, "i"));
  assert.doesNotMatch(`${foundation}\n${operations}\n${reads}`, /grant\s+(?:all|select|insert|update|delete)\s+on\s+table/i);
});

test("cash interface remains fail-closed behind scoped transaction authorization", async () => {
  const [page, component, actions] = await Promise.all([
    read("app/operacional/caixa/page.tsx"), read("app/components/cash-treasury.tsx"), read("app/actions/operational.ts"),
  ]);
  for (const value of ["authorizeRouteTransaction", "ZCX01", "ZCX02", "ZCX03", "ZCX04", "CashTreasury"]) assert.match(page, new RegExp(value));
  for (const value of ["createCashRegisterAction", "openCashSessionAction", "recordCashMovementAction", "closeCashSessionAction", "useOperationalRequest", "Caixa não liquida obrigações"]) assert.match(component, new RegExp(value));
  for (const value of ["operational_create_cash_register", "operational_open_cash_session", "operational_record_cash_movement", "operational_close_cash_session"]) assert.match(actions, new RegExp(value));
  assert.match(await read("lib/operational/use-operational-request.ts"), /crypto.randomUUID/);
  assert.match(actions, /revalidatePath\("\/operacional\/caixa"\)/);
});
