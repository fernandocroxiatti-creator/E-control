import "server-only";

import { createClient } from "@/lib/supabase/server";

export type OperationalParty = { party_id: string; party_type: "customer" | "supplier" | "both"; legal_name: string; document_number: string | null; contact_email: string | null; contact_phone: string | null; status: "active" | "inactive"; created_at: string };
export type OperationalItem = { item_id: string; item_type: "product" | "service"; code: string; name: string; category: string | null; unit_of_measure: string; current_cost: number; selling_price: number; minimum_stock: number; reorder_point: number; status: "active" | "inactive"; created_at: string };
export type OperationalStock = { item_id: string; code: string; name: string; quantity: number; minimum_stock: number; reorder_point: number; below_reorder_point: boolean };
export type OperationalInventoryMovement = { movement_id: string; item_id: string; item_code: string; item_name: string; movement_type: "initial" | "entry" | "exit" | "adjustment_positive" | "adjustment_negative" | "transfer_out" | "transfer_in" | "physical_count_in" | "physical_count_out" | "service_consumption" | "service_reversal"; quantity: number; balance_after: number; reference_note: string | null; created_at: string };
export type OperationalPurchaseOrder = { purchase_order_id: string; order_number: number; supplier_id: string; supplier_name: string; status: "draft" | "submitted" | "partially_received" | "received" | "cancelled"; total_amount: number; item_count: number; items: Array<{ item_id: string; quantity: number; unit_price: number }>; created_at: string; updated_at: string };
export type OperationalPurchaseReceivingOrder = { purchase_order_id: string; order_number: number; status: "submitted" | "partially_received" | "received"; supplier_name: string; items: Array<{ purchase_order_item_id: string; item_id: string; item_code: string; item_name: string; ordered_quantity: number; received_quantity: number; pending_quantity: number; ordered_unit_price: number }>; created_at: string; updated_at: string };
export type OperationalPurchaseReceipt = { purchase_receipt_id: string; receipt_number: number; purchase_order_id: string; status: "posted" | "partially_reversed" | "reversed"; document_number: string | null; notes: string | null; items: Array<{ purchase_receipt_item_id: string; item_id: string; received_quantity: number; effective_unit_cost: number; received_value: number; reversed_quantity: number; variance_reason: string | null }>; created_at: string };
export type OperationalInventoryValuation = { item_id: string; item_code: string; item_name: string; quantity: number; valuation_status: "pending" | "valued"; stock_value: number | null; average_unit_cost: number | null; valuation_updated_at: string | null };
export type OperationalWorkOrder = { work_order_id: string; order_number: number; customer_name: string; status: "open" | "in_progress" | "closed" | "cancelled" | "reversed"; total_amount: number; created_at: string; updated_at: string };
export type OperationalWorkOrderDirectPurchase = { direct_purchase_id: string; work_order_id: string; item_id: string | null; item_description: string; quantity: number; unit_cost: number; total_cost: number; supplier_name: string | null; acquisition_source: string; document_reference: string | null; notes: string | null; created_at: string };
export type OperationalWorkOrderDirectPurchaseTotal = { work_order_id: string; total_direct_cost: number };
export type OperationalWorkOrderDirectPurchaseReversal = { direct_purchase_reversal_id: string; direct_purchase_id: string; work_order_id: string; reversed_quantity: number; reversed_total_cost: number; reason: string | null; created_at: string };
export type OperationalInventoryCountSession = { count_session_id: string; status: "open" | "posted"; notes: string | null; created_at: string; posted_at: string | null; line_count: number };
export type OperationalQuotation = { quotation_id: string; quotation_number: number; customer_name: string; status: "draft" | "approved" | "rejected" | "cancelled"; valid_until: string | null; subtotal: number; discount_total: number; total_amount: number; created_at: string; updated_at: string };
export type OperationalRead<T> = { status: "ready"; data: T } | { status: "unavailable" };
export type OperationalPage<T> = OperationalRead<{ rows: T[]; hasMore: boolean; page: number }>;

const PAGE_SIZE = 25;

function requestedPage(value: number | undefined) {
  return Number.isInteger(value) && value && value > 0 ? value : 1;
}

function records<T>(value: unknown, keys: string[]): value is T[] {
  return Array.isArray(value) && value.every((row) => typeof row === "object" && row !== null && !Array.isArray(row) && keys.every((key) => key in row));
}

async function read<T>(name: string, args: Record<string, string | number | null>): Promise<OperationalRead<T>> {
  const client = await createClient();
  if (!client) return { status: "unavailable" };
  const { data, error } = await client.rpc(name, args);
  return error || data === null ? { status: "unavailable" } : { status: "ready", data: data as T };
}

