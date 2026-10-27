"use server";

import { revalidatePath } from "next/cache";
import { createMasterCompany, validateMasterCompanyInput, type MasterCompanyFormState } from "@/lib/master/company-creation";
import { createClient } from "@/lib/supabase/server";
import { getSupabaseEnv } from "@/lib/supabase/env";
import { isAuthorizedSupabaseTarget } from "@/lib/supabase/homologation-env";

export async function createMasterCompanyAction(
  _previousState: MasterCompanyFormState,
  formData: FormData,
): Promise<MasterCompanyFormState> {
  const input = validateMasterCompanyInput(formData.get("legal_name"), formData.get("request_id"));
  if (!input) {
    return { status: "error", message: "Informe uma razão social válida e tente novamente." };
  }

  const env = getSupabaseEnv();
  if (!env || !isAuthorizedSupabaseTarget(env) || !env.companyCreationEnabled) {
    return {
      status: "error",
      message: "A criação está bloqueada: habilite explicitamente o ambiente autorizado.",
    };
  }

  const supabase = await createClient();
  if (!supabase) return { status: "error", message: "A integração local do Supabase não está configurada." };

  const result = await createMasterCompany(supabase, input);
  if (result.status === "unauthenticated") {
    return { status: "error", message: "Sua sessão expirou. Entre novamente para continuar." };
  }
  if (result.status === "denied") {
    return { status: "error", message: "A sessão atual não possui autorização para cadastrar empresas." };
  }
  if (result.status !== "created") {
    return { status: "error", message: "Não foi possível concluir a solicitação. Tente novamente ou procure o suporte." };
  }

  revalidatePath("/master/empresas");
  return {
    status: "success",
    companyId: result.companyId,
    message: "Empresa criada. Nenhum usuário, vínculo ou acesso operacional foi concedido automaticamente.",
  };
}
