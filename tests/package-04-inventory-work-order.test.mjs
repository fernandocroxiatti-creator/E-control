import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { resolve } from "node:path";
import { fileURLToPath } from "node:url";
import test from "node:test";

const root = resolve(fileURLToPath(new URL("..", import.meta.url)));
const read = (file) => readFileSync(resolve(root, file), "utf8");
const migration = read("supabase/migrations/20261105100000_inventory_work_order_foundation.sql");
const behavior = read("tests/sql/package-04-inventory-work-order-behavior.sql");
const readModels = read("supabase/migrations/20261110100000_inventory_work_order_read_models.sql");

test("Package 04 creates only pending catalog proposals with closed tables and RPCs", () => {
  for (const code of ["MM02", "MM03", "MB52", "MB51", "MI01", "MI04", "MI07", "ZTR01", "ZOS01", "ZOS02", "ZOS03", "ZOS04"]) assert.match(migration, new RegExp(`'${code}'`));
  assert.match(migration, /Migration must not enable company access/);
  assert.match(migration, /force row level security/);
  assert.match(migration, /revoke all on function public\.operational_create_inventory_transfer/);
  assert.match(migration, /grant execute on function public\.operational_create_inventory_transfer[\s\S]*to authenticated/);
});

test("Package 04 isolated behavior covers transfer idempotency, counts, work-order reservation, consumption, reversal and tenant denial", () => {
  for (const message of ["transfer idempotency failed", "transfer balances are not atomic", "physical count did not apply negative adjustment", "work order consumed inventory more than once or not at all", "work order reversal did not restore inventory", "cross-company work order accepted"]) assert.match(behavior, new RegExp(message));
});

test("Package 05 read models remain authenticated, scoped and fail closed", () => {
  for (const routine of ["operational_list_inventory_count_sessions", "operational_list_inventory_transfers", "operational_get_work_order_detail"]) assert.match(readModels, new RegExp(routine));
  assert.match(readModels, /Prepared only\. Do not apply remotely/);
  for (const permission of ["transaction.inventory.physical.create", "transaction.inventory.physical.count", "transaction.inventory.physical.adjust"]) assert.match(readModels, new RegExp(permission.replaceAll(".", "\\.")));
  assert.match(readModels, /transaction\.inventory\.transfer/);
  assert.match(readModels, /transaction\.service_order\.read/);
  assert.match(readModels, /revoke all on function[\s\S]*service_role/);
  assert.match(readModels, /grant execute on function[\s\S]*to authenticated/);
  assert.doesNotMatch(readModels, /insert into public\.(?:company_transaction_availability|role_permission_grants)/i);
});
