import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import test from "node:test";

const sql = await readFile(new URL("../supabase/migrations/20261126120000_quotation_foundation.sql", import.meta.url), "utf8");
const literal = (value) => new RegExp(value.replace(/[.*+?^${}()|[\]\\]/g, "\\$&"), "i");

test("quotation foundation is tenant-scoped, audited and has no financial or inventory side effect", () => {
  for (const value of ["public.quotations", "public.quotation_lines", "public.quotation_events", "enable row level security", "force row level security", "app_private.write_operational_audit", "transaction.quotation.create", "transaction.quotation.approve"]) assert.match(sql, literal(value));
  assert.doesNotMatch(sql, /insert into public\.(inventory_movements|inventory_balances|accounts_receivable|cash_)/i);
});

test("quotation creation persists snapshots and rejects divergent replays", () => {
  for (const value of ["unit_cost_snapshot", "item_code", "item_name", "unique(tenant_id,request_id)", "pg_advisory_xact_lock", "different payload", "quantity", "discount_percent"]) assert.match(sql, literal(value));
});

test("quotation decisions require scoped approval and an auditable justification", () => {
  assert.match(sql, /operational_decide_quotation/);
  assert.match(sql, /transaction\.quotation\.approve/);
  assert.match(sql, /length\(normalized_reason\) not between 3 and 1000/);
  assert.match(sql, /Only draft quotations may be decided/);
  assert.match(sql, /public\.quotation_decisions/);
  assert.match(sql, /unique\(tenant_id,request_id\)/);
});

test("quotation approval is mapped to ZQT and conversion requires existing work-order contracts", () => {
  for (const value of ["when p_permission_key='transaction.quotation.create' then array['ZQT01']", "when p_permission_key='transaction.quotation.manage' then array['ZQT02']", "when p_permission_key='transaction.quotation.read' then array['ZQT03']", "when p_permission_key='transaction.quotation.approve' then array['ZQT04']", "operational_convert_quotation_to_work_order", "transaction.service_order.create", "transaction.service_order.update", "quotation_work_order_conversions"]) assert.match(sql, literal(value));
  assert.match(sql, /Only an unexpired approved quotation may be converted/);
});
