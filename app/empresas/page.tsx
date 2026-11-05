import { CompaniesWorkspace } from "@/app/components/companies-workspace";
import { getOperationalTransactionContexts } from "@/lib/companies/authorized-transaction-context";
import { getSupabaseEnv } from "@/lib/supabase/env";
import { createClient } from "@/lib/supabase/server";

export default async function CompaniesPage() {
  const client = await createClient();
  const { data: { user } } = client ? await client.auth.getUser() : { data: { user: null } };
  const access = user && client ? await getOperationalTransactionContexts(client, user.id) : { status: "no_active_membership" as const, contexts: [] };
  return <CompaniesWorkspace view="companies" contexts={access.contexts} accessStatus={access.status} operationalEnabled={Boolean(getSupabaseEnv()?.operationalEnabled)} />;
}
