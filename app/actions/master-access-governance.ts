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

type CompanyAccessRow = { transaction_code?: unknown; enabled?: unknown };

function companyAccessErrorMessage(code: string | undefined) {
  if (code === "22023") return "Uma transação selecionada ainda não está aprovada globalmente. Revise os estados do catálogo antes de salvar.";
  if (code === "P0002") return "A empresa não está ativa ou não foi encontrada. Atualize a página antes de tentar novamente.";
  if (code === "42501") return "Sua sessão não possui autorização Master para alterar a disponibilidade desta empresa.";
  return "Não foi possível confirmar as permissões da empresa. Atualize a página e consulte a auditoria antes de tentar novamente.";
}

function hasExpectedCompanyAvailability(value: unknown, expectedCodes: string[]) {
  if (!Array.isArray(value)) return false;
  const savedCodes = new Set(
    value.filter((row): row is CompanyAccessRow => typeof row === "object" && row !== null)
      .filter((row) => row.enabled === true && typeof row.transaction_code === "string")
      .map((row) => row.transaction_code as string),
  );
  return savedCodes.size === expectedCodes.length && expectedCodes.every((code) => savedCodes.has(code));
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
  const codes = [...new Set(formData.getAll("transaction_code").filter((value): value is string => typeof value === "string" && /^[A-Z][A-Z0-9]{1,19}$/.test(value)))].sort();
  if (!/^[0-9a-f-]{36}$/i.test(tenantId)) return { status: "error", message: "Empresa inválida." };
  try { const client = await governanceClient(); if (!client) return { status: "error", message: "A configuração de acessos por empresa ainda não está ativada." };
    const { data, error } = await client.rpc("master_set_company_transaction_availability", { p_tenant_id: tenantId, p_enabled_transaction_codes: codes });
    if (error || data !== "updated") {
      console.error(`[master-governance] company_access_rpc_not_confirmed:${error?.code ?? "unexpected_result"}`);
      return { status: "error", message: companyAccessErrorMessage(error?.code) };
    }
    const confirmation = await client.rpc("master_list_company_access", { p_tenant_id: tenantId });
    if (confirmation.error || !hasExpectedCompanyAvailability(confirmation.data, codes)) {
      console.error(`[master-governance] company_access_postcondition_not_confirmed:${confirmation.error?.code ?? "mismatch"}`);
      return { status: "error", message: "A resposta da gravação foi recebida, mas o estado persistido não pôde ser confirmado. Não repita a operação; atualize a página e consulte a auditoria." };
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