function page<T>(result: OperationalRead<T[]>, value: number): OperationalPage<T> {
  if (result.status !== "ready") return result;
  return { status: "ready", data: { rows: result.data.slice(0, PAGE_SIZE), hasMore: result.data.length > PAGE_SIZE, page: value } };
}

export async function listOperationalParties(tenantId: string, options: { search: string | null; partyType?: string | null; status?: string | null; page?: number }): Promise<OperationalPage<OperationalParty>> {
  const currentPage = requestedPage(options.page);
  const result = await read<unknown>("operational_list_business_parties", { p_tenant_id: tenantId, p_search: options.search, p_party_type: options.partyType ?? null, p_status: options.status ?? null, p_limit: PAGE_SIZE + 1, p_offset: (currentPage - 1) * PAGE_SIZE });
  return result.status === "ready" && records<OperationalParty>(result.data, ["party_id", "party_type", "legal_name", "status", "created_at"])
    ? page({ status: "ready", data: result.data }, currentPage) : { status: "unavailable" };
}

export async function listOperationalSupplierOptions(tenantId: string): Promise<OperationalRead<OperationalParty[]>> {
  const result = await read<unknown>("operational_list_business_parties", { p_tenant_id: tenantId, p_search: null, p_party_type: "supplier", p_status: "active", p_limit: 100, p_offset: 0 });
  return result.status === "ready" && records<OperationalParty>(result.data, ["party_id", "party_type", "legal_name", "status", "created_at"])
    ? { status: "ready", data: result.data } : { status: "unavailable" };
}

export async function listOperationalProductOptions(tenantId: string): Promise<OperationalRead<OperationalItem[]>> {
  const result = await read<unknown>("operational_list_catalog_items", { p_tenant_id: tenantId, p_search: null, p_item_type: "product", p_status: "active", p_limit: 100, p_offset: 0 });
  return result.status === "ready" && records<OperationalItem>(result.data, ["item_id", "item_type", "code", "name", "unit_of_measure", "status", "created_at"])
    ? { status: "ready", data: result.data } : { status: "unavailable" };
}

export async function listOperationalItems(tenantId: string, options: { search: string | null; itemType?: string | null; status?: string | null; page?: number }): Promise<OperationalPage<OperationalItem>> {
  const currentPage = requestedPage(options.page);
  const result = await read<unknown>("operational_list_catalog_items", { p_tenant_id: tenantId, p_search: options.search, p_item_type: options.itemType ?? null, p_status: options.status ?? null, p_limit: PAGE_SIZE + 1, p_offset: (currentPage - 1) * PAGE_SIZE });
  return result.status === "ready" && records<OperationalItem>(result.data, ["item_id", "item_type", "code", "name", "unit_of_measure", "status", "created_at"])
    ? page({ status: "ready", data: result.data }, currentPage) : { status: "unavailable" };
}

export async function listOperationalStock(tenantId: string, branchId: string, options: { search: string | null; page?: number }): Promise<OperationalPage<OperationalStock>> {
  const currentPage = requestedPage(options.page);
  const result = await read<unknown>("operational_list_inventory_balances", { p_tenant_id: tenantId, p_branch_id: branchId, p_search: options.search, p_limit: PAGE_SIZE + 1, p_offset: (currentPage - 1) * PAGE_SIZE });
  return result.status === "ready" && records<OperationalStock>(result.data, ["item_id", "code", "name", "quantity", "minimum_stock", "reorder_point", "below_reorder_point"])
    ? page({ status: "ready", data: result.data }, currentPage) : { status: "unavailable" };
}

export async function listOperationalInventoryMovements(tenantId: string, branchId: string, options: { itemId?: string | null; movementType?: string | null; from?: string | null; to?: string | null; page?: number }): Promise<OperationalPage<OperationalInventoryMovement>> {
  const currentPage = requestedPage(options.page);
  const result = await read<unknown>("operational_list_inventory_movements", { p_tenant_id: tenantId, p_branch_id: branchId, p_item_id: options.itemId ?? null, p_movement_type: options.movementType ?? null, p_from: options.from ?? null, p_to: options.to ?? null, p_limit: PAGE_SIZE + 1, p_offset: (currentPage - 1) * PAGE_SIZE });
  return result.status === "ready" && records<OperationalInventoryMovement>(result.data, ["movement_id", "item_id", "item_code", "item_name", "movement_type", "quantity", "balance_after", "created_at"])
    ? page({ status: "ready", data: result.data }, currentPage) : { status: "unavailable" };
}

