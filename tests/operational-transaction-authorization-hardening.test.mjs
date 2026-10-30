import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { resolve } from "node:path";
import { fileURLToPath } from "node:url";
import test from "node:test";

const root = resolve(fileURLToPath(new URL("..", import.meta.url)));
const read = (file) => readFileSync(resolve(root, file), "utf8");
const migration = read("supabase/migrations/20261030120000_operational_transaction_authorization_hardening.sql");
const behavior = read("tests/sql/operational-transaction-authorization-hardening.sql");
const runner = read("scripts/test-package-01-postgres.sh");

const rpcNames = [
  "operational_list_business_parties", "operational_create_business_party", "operational_update_business_party",
  "operational_set_business_party_status", "operational_create_catalog_item", "operational_update_catalog_item",
  "operational_set_catalog_item_status", "operational_record_inventory_movement", "operational_list_catalog_items",
  "operational_update_catalog_item_cost", "operational_list_inventory_balances", "operational_list_inventory_movements",
  "operational_list_purchase_orders", "operational_create_purchase_order", "operational_update_purchase_order",
];

test("hardening migration preserves private SECURITY DEFINER protection and maps every required operational permission", () => {
  assert.match(migration, /current_user <> 'postgres'/);
  assert.match(migration, /security definer set search_path='' set row_security=off/);
  assert.match(migration, /revoke all on function app_private\.assert_operational_permission[\s\S]*from public,anon,authenticated,service_role/);
  assert.doesNotMatch(migration, /grant execute[\s\S]*assert_operational_permission/);
  for (const code of ["BP01", "MM01", "SV01", "MIGO", "ME21N", "ME23N"]) assert.match(migration, new RegExp(`'${code}'`));
});

test("isolated PostgreSQL suite invokes each operational RPC in allowed and denied tenant contexts", () => {
  assert.match(runner, /20261030120000_operational_transaction_authorization_hardening\.sql/);
  assert.match(runner, /operational-transaction-authorization-hardening\.sql/);
  for (const name of rpcNames) {
    assert.match(behavior, new RegExp(name));
  }
  for (const message of [
    "no membership accepted", "inactive membership accepted", "revoked branch accepted", "pending role accepted",
    "pending permission accepted", "missing grant accepted", "pending transaction accepted", "disabled module accepted",
    "disabled transaction accepted", "cross-company access accepted",
  ]) assert.match(behavior, new RegExp(message));
});
