import "server-only";

import { createClient } from "@/lib/supabase/server";

export type OperationalParty = { party_id: string; party_type: "customer" | "supplier" | "both"; legal_name: string; document_number: string | null; contact_email: string | null; contact_phone: string | null; status: "active" | "inactive"; created_at: string };
export type OperationalItem = { item_id: string; item_type: "product" | "service"; code: string; name: string; category: string | null; unit_of_measure: string; current_cost: number; selling_price: number; minimum_stock: number; reorder_point: number; status: "active" | "inactive"; created_at: string };
export type OperationalStock = { item_id: string; code: string; name: string; quantity: number; minimum_stock: number; reorder_point: number; below_reorder_point: boolean };
export type OperationalRead<T> = { status: "ready"; data: T } | { status: "unavailable" };

function records<T>(value: unknown, keys: string[]): value is T[] {
  return Array.isArray(value) && value.every((row) => typeof row === "object" && row !== null && !Array.isArray(row) && keys.every((key) => key in row));
}

async function read<T>(name: string, args: Record<string, string | number | null>): Promise<OperationalRead<T>> {
  const client = await createClient();
  if (!client) return { status: "unavailable" };
  const { data, error } = await client.rpc(name, args);
  return error || data === null ? { status: "unavailable" } : { status: "ready", data: data as T };
}

export async function listOperationalParties(tenantId: string, search: string | null): Promise<OperationalRead<OperationalParty[]>> {
  const result = await read<unknown>("operational_list_business_parties", { p_tenant_id: tenantId, p_search: search, p_party_type: null, p_status: "active", p_limit: 50, p_offset: 0 });
  return result.status === "ready" && records<OperationalParty>(result.data, ["party_id", "party_type", "legal_name", "status", "created_at"])
    ? { status: "ready", data: result.data } : { status: "unavailable" };
}

export async function listOperationalItems(tenantId: string, search: string | null): Promise<OperationalRead<OperationalItem[]>> {
  const result = await read<unknown>("operational_list_catalog_items", { p_tenant_id: tenantId, p_search: search, p_item_type: null, p_status: "active", p_limit: 50, p_offset: 0 });
  return result.status === "ready" && records<OperationalItem>(result.data, ["item_id", "item_type", "code", "name", "unit_of_measure", "status", "created_at"])
    ? { status: "ready", data: result.data } : { status: "unavailable" };
}

export async function listOperationalStock(tenantId: string, branchId: string, search: string | null): Promise<OperationalRead<OperationalStock[]>> {
  const result = await read<unknown>("operational_list_inventory_balances", { p_tenant_id: tenantId, p_branch_id: branchId, p_search: search, p_limit: 50, p_offset: 0 });
  return result.status === "ready" && records<OperationalStock>(result.data, ["item_id", "code", "name", "quantity", "minimum_stock", "reorder_point", "below_reorder_point"])
    ? { status: "ready", data: result.data } : { status: "unavailable" };
}

export type OperationalMembership = { membership_id: string; display_name: string; status: "pending" | "active" | "suspended" | "revoked"; branch_access_mode: string; created_at: string; branch_count: number; role_count: number };

export async function listOperationalMemberships(tenantId: string): Promise<OperationalRead<OperationalMembership[]>> {
  const result = await read<unknown>("company_list_memberships", { p_tenant_id: tenantId });
  return result.status === "ready" && records<OperationalMembership>(result.data, ["membership_id", "display_name", "status", "branch_access_mode", "created_at", "branch_count", "role_count"])
    ? { status: "ready", data: result.data } : { status: "unavailable" };
}
