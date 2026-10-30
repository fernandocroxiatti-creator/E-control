import "server-only";

import { createClient } from "@/lib/supabase/server";
import { requireMasterUser } from "@/lib/master/authorization";
import { getSupabaseEnv } from "@/lib/supabase/env";
import { isAuthorizedSupabaseTarget } from "@/lib/supabase/homologation-env";

export type ReadResult<T> =
  | { status: "ready"; data: T }
  | { status: "unavailable" };

export type MasterAuditItem = { event_key: string; created_at: string; event_source?: string };
export type MasterOverview = {
  companies_total: number;
  companies_active: number;
  companies_suspended: number;
  companies_closed: number;
  branches_total: number;
  memberships_active: number;
  master_events_recent: MasterAuditItem[];
  provisioning_events_recent: MasterAuditItem[];
};
export type MasterCompany = {
  company_id: string;
  legal_name: string;
  status: "active" | "suspended" | "closed";
  created_at: string;
  branch_count: number;
  active_membership_count: number;
};
export type MasterCompanyV2 = MasterCompany & {
  trade_name: string | null;
  cnpj: string | null;
  contact_email: string | null;
  contact_phone: string | null;
};
export type MasterCompanyDetail = MasterCompany;
export type MasterBranch = {
  branch_id: string;
  tenant_id: string;
  code: string;
  name: string;
  status: "active" | "inactive";
  created_at: string;
};
export type MasterBranchV2 = MasterBranch & {
  cnpj: string | null;
  address: string | null;
  is_headquarters: boolean;
};
export type MasterMembership = {
  display_name: string | null;
  status: string;
  branch_access_mode: string;
  created_at: string;
};
export type CompanyAdminInvitation = {
  invitation_id: string;
  recipient_email: string;
  role_key: "company_owner";
  status: "pending" | "accepted" | "expired" | "revoked";
  created_at: string;
  expires_at: string;
  accepted_at: string | null;
  revoked_at: string | null;
};
export type MasterCatalogItem = {
  item_type: "role" | "permission" | "role_permission";
  item_key: string;
  display_name: string;
  scope: string | null;
  approval_state: string;
  related_permission_count: number;
};
export type MasterAccessControlEntry = {
  entry_type: "role" | "permission" | "transaction" | "role_permission";
  role_key: string | null;
  permission_key: string | null;
  transaction_code: string | null;
  display_name: string;
  scope: string | null;
  approval_state: string;
};

async function invokeMasterRead<T>(
  name: string,
  args?: Record<string, string | number | null>,
): Promise<ReadResult<T>> {
  // Do not swallow Next's redirect/notFound control-flow thrown by this guard.
  await requireMasterUser();
  try {
    // The RPC also enforces auth.uid()/is_current_user_master() in PostgreSQL.
    const client = await createClient();
    if (!client) return { status: "unavailable" };
    const { data, error } = args ? await client.rpc(name, args) : await client.rpc(name);
    if (error || data === null) return { status: "unavailable" };
    return { status: "ready", data: data as T };
  } catch {
    return { status: "unavailable" };
  }
}

function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === "object" && value !== null && !Array.isArray(value);
}

function isOverview(value: unknown): value is MasterOverview {
  if (!isRecord(value)) return false;
  const counts = ["companies_total", "companies_active", "companies_suspended", "companies_closed", "branches_total", "memberships_active"];
  return counts.every((key) => Number.isSafeInteger(value[key]) && Number(value[key]) >= 0)
    && Array.isArray(value.master_events_recent)
    && Array.isArray(value.provisioning_events_recent);
}

function isArrayOfRecords<T>(value: unknown, required: string[]): value is T[] {
  return Array.isArray(value) && value.every((row) => isRecord(row) && required.every((key) => key in row));
}

export async function getMasterOverview(): Promise<ReadResult<MasterOverview>> {
  const result = await invokeMasterRead<unknown>("master_admin_summary");
  return result.status === "ready" && isOverview(result.data)
    ? { status: "ready", data: result.data }
    : { status: "unavailable" };
}

export async function getMasterCompanies(search: string | null, status: string | null): Promise<ReadResult<MasterCompany[]>> {
  const result = await invokeMasterRead<unknown>("master_admin_list_companies", {
    p_search: search,
    p_status: status,
    p_limit: 100,
    p_offset: 0,
  });
  return result.status === "ready" && isArrayOfRecords<MasterCompany>(result.data,
    ["company_id", "legal_name", "status", "created_at", "branch_count", "active_membership_count"])
    ? { status: "ready", data: result.data }
    : { status: "unavailable" };
}

export async function getMasterBranches(tenantId: string): Promise<ReadResult<MasterBranch[]>> {
  const result = await invokeMasterRead<unknown>("master_admin_list_branches", { p_tenant_id: tenantId });
  return result.status === "ready" && isArrayOfRecords<MasterBranch>(result.data,
    ["branch_id", "tenant_id", "code", "name", "status", "created_at"])
    ? { status: "ready", data: result.data }
    : { status: "unavailable" };
}

export async function getMasterCompany(companyId: string): Promise<ReadResult<MasterCompanyDetail | null>> {
  const result = await invokeMasterRead<unknown>("master_admin_get_company", { p_company_id: companyId });
  if (result.status !== "ready" || !isArrayOfRecords<MasterCompanyDetail>(result.data,
    ["company_id", "legal_name", "status", "created_at", "branch_count", "active_membership_count"])) {
    return { status: "unavailable" };
  }
  return { status: "ready", data: result.data[0] ?? null };
}

export async function getMasterMemberships(tenantId: string): Promise<ReadResult<MasterMembership[]>> {
  const result = await invokeMasterRead<unknown>("master_admin_list_memberships", { p_tenant_id: tenantId });
  return result.status === "ready" && isArrayOfRecords<MasterMembership>(result.data,
    ["display_name", "status", "branch_access_mode", "created_at"])
    ? { status: "ready", data: result.data }
    : { status: "unavailable" };
}

