import { redirect } from "next/navigation";
import { ErpDashboard } from "@/app/components/erp-dashboard";
import { createClient } from "@/lib/supabase/server";
import { isCurrentSessionMaster } from "@/lib/master/authorization-check";
import { getOperationalTransactionContexts } from "@/lib/companies/authorized-transaction-context";
import { getSupabaseEnv } from "@/lib/supabase/env";

export const dynamic = "force-dynamic";

export default async function CompaniesLayout({ children }: { children: React.ReactNode }) {
  const supabase = await createClient();
  if (!supabase) redirect("/login?next=%2Fempresas");
  const { data: { user }, error } = await supabase.auth.getUser();
  if (error || !user) redirect("/login?next=%2Fempresas");
  const showMasterAdmin = await isCurrentSessionMaster(supabase);

  const access = await getOperationalTransactionContexts(supabase, user.id);
  return <ErpDashboard email={user.email ?? "Usuário autenticado"} showMasterAdmin={showMasterAdmin} activeSection="companies" transactionContexts={access.contexts} operationalContextStatus={access.status} operationalEnabled={Boolean(getSupabaseEnv()?.operationalEnabled)}>{children}</ErpDashboard>;
}
