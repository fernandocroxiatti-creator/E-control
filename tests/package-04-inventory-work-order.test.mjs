import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { resolve } from "node:path";
import { fileURLToPath } from "node:url";
import test from "node:test";

const root = resolve(fileURLToPath(new URL("..", import.meta.url)));
const read = (file) => readFileSync(resolve(root, file), "utf8");
const migration = read("supabase/migrations/20261105100000_inventory_work_order_foundation.sql");
const behavior = read("tests/sql/package-04-inventory-work-order-behavior.sql");

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
