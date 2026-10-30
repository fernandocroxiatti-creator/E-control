import { redirect } from "next/navigation";
import { ErpDashboard } from "@/app/components/erp-dashboard";
import { createClient } from "@/lib/supabase/server";
import { isCurrentSessionMaster } from "@/lib/master/authorization-check";
import { getAuthorizedTransactionContexts } from "@/lib/companies/authorized-transaction-context";
import { getSupabaseEnv } from "@/lib/supabase/env";

export const dynamic = "force-dynamic";

export default async function DashboardPage({ searchParams }: { searchParams: Promise<{ password?: string }> }) {
  const supabase = await createClient();
  if (!supabase) {
    return <main className="auth-shell"><section className="auth-card"><h1>Integração não configurada</h1><p className="auth-description">Configure a URL e a chave publicável do Supabase para habilitar o acesso.</p></section></main>;
  }
  const { data: { user }, error } = await supabase.auth.getUser();
  if (error || !user) redirect("/login?next=%2Fdashboard");
  const showMasterAdmin = await isCurrentSessionMaster(supabase);
  const transactionContexts = await getAuthorizedTransactionContexts(supabase, user.id);
  const { password } = await searchParams;
  return <ErpDashboard email={user.email ?? "Usuário autenticado"} showMasterAdmin={showMasterAdmin} passwordUpdated={password === "updated"} transactionContexts={transactionContexts} operationalEnabled={Boolean(getSupabaseEnv()?.operationalEnabled)} />;
}
