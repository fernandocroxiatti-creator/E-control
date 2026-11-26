import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import test from "node:test";

const sql = await readFile(new URL("../supabase/migrations/20261126141000_commercial_billing_foundation.sql", import.meta.url), "utf8");
const actions = await readFile(new URL("../app/actions/operational.ts", import.meta.url), "utf8");
const reads = await readFile(new URL("../lib/operational/read-model.ts", import.meta.url), "utf8");
const route = await readFile(new URL("../app/operacional/faturamento/page.tsx", import.meta.url), "utf8");
const dashboard = await readFile(new URL("../app/components/erp-dashboard.tsx", import.meta.url), "utf8");
const literal = (value) => new RegExp(value.replace(/[.*+?^${}()|[\]\\]/g, "\\$&"), "i");

test("commercial billing is an auditable tenant-scoped status contract, not a fiscal or financial fact", () => {
  for (const value of [
    "public.commercial_billing_documents", "public.commercial_billing_events",
    "enable row level security", "force row level security",
    "transaction.billing.issue", "transaction.billing.read", "transaction.billing.cancel",
    "app_private.write_operational_audit",
  ]) assert.match(sql, literal(value));
  assert.doesNotMatch(sql, /insert into public\.(accounts_receivable|accounts_payable|cash_|inventory_movements|fiscal_)/i);
});

test("billing and cancellation requests are tenant-scoped and reject divergent replays", () => {
  for (const value of [
    "unique(tenant_id,request_id)", "commercial_billing_cancellation_requests",
    "commercial-billing:", "commercial-billing-cancel:",
    "Billing request identifier belongs to a different payload",
    "Billing cancellation request identifier belongs to a different payload",
  ]) assert.match(sql, literal(value));
});

test("direct-purchase reversal remains fail-closed while active work-order billing exists", () => {
  for (const value of [
    "app_private.assert_work_order_not_billed",
    "source_type='work_order'", "d.status='issued'",
    "Direct-purchase reversal is blocked because the work order has active commercial billing",
    "work_order_status not in ('open','closed')",
  ]) assert.match(sql, literal(value));
});

test("billing operations require explicit scoped authorization and are not globally granted", () => {
  for (const value of [
    "app_private.assert_commercial_billing_permission", "app_private.has_tenant_permission",
    "app_private.can_access_branch", "company_module_availability",
    "company_transaction_availability", "grant execute on function public.operational_issue_commercial_billing",
  ]) assert.match(sql, literal(value));
  assert.doesNotMatch(sql, /grant execute[^;]*to\s+(?:public|service_role)/i);
});

test("server actions, read model and interface stay session-scoped and fail closed", () => {
  for (const value of [
    "issueCommercialBillingAction", "cancelCommercialBillingAction", "operational_issue_commercial_billing", "operational_cancel_commercial_billing",
    "listOperationalCommercialBilling", "operational_list_commercial_billing", "authorizeRouteTransaction(client, \"ZFB01\"",
    "authorizeRouteTransaction(client, \"ZFB02\"", "authorizeRouteTransaction(client, \"ZFB03\"", "/operacional/faturamento",
  ]) assert.match(`${actions}\n${reads}\n${route}\n${dashboard}`, literal(value));
  const billingActions = actions.slice(actions.indexOf("export async function issueCommercialBillingAction"), actions.indexOf("export async function setOperationalMembershipStatusAction"));
  assert.doesNotMatch(`${billingActions}\n${reads}\n${route}`, /createAuthAdminClient|service_role/i);
});
