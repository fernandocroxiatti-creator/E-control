"use server";
import { revalidatePath } from "next/cache";
import { parseCommand } from "@/lib/erp-completion/input";
import { createClient } from "@/lib/supabase/server";
import { getSupabaseEnv } from "@/lib/supabase/env";
import { isAuthorizedSupabaseTarget } from "@/lib/supabase/homologation-env";
import { isCurrentSessionMaster } from "@/lib/master/authorization-check";
export type CompletionState = { status: "idle" | "success" | "error"; message?: string; resultId?: string };
export async function executeCompletionAction(_: CompletionState, form: FormData): Promise<CompletionState> {
  let parsed: ReturnType<typeof parseCommand>;
  try { parsed = parseCommand(String(form.get("command") ?? ""), form); }
  catch (error) { return { status: "error", message: error instanceof Error ? error.message : "Dados inválidos." }; }
  try {
    const { spec, args } = parsed; const env = getSupabaseEnv();
    if (!env || !isAuthorizedSupabaseTarget(env) || (spec.master ? !env.accessGovernanceEnabled : !env.operationalEnabled)) return { status: "error", message: "Operação bloqueada neste ambiente." };
    const client = await createClient(); if (!client) return { status: "error", message: "Integração indisponível." };
    const { data: { user }, error: authError } = await client.auth.getUser();
    if (authError || !user || (spec.master && !await isCurrentSessionMaster(client))) return { status: "error", message: "Sessão sem autorização." };
    const { data, error } = await client.rpc(spec.rpc, args);
    if (error || typeof data !== "string") return { status: "error", message: "Operação não concluída. Confira os dados, a situação do registro e as permissões da empresa/filial." };
    revalidatePath("/operacional/bancos"); revalidatePath("/operacional/gestao"); revalidatePath("/master/planos");
    return { status: "success", message: "Operação registrada e auditada.", resultId: data };
  } catch { return { status: "error", message: "Não foi possível confirmar a operação. Reenvie os mesmos dados para consultar o resultado sem duplicar o lançamento." }; }
}
