"use server";
import { revalidatePath } from "next/cache";
import { parseSaasPolicy, parseSaasReactivation } from "@/lib/saas/input";
import { createClient } from "@/lib/supabase/server";
import { getSupabaseEnv } from "@/lib/supabase/env";
import { isAuthorizedSupabaseTarget } from "@/lib/supabase/homologation-env";
import { isCurrentSessionMaster } from "@/lib/master/authorization-check";
export type SaasActionState = { status: "idle" | "success" | "error"; message?: string };
async function masterClient() {
  const env=getSupabaseEnv(); if (!env || !isAuthorizedSupabaseTarget(env) || !env.accessGovernanceEnabled) return null;
  const client=await createClient(); if (!client) return null;
  const { data: { user }, error }=await client.auth.getUser();
  return user && !error && await isCurrentSessionMaster(client) ? client : null;
}
function refresh() { revalidatePath("/master/planos"); revalidatePath("/empresas/assinatura"); revalidatePath("/operacional","layout"); }
export async function saveSaasPolicyAction(_: SaasActionState, form: FormData): Promise<SaasActionState> {
  let input; try { input=parseSaasPolicy(form); } catch(error) { return {status:"error",message:error instanceof Error ? error.message : "Dados inválidos."}; }
  try {
    const client=await masterClient(); if (!client) return {status:"error",message:"Governança indisponível ou sessão sem autorização Master."};
    const {error}=await client.rpc("master_set_saas_company_policy",{p_tenant_id:input.tenantId,p_enforcement_enabled:input.enabled,p_block_on_overdue:input.blockOnOverdue,p_due_on:input.dueOn,p_grace_days:input.graceDays,p_reason:input.reason});
    if(error) return {status:"error",message:"Política não salva. Confirme que a empresa possui uma assinatura e revise os campos."};
    refresh();return {status:"success",message:"Política comercial salva e auditada. As permissões empresariais foram preservadas."};
  } catch {return {status:"error",message:"Não foi possível confirmar a política comercial. Atualize a consulta antes de tentar novamente."};}
}
export async function reactivateSaasCompanyAction(_: SaasActionState, form: FormData): Promise<SaasActionState> {
  let input;try {input=parseSaasReactivation(form);} catch(error) {return {status:"error",message:error instanceof Error ? error.message : "Dados inválidos."};}
  try {
    const client=await masterClient();if(!client)return {status:"error",message:"Governança indisponível ou sessão sem autorização Master."};
    const {error}=await client.rpc("master_reactivate_saas_company",{p_tenant_id:input.tenantId,p_due_on:input.dueOn,p_reason:input.reason});
    if(error)return {status:"error",message:"Reativação não concluída. Verifique plano ativo, limites contratados, assinatura não cancelada e vencimento atual ou futuro."};
    refresh();return {status:"success",message:"Regularização comercial registrada. Acesso operacional continua dependente da liberação manual e das permissões existentes."};
  }catch{return {status:"error",message:"Não foi possível confirmar a reativação. Atualize a consulta antes de tentar novamente."};}
}
