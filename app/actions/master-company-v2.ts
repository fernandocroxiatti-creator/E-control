"use server";

import { revalidatePath } from "next/cache";
import { requireMasterUser } from "@/lib/master/authorization";
import { getSupabaseEnv } from "@/lib/supabase/env";
import { isAuthorizedSupabaseTarget } from "@/lib/supabase/homologation-env";
import { createClient } from "@/lib/supabase/server";
import { validateBranchMetadata, validateCompanyMetadata, normalizeStatus } from "@/lib/companies/management-validation";

export type MasterMutationState = { status: "idle" | "success" | "error"; message?: string; entityId?: string };
const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[1-8][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i;

async function getAuthorizedMutationClient(requiresCompanyCreation = false) {
  const env = getSupabaseEnv();
  if (!env || !isAuthorizedSupabaseTarget(env) || !env.companyManagementEnabled
    || (requiresCompanyCreation && !env.companyCreationEnabled)) return null;
  await requireMasterUser();
  const client = await createClient();
  if (!client) return null;
  const { data, error } = await client.rpc("master_admin_management_ready");
  if (error || data !== true) return null;
  return client;
}

function rpcErrorState(error: unknown): MasterMutationState {
  const code = typeof error === "object" && error !== null && "code" in error ? String((error as { code?: unknown }).code ?? "") : "";
  if (code === "42501") return { status: "error", message: "A sessão atual não possui autorização para esta operação." };
  if (code === "23505") return { status: "error", message: "Já existe um registro com esse CNPJ ou código dentro das regras cadastradas." };
  if (code === "22023" || code === "P0002") return { status: "error", message: "Os dados não foram aceitos. Confira os campos e o estado atual do registro." };
  return { status: "error", message: "Não foi possível confirmar a operação. Atualize a página antes de tentar novamente." };
}

async function invoke(name: string, args: Record<string, unknown>, requiresCompanyCreation = false): Promise<{ data: unknown; error: unknown | null }> {
  try {
    const client = await getAuthorizedMutationClient(requiresCompanyCreation);
    if (!client) return { data: null, error: new Error("management-not-ready") };
    const { data, error } = await client.rpc(name as never, args as never);
    return { data, error };
  } catch {
    return { data: null, error: new Error("operation-unavailable") };
  }
}

function formString(formData: FormData, key: string): string | null {
  const value = formData.get(key);
  return typeof value === "string" ? value : null;
}

export async function createMasterCompanyAction(_state: MasterMutationState, formData: FormData): Promise<MasterMutationState> {
  const requestId = formString(formData, "request_id");
  const parsed = validateCompanyMetadata({
    legalName: formString(formData, "legal_name"), tradeName: formString(formData, "trade_name"),
    cnpj: formString(formData, "cnpj"), contactEmail: formString(formData, "contact_email"), contactPhone: formString(formData, "contact_phone"),
  });
  if (!requestId || !UUID.test(requestId) || !parsed.valid) return { status: "error", message: parsed.valid ? "Atualize o formulário e tente novamente." : parsed.message };
  const { data, error } = await invoke("master_create_company_v2", {
    p_request_id: requestId, p_legal_name: parsed.value.legalName, p_trade_name: parsed.value.tradeName,
    p_cnpj: parsed.value.cnpj, p_contact_email: parsed.value.contactEmail, p_contact_phone: parsed.value.contactPhone,
  }, true);
  if (error || typeof data !== "string" || !UUID.test(data)) return rpcErrorState(error);
  revalidatePath("/master"); revalidatePath("/master/empresas"); revalidatePath("/master/filiais");
  return { status: "success", entityId: data, message: "Empresa cadastrada e auditada. Nenhum usuário ou acesso empresarial foi criado." };
}

export async function updateMasterCompanyAction(_state: MasterMutationState, formData: FormData): Promise<MasterMutationState> {
  const requestId = formString(formData, "request_id"); const companyId = formString(formData, "company_id");
  const parsed = validateCompanyMetadata({ legalName: formString(formData, "legal_name"), tradeName: formString(formData, "trade_name"), cnpj: formString(formData, "cnpj"), contactEmail: formString(formData, "contact_email"), contactPhone: formString(formData, "contact_phone") });
  if (!requestId || !UUID.test(requestId) || !companyId || !UUID.test(companyId) || !parsed.valid) return { status: "error", message: parsed.valid ? "Identificador de empresa ou solicitação inválido." : parsed.message };
  const { data, error } = await invoke("master_update_company_v2", { p_request_id: requestId, p_company_id: companyId,
    p_legal_name: parsed.value.legalName, p_trade_name: parsed.value.tradeName, p_cnpj: parsed.value.cnpj,
    p_contact_email: parsed.value.contactEmail, p_contact_phone: parsed.value.contactPhone });
  if (error || data !== companyId) return rpcErrorState(error);
  revalidatePath("/master/empresas"); revalidatePath(`/master/empresas/${companyId}`);
  return { status: "success", entityId: companyId, message: "Dados empresariais atualizados e auditados." };
}

export async function setMasterCompanyStatusAction(_state: MasterMutationState, formData: FormData): Promise<MasterMutationState> {
  const requestId = formString(formData, "request_id"); const companyId = formString(formData, "company_id");
  const status = normalizeStatus(formString(formData, "status"), ["active", "suspended"]);
  if (!requestId || !UUID.test(requestId) || !companyId || !UUID.test(companyId) || !status) return { status: "error", message: "Solicitação de situação inválida." };
  const { data, error } = await invoke("master_set_company_status_v2", { p_request_id: requestId, p_company_id: companyId, p_status: status });
  if (error || data !== companyId) return rpcErrorState(error);
  revalidatePath("/master"); revalidatePath("/master/empresas"); revalidatePath(`/master/empresas/${companyId}`);
  return { status: "success", entityId: companyId, message: status === "active" ? "Empresa ativada." : "Empresa suspensa." };
}

export async function createMasterBranchAction(_state: MasterMutationState, formData: FormData): Promise<MasterMutationState> {
  const requestId = formString(formData, "request_id");
  const parsed = validateBranchMetadata({ companyId: formString(formData, "company_id"), code: formString(formData, "code"), name: formString(formData, "name"), cnpj: formString(formData, "cnpj"), address: formString(formData, "address"), isHeadquarters: formString(formData, "is_headquarters") });
  if (!requestId || !UUID.test(requestId) || !parsed.valid) return { status: "error", message: parsed.valid ? "Identificador de solicitação inválido." : parsed.message };
  const v = parsed.value;
  const { data, error } = await invoke("master_create_branch_v2", { p_request_id: requestId, p_company_id: v.companyId, p_code: v.code, p_name: v.name, p_cnpj: v.cnpj, p_address: v.address, p_is_headquarters: v.isHeadquarters });
  if (error || typeof data !== "string" || !UUID.test(data)) return rpcErrorState(error);
  revalidatePath("/master"); revalidatePath("/master/filiais"); revalidatePath(`/master/empresas/${v.companyId}`);
  return { status: "success", entityId: data, message: "Filial cadastrada e auditada." };
}

export async function updateMasterBranchAction(_state: MasterMutationState, formData: FormData): Promise<MasterMutationState> {
  const requestId = formString(formData, "request_id"); const branchId = formString(formData, "branch_id");
  const parsed = validateBranchMetadata({ companyId: formString(formData, "company_id"), code: formString(formData, "code"), name: formString(formData, "name"), cnpj: formString(formData, "cnpj"), address: formString(formData, "address"), isHeadquarters: formString(formData, "is_headquarters") });
  if (!requestId || !UUID.test(requestId) || !branchId || !UUID.test(branchId) || !parsed.valid) return { status: "error", message: parsed.valid ? "Identificador de filial ou solicitação inválido." : parsed.message };
  const v = parsed.value;
  const { data, error } = await invoke("master_update_branch_v2", { p_request_id: requestId, p_branch_id: branchId, p_code: v.code, p_name: v.name, p_cnpj: v.cnpj, p_address: v.address, p_is_headquarters: v.isHeadquarters });
  if (error || data !== branchId) return rpcErrorState(error);
  revalidatePath("/master/filiais"); revalidatePath(`/master/empresas/${v.companyId}`);
  return { status: "success", entityId: branchId, message: "Dados da filial atualizados e auditados." };
}

export async function setMasterBranchStatusAction(_state: MasterMutationState, formData: FormData): Promise<MasterMutationState> {
  const requestId = formString(formData, "request_id"); const branchId = formString(formData, "branch_id");
  const status = normalizeStatus(formString(formData, "status"), ["active", "inactive"]);
  const companyId = formString(formData, "company_id");
  if (!requestId || !UUID.test(requestId) || !branchId || !UUID.test(branchId) || !companyId || !UUID.test(companyId) || !status) return { status: "error", message: "Solicitação de situação inválida." };
  const { data, error } = await invoke("master_set_branch_status_v2", { p_request_id: requestId, p_branch_id: branchId, p_status: status });
  if (error || data !== branchId) return rpcErrorState(error);
  revalidatePath("/master/filiais"); revalidatePath(`/master/empresas/${companyId}`);
  return { status: "success", entityId: branchId, message: status === "active" ? "Filial ativada." : "Filial suspensa." };
}
