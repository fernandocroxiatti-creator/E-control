"use server";

import { revalidatePath } from "next/cache";
import { requireMasterUser } from "@/lib/master/authorization";
import { getSiteUrl } from "@/lib/supabase/env";
import { getSupabaseEnv } from "@/lib/supabase/env";
import { isAuthorizedSupabaseTarget } from "@/lib/supabase/homologation-env";
import { createClient } from "@/lib/supabase/server";

export type InvitationActionState = {
  status: "idle" | "success" | "error";
  message?: string;
  invitationLink?: string;
  expiresAt?: string;
};

export type InvitationAcceptState = {
  status: "idle" | "accepted" | "rejected" | "error";
  message?: string;
};

const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[1-8][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i;
const TOKEN = /^[0-9a-f]{64}$/;

function value(formData: FormData, name: string) {
  const candidate = formData.get(name);
  return typeof candidate === "string" ? candidate.trim() : "";
}

async function getInvitationClient(requireIssuingEnabled = false) {
  const env = getSupabaseEnv();
  if (!env || !isAuthorizedSupabaseTarget(env)
    || (requireIssuingEnabled && (!env.companyManagementEnabled || !env.companyInvitationsEnabled))) return null;
  await requireMasterUser();
  const client = await createClient();
  if (!client) return null;
  const { data, error } = await client.rpc("master_admin_management_ready");
  if (error || data !== true) return null;
  return client;
}

function safeFailure(): InvitationActionState {
  return { status: "error", message: "Não foi possível concluir. Confira a empresa, o papel aprovado e o estado do convite antes de tentar novamente." };
}

export async function createCompanyAdminInvitationAction(
  _state: InvitationActionState,
  formData: FormData,
): Promise<InvitationActionState> {
  const tenantId = value(formData, "tenant_id");
  const recipientEmail = value(formData, "recipient_email").toLowerCase();
  const requestId = value(formData, "request_id");
  if (!UUID.test(tenantId) || !UUID.test(requestId)
    || recipientEmail.length > 254
    || !/^[^\s@]+@[^\s@]+\.[^\s@]+$/.test(recipientEmail)) {
    return { status: "error", message: "Informe uma empresa e um e-mail válidos." };
  }

  try {
    const client = await getInvitationClient(true);
    if (!client) return safeFailure();
    const { data, error } = await client.rpc("master_create_company_admin_invitation", {
      p_tenant_id: tenantId,
      p_recipient_email: recipientEmail,
      p_request_id: requestId,
    });
    if (error || !Array.isArray(data) || data.length !== 1) return safeFailure();
    const result = data[0] as { invitation_id?: unknown; invitation_token?: unknown; expires_at?: unknown };
    if (typeof result.invitation_id !== "string" || !UUID.test(result.invitation_id)
      || typeof result.invitation_token !== "string" || !TOKEN.test(result.invitation_token)
      || typeof result.expires_at !== "string") return safeFailure();

    // Fragment values are not sent in HTTP requests or server access logs.
    const inviteUrl = new URL("/convites/aceitar", getSiteUrl());
    inviteUrl.hash = new URLSearchParams({ token: result.invitation_token }).toString();
    revalidatePath("/master/administradores");
    return {
      status: "success",
      message: "Convite criado. Copie o link agora e envie ao destinatário por um canal seguro; ele será exibido somente nesta resposta.",
      invitationLink: inviteUrl.toString(),
      expiresAt: result.expires_at,
    };
  } catch {
    return safeFailure();
  }
}

export async function revokeCompanyAdminInvitationAction(
  _state: InvitationActionState,
  formData: FormData,
): Promise<InvitationActionState> {
  const invitationId = value(formData, "invitation_id");
  if (!UUID.test(invitationId)) return { status: "error", message: "Convite inválido." };
  try {
    // Revocation changes business state too. It must remain behind the same
    // explicit Production flag as issuance, rather than merely hiding a UI button.
    const client = await getInvitationClient(true);
    if (!client) return safeFailure();
    const { data, error } = await client.rpc("master_revoke_company_admin_invitation", {
      p_invitation_id: invitationId,
    });
    if (error || data !== "revoked") return safeFailure();
    revalidatePath("/master/administradores");
    return { status: "success", message: "Convite revogado." };
  } catch {
    return safeFailure();
  }
}

export async function expireCompanyAdminInvitationsAction(
  _state: InvitationActionState,
  formData: FormData,
): Promise<InvitationActionState> {
  const tenantId = value(formData, "tenant_id");
  if (!UUID.test(tenantId)) return { status: "error", message: "Empresa inválida." };
  try {
    // Expiration writes audit/state records and is therefore feature-gated.
    const client = await getInvitationClient(true);
    if (!client) return safeFailure();
    const { data, error } = await client.rpc("master_expire_company_admin_invitations", { p_tenant_id: tenantId });
    if (error || !Number.isSafeInteger(data) || Number(data) < 0) return safeFailure();
    revalidatePath("/master/administradores");
    return { status: "success", message: `${data} convite(s) expirado(s) e auditado(s).` };
  } catch {
    return safeFailure();
  }
}

export async function acceptCompanyAdminInvitationAction(
  _state: InvitationAcceptState,
  formData: FormData,
): Promise<InvitationAcceptState> {
  const token = value(formData, "invitation_token");
  if (!TOKEN.test(token)) return { status: "rejected", message: "Este convite não é válido ou já não pode ser utilizado." };
  try {
    const env = getSupabaseEnv();
    if (!env || !isAuthorizedSupabaseTarget(env) || !env.companyManagementEnabled || !env.companyInvitationsEnabled) {
      return { status: "error", message: "O ambiente de autenticação não está disponível." };
    }
    const client = await createClient();
    if (!client) return { status: "error", message: "A sessão não está disponível. Entre na sua conta e tente novamente." };
    const { data: authData, error: authError } = await client.auth.getUser();
    if (authError || !authData.user) {
      return { status: "error", message: "Entre na sua conta antes de aceitar o convite." };
    }
    const { data, error } = await client.rpc("accept_company_admin_invitation", {
      p_invitation_token: token,
    });
    if (error || !Array.isArray(data) || data.length !== 1) {
      return { status: "error", message: "Não foi possível validar o convite. Nenhum acesso foi confirmado." };
    }
    const outcome = (data[0] as { outcome?: unknown }).outcome;
    if (outcome === "accepted") {
      revalidatePath("/dashboard");
      return { status: "accepted", message: "Convite aceito. Seu vínculo empresarial foi ativado." };
    }
    if (outcome === "expired") {
      return { status: "rejected", message: "Este convite expirou. Solicite um novo convite ao administrador." };
    }
    return { status: "rejected", message: "Este convite não é válido para esta conta ou já foi utilizado/revogado." };
  } catch {
    return { status: "error", message: "Não foi possível confirmar a aceitação. Atualize o estado antes de tentar novamente." };
  }
}