export async function listOperationalPurchaseOrders(tenantId: string, branchId: string, options: { search: string | null; status?: string | null; page?: number }): Promise<OperationalPage<OperationalPurchaseOrder>> {
  const currentPage = requestedPage(options.page);
  const result = await read<unknown>("operational_list_purchase_orders", { p_tenant_id: tenantId, p_branch_id: branchId, p_search: options.search, p_status: options.status ?? null, p_limit: PAGE_SIZE + 1, p_offset: (currentPage - 1) * PAGE_SIZE });
  return result.status === "ready" && records<OperationalPurchaseOrder>(result.data, ["purchase_order_id", "order_number", "supplier_id", "supplier_name", "status", "total_amount", "item_count", "items", "created_at", "updated_at"])
    ? page({ status: "ready", data: result.data }, currentPage) : { status: "unavailable" };
}

/** Phase 01 reads intentionally become unavailable until its migration is installed. */
export async function listOperationalPurchaseReceiving(tenantId: string, branchId: string): Promise<OperationalRead<OperationalPurchaseReceivingOrder[]>> {
  const result = await read<unknown>("operational_list_purchase_receiving", { p_tenant_id: tenantId, p_branch_id: branchId, p_limit: 50, p_offset: 0 });
  return result.status === "ready" && records<OperationalPurchaseReceivingOrder>(result.data, ["purchase_order_id", "order_number", "status", "supplier_name", "items", "created_at", "updated_at"])
    ? { status: "ready", data: result.data } : { status: "unavailable" };
}

export async function listOperationalPurchaseReceipts(tenantId: string, branchId: string): Promise<OperationalRead<OperationalPurchaseReceipt[]>> {
  const result = await read<unknown>("operational_list_purchase_receipts", { p_tenant_id: tenantId, p_branch_id: branchId, p_purchase_order_id: null, p_limit: 50, p_offset: 0 });
  return result.status === "ready" && records<OperationalPurchaseReceipt>(result.data, ["purchase_receipt_id", "receipt_number", "purchase_order_id", "status", "items", "created_at"])
    ? { status: "ready", data: result.data } : { status: "unavailable" };
}

export async function listOperationalInventoryValuation(tenantId: string, branchId: string): Promise<OperationalRead<OperationalInventoryValuation[]>> {
  const result = await read<unknown>("operational_list_inventory_valuation", { p_tenant_id: tenantId, p_branch_id: branchId, p_limit: 100, p_offset: 0 });
  return result.status === "ready" && records<OperationalInventoryValuation>(result.data, ["item_id", "item_code", "item_name", "quantity", "valuation_status", "stock_value", "average_unit_cost", "valuation_updated_at"])
    ? { status: "ready", data: result.data } : { status: "unavailable" };
}

export async function listOperationalWorkOrders(tenantId: string, branchId: string, options: { status?: string | null; page?: number }): Promise<OperationalPage<OperationalWorkOrder>> {
  const currentPage = requestedPage(options.page);
  const result = await read<unknown>("operational_list_work_orders", { p_tenant_id: tenantId, p_branch_id: branchId, p_status: options.status ?? null, p_limit: PAGE_SIZE + 1, p_offset: (currentPage - 1) * PAGE_SIZE });
  return result.status === "ready" && records<OperationalWorkOrder>(result.data, ["work_order_id", "order_number", "customer_name", "status", "total_amount", "created_at", "updated_at"])
    ? page({ status: "ready", data: result.data }, currentPage) : { status: "unavailable" };
}

/** Phase 03 reads deliberately fail closed until the quotation migration is installed and ZQT03 is authorized. */
export async function listOperationalQuotations(tenantId: string, branchId: string, options: { status?: string | null; page?: number }): Promise<OperationalPage<OperationalQuotation>> {
  const currentPage = requestedPage(options.page);
  const result = await read<unknown>("operational_list_quotations", { p_tenant_id: tenantId, p_branch_id: branchId, p_status: options.status ?? null, p_limit: PAGE_SIZE + 1, p_offset: (currentPage - 1) * PAGE_SIZE });
  return result.status === "ready" && records<OperationalQuotation>(result.data, ["quotation_id", "quotation_number", "customer_name", "status", "subtotal", "discount_total", "total_amount", "created_at", "updated_at"])
    ? page({ status: "ready", data: result.data }, currentPage) : { status: "unavailable" };
}

