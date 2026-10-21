import { MasterShell } from "@/app/master/master-ui";
import { requireMasterUser } from "@/lib/master/authorization";

export const dynamic = "force-dynamic";

export default async function MasterLayout({ children }: { children: React.ReactNode }) {
  const user = await requireMasterUser();
  return <MasterShell email={user.email ?? "Usuário autenticado"}>{children}</MasterShell>;
}
