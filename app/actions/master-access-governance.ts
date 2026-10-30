"use server";

import { revalidatePath } from "next/cache";
import { requireMasterUser } from "@/lib/master/authorization";
import { getSupabaseEnv } from "@/lib/supabase/env";
import { isAuthorizedSupabaseTarget } from "@/lib/supabase/homologation-env";
import { createClient } from "@/lib/supabase/server";
import type { MasterAccessActionState } from "@/lib/master/action-state";

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

function refreshGovernanceViews() {
  try {
    revalidatePath("/master/permissoes");
    revalidatePath("/master/administradores");
    revalidatePath("/master/auditoria");
    return true;
  } catch {
    // Deliberately avoid logging the database response or session data.
    console.error("[master-governance] revalidation_failed");
    return false;
  }
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
    if (error || data !== approvalState) {
      console.error("[master-governance] catalog_approval_rpc_not_confirmed");
      return { status: "error", message: "Não foi possível confirmar a aprovação. Atualize a página e consulte a auditoria antes de tentar novamente." };
    }
    return refreshGovernanceViews()
      ? { status: "success", message: "Estado do catálogo atualizado e auditado." }
      : { status: "success", message: "A aprovação foi registrada e auditada, mas a tela não pôde ser atualizada. Atualize a página para conferir." };
  } catch {
    console.error("[master-governance] catalog_approval_action_failed");
    return { status: "error", message: "Não foi possível concluir a aprovação. Nenhum sucesso foi confirmado; atualize a página e consulte a auditoria antes de tentar novamente." };
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
    if (error || ![operation, "unchanged"].includes(String(data))) {
      console.error("[master-governance] role_permission_rpc_not_confirmed");
      return { status: "error", message: "Não foi possível confirmar a alteração da concessão. Atualize a página e consulte a auditoria antes de tentar novamente." };
    }
    const message = operation === "grant" ? "Permissão concedida e auditada." : "Permissão revogada e auditada.";
    return refreshGovernanceViews()
      ? { status: "success", message }
      : { status: "success", message: `${message} A tela não pôde ser atualizada; atualize a página para conferir.` };
  } catch {
    console.error("[master-governance] role_permission_action_failed");
    return { status: "error", message: "Não foi possível concluir a alteração da concessão. Nenhum sucesso foi confirmado; atualize a página e consulte a auditoria antes de tentar novamente." };
  }
}

export async function setCompanyTransactionAvailabilityAction(_state: MasterAccessActionState, formData: FormData): Promise<MasterAccessActionState> {
  if (formData.get("confirmed") !== "on") return { status: "error", message: "Confirmação explícita obrigatória." };
  const tenantId = text(formData, "tenant_id", 64);
  const codes = formData.getAll("transaction_code").filter((value): value is string => typeof value === "string" && /^[A-Z][A-Z0-9]{1,19}$/.test(value));
  if (!/^[0-9a-f-]{36}$/i.test(tenantId)) return { status: "error", message: "Empresa inválida." };
  try { const client = await governanceClient(); if (!client) return { status: "error", message: "A configuração de acessos por empresa ainda não está ativada." };
    const { data, error } = await client.rpc("master_set_company_transaction_availability", { p_tenant_id: tenantId, p_enabled_transaction_codes: codes });
    if (error || data !== "updated") {
      console.error("[master-governance] company_access_rpc_not_confirmed");
      return { status: "error", message: "Não foi possível confirmar as permissões da empresa. Atualize a página e consulte a auditoria antes de tentar novamente." };
    }
    try {
      revalidatePath("/master/acessos-por-empresa");
      revalidatePath("/master/auditoria");
      return { status: "success", message: "Permissões da empresa atualizadas e auditadas." };
    } catch {
      console.error("[master-governance] company_access_revalidation_failed");
      return { status: "success", message: "As permissões foram atualizadas e auditadas, mas a tela não pôde ser atualizada. Atualize a página para conferir." };
    }
  } catch {
    console.error("[master-governance] company_access_action_failed");
    return { status: "error", message: "Não foi possível concluir a atualização. Nenhum sucesso foi confirmado; atualize a página e consulte a auditoria antes de tentar novamente." };
  }
}
