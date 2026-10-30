"use server";

import { revalidatePath } from "next/cache";
import { requireMasterUser } from "@/lib/master/authorization";
import { getSupabaseEnv } from "@/lib/supabase/env";
import { isAuthorizedSupabaseTarget } from "@/lib/supabase/homologation-env";
import { createClient } from "@/lib/supabase/server";

export type MasterAccessActionState = { status: "idle" | "success" | "error"; message?: string };
export const masterAccessIdle: MasterAccessActionState = { status: "idle" };

const itemTypes = new Set(["role", "permission", "transaction"]);
const states = new Set(["pending_approval", "approved", "retired"]);
const operations = new Set(["grant", "revoke"]);

function text(formData: FormData, field: string, max = 120) {
  const value = formData.get(field);
  return typeof value === "string" ? value.trim().slice(0, max) : "";
}

async function governanceClient() {
  const env = getSupabaseEnv();
  if (!env || !isAuthorizedSupabaseTarget(env) || !env.companyManagementEnabled || !env.accessGovernanceEnabled) return null;
  await requireMasterUser();
  const client = await createClient();
  if (!client) return null;
  const { data: { user }, error } = await client.auth.getUser();
  return error || !user ? null : client;
}

export async function setAccessCatalogApprovalAction(
  _state: MasterAccessActionState,
  formData: FormData,
): Promise<MasterAccessActionState> {
  if (formData.get("confirmed") !== "on") {
    return { status: "error", message: "Confirmação explícita obrigatória." };
  }
  const itemType = text(formData, "item_type", 16);
  const itemKey = text(formData, "item_key", 120);
  const approvalState = text(formData, "approval_state", 24);
  if (!itemTypes.has(itemType) || !itemKey || !states.has(approvalState)) {
    return { status: "error", message: "Solicitação de aprovação inválida." };
  }
  try {
    const client = await governanceClient();
    if (!client) return { status: "error", message: "Aprovações administrativas estão desativadas neste ambiente." };
    const { data, error } = await client.rpc("master_set_access_catalog_approval", {
      p_item_type: itemType,
      p_item_key: itemKey,
      p_approval_state: approvalState,
    });
    if (error || data !== approvalState) return { status: "error", message: "A aprovação não foi registrada." };
    revalidatePath("/master/permissoes");
    revalidatePath("/master/administradores");
    revalidatePath("/master/auditoria");
    return { status: "success", message: "Estado do catálogo atualizado e auditado." };
  } catch {
    return { status: "error", message: "A aprovação não foi registrada." };
  }
}

export async function setRolePermissionGrantAction(
  _state: MasterAccessActionState,
  formData: FormData,
): Promise<MasterAccessActionState> {
  if (formData.get("confirmed") !== "on") {
    return { status: "error", message: "Confirmação explícita obrigatória." };
  }
  const roleKey = text(formData, "role_key", 80);
  const permissionKey = text(formData, "permission_key", 120);
  const operation = text(formData, "operation", 16);
  if (!roleKey || !permissionKey || !operations.has(operation)) {
    return { status: "error", message: "Solicitação de concessão inválida." };
  }
  try {
    const client = await governanceClient();
    if (!client) return { status: "error", message: "Concessões administrativas estão desativadas neste ambiente." };
    const { data, error } = await client.rpc("master_set_role_permission_grant", {
      p_role_key: roleKey,
      p_permission_key: permissionKey,
      p_operation: operation,
    });
    if (error || ![operation, "unchanged"].includes(String(data))) return { status: "error", message: "A concessão não foi registrada." };
    revalidatePath("/master/permissoes");
    revalidatePath("/master/administradores");
    revalidatePath("/master/auditoria");
    return { status: "success", message: operation === "grant" ? "Permissão concedida e auditada." : "Permissão revogada e auditada." };
  } catch {
    return { status: "error", message: "A concessão não foi registrada." };
  }
}

export async function setCompanyTransactionAvailabilityAction(_state: MasterAccessActionState, formData: FormData): Promise<MasterAccessActionState> {
  if (formData.get("confirmed") !== "on") return { status: "error", message: "Confirmação explícita obrigatória." };
  const tenantId = text(formData, "tenant_id", 64);
  const codes = formData.getAll("transaction_code").filter((value): value is string => typeof value === "string" && /^[A-Z][A-Z0-9]{1,19}$/.test(value));
  if (!/^[0-9a-f-]{36}$/i.test(tenantId)) return { status: "error", message: "Empresa inválida." };
  try { const client = await governanceClient(); if (!client) return { status: "error", message: "A configuração de acessos por empresa ainda não está ativada." };
    const { data, error } = await client.rpc("master_set_company_transaction_availability", { p_tenant_id: tenantId, p_enabled_transaction_codes: codes });
    if (error || data !== "updated") return { status: "error", message: "As permissões da empresa não foram salvas." };
    revalidatePath("/master/acessos-por-empresa"); revalidatePath("/master/auditoria"); return { status: "success", message: "Permissões da empresa atualizadas e auditadas." };
  } catch { return { status: "error", message: "As permissões da empresa não foram salvas." }; }
}
