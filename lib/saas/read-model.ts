import "server-only";
import type { SupabaseClient } from "@supabase/supabase-js";
import type { AuthorizedTransactionContext } from "@/lib/companies/authorized-transaction-context";
export async function getCommerciallyBlockedTenants(client: SupabaseClient, contexts: AuthorizedTransactionContext[]) {
  const ids = [...new Set(contexts.map(c => c.tenantId))];
  const result = await Promise.all(ids.map(async tenant => {
    const { data, error } = await client.rpc("company_get_saas_subscription", { p_tenant_id: tenant });
    return error || data?.operational_allowed !== true ? tenant : null;
  }));
  return result.filter((id): id is string => id !== null);
}
