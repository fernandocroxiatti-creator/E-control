"use server";
import { revalidatePath } from "next/cache";
import { createClient } from "@/lib/supabase/server";
import { getSupabaseEnv } from "@/lib/supabase/env";
import { isAuthorizedSupabaseTarget } from "@/lib/supabase/homologation-env";
import { parseBillingReceivable } from "@/lib/billing/receivable-input";
export type BillingFinanceState = { status: "idle" | "success" | "error"; message?: string; obligationId?: string };
export async function integrateBillingReceivableAction(_: BillingFinanceState, form: FormData): Promise<BillingFinanceState> {
  let args: ReturnType<typeof parseBillingReceivable>;
  try { args = parseBillingReceivable(form); } catch (error) { return { status: "error", message: error instanceof Error ? error.message : "Dados inválidos." }; }
  try {
    const env = getSupabaseEnv();
    if (!env || !isAuthorizedSupabaseTarget(env) || !env.operationalEnabled) return { status: "error", message: "Operação indisponível neste ambiente." };
    const client = await createClient(); if (!client) return { status: "error", message: "Integração indisponível." };
    const { data: { user }, error: authError } = await client.auth.getUser(); if (authError || !user) return { status: "error", message: "Entre novamente para continuar." };
    const { data, error } = await client.rpc("operational_integrate_billing_receivable", args);
    if (error || typeof data !== "string") {
      const message = error?.code === "23505" ? "Já existe integração ou obrigação compatível. Consulte o financeiro e vincule o recebível existente; não gere outro lançamento." : error?.code === "23514" ? "As parcelas devem totalizar o faturamento. Para vínculo existente, empresa, filial, cliente, emissão e total devem coincidir." : error?.code === "42501" ? "Integração exige ZFB04, consulta de faturamento e gestão de recebíveis autorizadas para a filial." : error?.code === "55000" ? "O faturamento ou o contrato não permite esta operação no estado atual." : "Não foi possível integrar. Confira as parcelas e tente novamente com os mesmos dados.";
      return { status: "error", message };
    }
    revalidatePath("/operacional/faturamento"); revalidatePath("/operacional/financeiro"); revalidatePath("/operacional/gestao");
    return { status: "success", message: "Recebível vinculado ao faturamento com auditoria. Nenhuma baixa ou movimentação bancária foi criada.", obligationId: data };
  } catch { return { status: "error", message: "Não foi possível confirmar o resultado. Reenvie os mesmos dados para recuperar a solicitação sem duplicá-la." }; }
}
