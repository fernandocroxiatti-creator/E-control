import type { SupabaseClient } from "@supabase/supabase-js";

type ContextClient = {
  from: SupabaseClient["from"];
};

export type AuthorizedTransactionContext = {
  tenantId: string;
  companyName: string;
  branchId: string;
  branchCode: string;
  branchName: string;
};

export type OperationalContextStatus = "ready" | "no_active_membership" | "no_authorized_branch" | "unavailable";
export type OperationalContextResult = { status: OperationalContextStatus; contexts: AuthorizedTransactionContext[] };

/** Reads only membership and branch rows visible to the current SSR session through RLS. */
export async function getOperationalTransactionContexts(
  client: ContextClient,
  authenticatedUserId: string,
): Promise<OperationalContextResult> {
  if (!authenticatedUserId) return { status: "no_active_membership", contexts: [] };
  try {
    const { data: memberships, error: membershipError } = await client
      .from("company_memberships")
      .select("id, tenant_id, branch_access_mode")
      .eq("user_id", authenticatedUserId)
      .eq("status", "active");
    if (membershipError) return { status: "unavailable", contexts: [] };
    if (!Array.isArray(memberships) || memberships.length === 0) return { status: "no_active_membership", contexts: [] };

    const tenantIds = [...new Set(memberships.map((row: { tenant_id: string }) => row.tenant_id))];
    const { data: companies, error: companyError } = await client
      .from("companies")
      .select("id, legal_name")
      .in("id", tenantIds)
      .eq("status", "active");
    if (companyError || !Array.isArray(companies)) return { status: "unavailable", contexts: [] };
    const companyNames = new Map(companies.map((row: { id: string; legal_name: string }) => [row.id, row.legal_name]));

    const contexts: AuthorizedTransactionContext[] = [];
    for (const membership of memberships as Array<{ id: string; tenant_id: string; branch_access_mode: string }>) {
      const companyName = companyNames.get(membership.tenant_id);
      if (!companyName) continue;

      if (membership.branch_access_mode === "all_branches") {
        const { data, error } = await client
          .from("branches")
          .select("id, code, name")
          .eq("tenant_id", membership.tenant_id)
          .eq("status", "active");
        if (error || !Array.isArray(data)) continue;
        contexts.push(...data.map((branch: { id: string; code: string; name: string }) => ({
          tenantId: membership.tenant_id,
          companyName,
          branchId: branch.id,
          branchCode: branch.code,
          branchName: branch.name,
        })));
        continue;
      }

      const { data: accesses, error: accessError } = await client
        .from("branch_access")
        .select("branch_id")
        .eq("tenant_id", membership.tenant_id)
        .eq("membership_id", membership.id)
        .eq("status", "active");
      if (accessError || !Array.isArray(accesses) || accesses.length === 0) continue;
      const branchIds = [...new Set(accesses.map((row: { branch_id: string }) => row.branch_id))];
      const { data: branches, error: branchError } = await client
        .from("branches")
        .select("id, code, name")
        .in("id", branchIds)
        .eq("tenant_id", membership.tenant_id)
        .eq("status", "active");
      if (branchError || !Array.isArray(branches)) continue;
      contexts.push(...branches.map((branch: { id: string; code: string; name: string }) => ({
        tenantId: membership.tenant_id,
        companyName,
        branchId: branch.id,
        branchCode: branch.code,
        branchName: branch.name,
      })));
    }
    return { status: contexts.length ? "ready" : "no_authorized_branch", contexts };
  } catch {
    return { status: "unavailable", contexts: [] };
  }
}

/** Compatibility helper for callers that only need the RLS-authorized contexts. */
export async function getAuthorizedTransactionContexts(
  client: ContextClient,
  authenticatedUserId: string,
): Promise<AuthorizedTransactionContext[]> {
  return (await getOperationalTransactionContexts(client, authenticatedUserId)).contexts;
}

export function operationalContextMessage(status: OperationalContextStatus) {
  if (status === "no_active_membership") return "Você não possui vínculo empresarial ativo. Um administrador da empresa deve concluir o convite, a aprovação do vínculo e a atribuição de filial.";
  if (status === "no_authorized_branch") return "Seu vínculo empresarial não possui uma filial ativa autorizada. Solicite a revisão da filial vinculada ao seu acesso.";
  if (status === "unavailable") return "Não foi possível verificar seu contexto empresarial. O acesso operacional permanece bloqueado por segurança.";
  return "";
}
