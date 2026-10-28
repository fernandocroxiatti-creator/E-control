"use server";

import { createClient } from "@/lib/supabase/server";
import {
  assertFirstMasterBootstrapCsrf,
  isCurrentSessionApprovedForFirstMaster,
  isFirstMasterBootstrapInvokerEnabled,
} from "@/lib/first-master-bootstrap";

export type FirstMasterBootstrapActionState = { error?: string; completed?: boolean };

/** Calls the zero-argument RPC once; it intentionally has no retry path. */
export async function submitFirstMasterBootstrap(
  _previous: FirstMasterBootstrapActionState,
  formData: FormData,
): Promise<FirstMasterBootstrapActionState> {
  if (!isFirstMasterBootstrapInvokerEnabled()) return { error: "Fluxo indisponível." };
  if (formData.get("confirm-first-master") !== "confirm") return { error: "Confirmação obrigatória." };
  if (!await assertFirstMasterBootstrapCsrf()) return { error: "Solicitação inválida." };

  const supabase = await createClient();
  if (!supabase || !await isCurrentSessionApprovedForFirstMaster(supabase)) return { error: "Acesso indisponível." };

  try {
    const result = await supabase.rpc("bootstrap_first_master");
    if (result.error) return { error: "Não foi possível concluir a concessão. Verifique o estado antes de tentar novamente." };
    return { completed: true };
  } catch {
    return { error: "Não foi possível concluir a concessão. Verifique o estado antes de tentar novamente." };
  }
}
