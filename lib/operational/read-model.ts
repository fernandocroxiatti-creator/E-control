import "server-only";

import { createClient } from "@/lib/supabase/server";

export type OperationalParty = { party_id: string; party_type: "customer" | "supplier" | "both"; legal_name: string; document_number: string | null; contact_email: string | null; contact_phone: string | null; status: "active" | "inactive"; created_at: string };
export type OperationalItem = { item_id: string; item_type: "product" | "service"; code: string; name: string; category: string | null; unit_of_measure: string; current_cost: number; selling_price: number; minimum_stock: number; reorder_point: number; status: "active" | "inactive"; created_at: string };
export type OperationalStock = { item_id: string; code: string; name: string; quantity: number; minimum_stock: number; reorder_point: number; below_reorder_point: boolean };
export type OperationalInventoryMovement = { movement_id: string; item_id: string; item_code: string; item_name: string; movement_type: "initial" | "entry" | "exit" | "adjustment_positive" | "adjustment_negative"; quantity: number; balance_after: number; reference_note: string | null; created_at: string };
export type OperationalPurchaseOrder = { purchase_order_id: string; order_number: number; supplier_id: string; supplier_name: string; status: "draft" | "submitted" | "cancelled"; total_amount: number; item_count: number; items: Array<{ item_id: string; quantity: number; unit_price: number }>; created_at: string; updated_at: string };
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

export type OperationalMembership = { membership_id: string; display_name: string; status: "pending" | "active" | "suspended" | "revoked"; branch_access_mode: string; created_at: string; branch_count: number; role_count: number };

export async function listOperationalMemberships(tenantId: string): Promise<OperationalRead<OperationalMembership[]>> {
  const result = await read<unknown>("company_list_memberships", { p_tenant_id: tenantId });
  return result.status === "ready" && records<OperationalMembership>(result.data, ["membership_id", "display_name", "status", "branch_access_mode", "created_at", "branch_count", "role_count"])
    ? { status: "ready", data: result.data } : { status: "unavailable" };
}