/** Phase 02 read API fails closed until its migration is available. */
export async function listOperationalWorkOrderDirectPurchases(tenantId: string, branchId: string): Promise<OperationalRead<OperationalWorkOrderDirectPurchase[]>> {
  const result = await read<unknown>("operational_list_work_order_direct_purchases", { p_tenant_id: tenantId, p_branch_id: branchId, p_work_order_id: null, p_limit: 100, p_offset: 0 });
  return result.status === "ready" && records<OperationalWorkOrderDirectPurchase>(result.data, ["direct_purchase_id", "work_order_id", "item_description", "quantity", "unit_cost", "total_cost", "acquisition_source", "created_at"])
    ? { status: "ready", data: result.data } : { status: "unavailable" };
}

export async function listOperationalWorkOrderDirectPurchaseTotals(tenantId: string, branchId: string): Promise<OperationalRead<OperationalWorkOrderDirectPurchaseTotal[]>> {
  const result = await read<unknown>("operational_list_work_order_direct_purchase_totals", { p_tenant_id: tenantId, p_branch_id: branchId });
  return result.status === "ready" && records<OperationalWorkOrderDirectPurchaseTotal>(result.data, ["work_order_id", "total_direct_cost"])
    ? { status: "ready", data: result.data } : { status: "unavailable" };
}

export async function listOperationalWorkOrderDirectPurchaseReversals(tenantId: string, branchId: string): Promise<OperationalRead<OperationalWorkOrderDirectPurchaseReversal[]>> {
  const result = await read<unknown>("operational_list_work_order_direct_purchase_reversals", { p_tenant_id: tenantId, p_branch_id: branchId, p_work_order_id: null, p_limit: 100, p_offset: 0 });
  return result.status === "ready" && records<OperationalWorkOrderDirectPurchaseReversal>(result.data, ["direct_purchase_reversal_id", "direct_purchase_id", "work_order_id", "reversed_quantity", "reversed_total_cost", "created_at"])
    ? { status: "ready", data: result.data } : { status: "unavailable" };
}

/** Package 05 read API. A missing RPC is intentionally reported as unavailable
 * so a Production deployment remains compatible until its migration is approved. */
export async function listOperationalInventoryCountSessions(tenantId: string, branchId: string): Promise<OperationalRead<OperationalInventoryCountSession[]>> {
  const result = await read<unknown>("operational_list_inventory_count_sessions", { p_tenant_id: tenantId, p_branch_id: branchId, p_status: "open", p_limit: 50, p_offset: 0 });
  return result.status === "ready" && records<OperationalInventoryCountSession>(result.data, ["count_session_id", "status", "notes", "created_at", "posted_at", "line_count"])
    ? { status: "ready", data: result.data } : { status: "unavailable" };
}

export type OperationalMembership = { membership_id: string; display_name: string; status: "pending" | "active" | "suspended" | "revoked"; branch_access_mode: string; created_at: string; branch_count: number; role_count: number };
export type OperationalEmployeeInvitation = { invitation_id: string; recipient_email: string; status: "pending" | "accepted" | "expired" | "revoked"; created_at: string; expires_at: string; accepted_at: string | null; revoked_at: string | null; branch_count: number };
export type OperationalMembershipAuthorization = { membership_id: string; role_key: string; role_display_name: string; scope: "company" | "branch"; branch_id: string | null; branch_name: string | null; granted_permission_count: number };

export async function listOperationalMemberships(tenantId: string): Promise<OperationalRead<OperationalMembership[]>> {
  const result = await read<unknown>("company_list_memberships", { p_tenant_id: tenantId });
  return result.status === "ready" && records<OperationalMembership>(result.data, ["membership_id", "display_name", "status", "branch_access_mode", "created_at", "branch_count", "role_count"])
    ? { status: "ready", data: result.data } : { status: "unavailable" };
}

export async function listOperationalEmployeeInvitations(tenantId: string): Promise<OperationalRead<OperationalEmployeeInvitation[]>> {
  const result = await read<unknown>("company_list_employee_invitations", { p_tenant_id: tenantId });
  return result.status === "ready" && records<OperationalEmployeeInvitation>(result.data,
    ["invitation_id", "recipient_email", "status", "created_at", "expires_at", "accepted_at", "revoked_at", "branch_count"])
    ? { status: "ready", data: result.data } : { status: "unavailable" };
}

export async function listOperationalMembershipAuthorizations(tenantId: string): Promise<OperationalRead<OperationalMembershipAuthorization[]>> {
  const result = await read<unknown>("company_list_membership_authorizations", { p_tenant_id: tenantId });
  return result.status === "ready" && records<OperationalMembershipAuthorization>(result.data,
    ["membership_id", "role_key", "role_display_name", "scope", "branch_id", "branch_name", "granted_permission_count"])
    ? { status: "ready", data: result.data } : { status: "unavailable" };
}
