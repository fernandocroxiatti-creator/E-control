import { redirect } from "next/navigation";
import { ErpDashboard } from "@/app/components/erp-dashboard";
import { createClient } from "@/lib/supabase/server";
import { isCurrentSessionMaster } from "@/lib/master/authorization-check";

export const dynamic = "force-dynamic";

export default async function CompaniesLayout({ children }: { children: React.ReactNode }) {
  const supabase = await createClient();
  if (!supabase) redirect("/login?next=%2Fempresas");
  const { data: { user }, error } = await supabase.auth.getUser();
  if (error || !user) redirect("/login?next=%2Fempresas");
  const showMasterAdmin = await isCurrentSessionMaster(supabase);

  return <ErpDashboard email={user.email ?? "Usuário autenticado"} showMasterAdmin={showMasterAdmin} activeSection="companies">{children}</ErpDashboard>;
}
