import { redirect } from "next/navigation";
import { ErpDashboard } from "@/app/components/erp-dashboard";
import { createClient } from "@/lib/supabase/server";
import { isCurrentSessionMaster } from "@/lib/master/authorization-check";
import { getAuthorizedTransactionContexts } from "@/lib/companies/authorized-transaction-context";
import { getSupabaseEnv } from "@/lib/supabase/env";

export const dynamic = "force-dynamic";
export default async function OperationalLayout({ children }: { children: React.ReactNode }) {
  const supabase = await createClient();
  if (!supabase) redirect("/login?next=%2Foperacional%2Fcadastros");
  const { data: { user }, error } = await supabase.auth.getUser();
  if (error || !user) redirect("/login?next=%2Foperacional%2Fcadastros");
  return <ErpDashboard email={user.email ?? "Usuário autenticado"} showMasterAdmin={await isCurrentSessionMaster(supabase)} transactionContexts={await getAuthorizedTransactionContexts(supabase, user.id)} operationalEnabled={Boolean(getSupabaseEnv()?.operationalEnabled)} activeSection="catalog">{children}</ErpDashboard>;
}