export async function getCompanyAdminInvitations(tenantId: string): Promise<ReadResult<CompanyAdminInvitation[]>> {
  const result = await invokeMasterRead<unknown>("master_list_company_admin_invitations", { p_tenant_id: tenantId });
  return result.status === "ready" && isArrayOfRecords<CompanyAdminInvitation>(result.data,
    ["invitation_id", "recipient_email", "role_key", "status", "created_at", "expires_at", "accepted_at", "revoked_at"])
    ? { status: "ready", data: result.data }
    : { status: "unavailable" };
}

export async function getMasterAccessCatalog(): Promise<ReadResult<MasterCatalogItem[]>> {
  const result = await invokeMasterRead<unknown>("master_admin_list_access_catalog");
  return result.status === "ready" && isArrayOfRecords<MasterCatalogItem>(result.data,
    ["item_type", "item_key", "display_name", "scope", "approval_state", "related_permission_count"])
    ? { status: "ready", data: result.data }
    : { status: "unavailable" };
}

export async function getMasterAccessControlMatrix(): Promise<ReadResult<MasterAccessControlEntry[]>> {
  const result = await invokeMasterRead<unknown>("master_list_access_control_matrix");
  return result.status === "ready" && isArrayOfRecords<MasterAccessControlEntry>(result.data,
    ["entry_type", "role_key", "permission_key", "transaction_code", "display_name", "scope", "approval_state"])
    ? { status: "ready", data: result.data }
    : { status: "unavailable" };
}

export async function getMasterAudit(limit = 50): Promise<ReadResult<MasterAuditItem[]>> {
  const result = await invokeMasterRead<unknown>("master_admin_list_audit", { p_limit: limit });
  return result.status === "ready" && isArrayOfRecords<MasterAuditItem>(result.data,
    ["event_source", "event_key", "created_at"])
    ? { status: "ready", data: result.data }
    : { status: "unavailable" };
}

export async function getMasterCompanyManagementEnabled(): Promise<boolean> {
  const env = getSupabaseEnv();
  if (!env || !isAuthorizedSupabaseTarget(env) || !env.companyManagementEnabled) return false;
  await requireMasterUser();
  try {
    const client = await createClient();
    if (!client) return false;
    const { data, error } = await client.rpc("master_admin_management_ready");
    return !error && data === true;
  } catch {
    return false;
  }
}

export async function getMasterCompanyCreationEnabled(): Promise<boolean> {
  const env = getSupabaseEnv();
  if (!env || !isAuthorizedSupabaseTarget(env) || !env.companyManagementEnabled || !env.companyCreationEnabled) return false;
  await requireMasterUser();
  try {
    const client = await createClient();
    if (!client) return false;
    const { data, error } = await client.rpc("master_admin_management_ready");
    return !error && data === true;
  } catch {
    return false;
  }
}

export async function getMasterCompanyInvitationsEnabled(): Promise<boolean> {
  const env = getSupabaseEnv();
  if (!env || !isAuthorizedSupabaseTarget(env) || !env.companyManagementEnabled || !env.companyInvitationsEnabled) return false;
  await requireMasterUser();
  try {
    const client = await createClient();
    if (!client) return false;
    const { data, error } = await client.rpc("master_admin_management_ready");
    return !error && data === true;
  } catch {
    return false;
  }
}

export async function getMasterAccessGovernanceEnabled(): Promise<boolean> {
  const env = getSupabaseEnv();
  if (!env || !isAuthorizedSupabaseTarget(env) || !env.companyManagementEnabled || !env.accessGovernanceEnabled) return false;
  await requireMasterUser();
  try {
    const client = await createClient();
    if (!client) return false;
    const { data: { user }, error } = await client.auth.getUser();
    return !error && Boolean(user);
  } catch {
    return false;
  }
}

export async function getMasterCompaniesV2(
  search: string | null, status: string | null, limit = 100, offset = 0,
): Promise<ReadResult<MasterCompanyV2[]>> {
  const result = await invokeMasterRead<unknown>("master_admin_list_companies_v2", {
    p_search: search, p_status: status, p_limit: limit, p_offset: offset,
  });
  return result.status === "ready" && isArrayOfRecords<MasterCompanyV2>(result.data,
    ["company_id", "legal_name", "trade_name", "cnpj", "contact_email", "contact_phone", "status", "created_at", "branch_count", "active_membership_count"])
    ? { status: "ready", data: result.data }
    : { status: "unavailable" };
}

export async function getMasterCompanyV2(companyId: string): Promise<ReadResult<MasterCompanyV2 | null>> {
  const result = await invokeMasterRead<unknown>("master_admin_get_company_v2", { p_company_id: companyId });
  if (result.status !== "ready" || !isArrayOfRecords<MasterCompanyV2>(result.data,
    ["company_id", "legal_name", "trade_name", "cnpj", "contact_email", "contact_phone", "status", "created_at", "branch_count", "active_membership_count"])) {
    return { status: "unavailable" };
  }
  return { status: "ready", data: result.data[0] ?? null };
}

export async function getMasterBranchesV2(tenantId: string): Promise<ReadResult<MasterBranchV2[]>> {
  const result = await invokeMasterRead<unknown>("master_admin_list_branches_v2", { p_tenant_id: tenantId });
  return result.status === "ready" && isArrayOfRecords<MasterBranchV2>(result.data,
    ["branch_id", "tenant_id", "code", "name", "cnpj", "address", "is_headquarters", "status", "created_at"])
    ? { status: "ready", data: result.data }
    : { status: "unavailable" };
}
