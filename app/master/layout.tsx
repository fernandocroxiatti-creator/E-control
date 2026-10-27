import { MasterShell } from "@/app/master/master-ui";
import { resolveMasterAuthorization } from "@/lib/master/authorization";
import { notFound, redirect } from "next/navigation";

export const dynamic = "force-dynamic";
export const revalidate = 0;

export default async function MasterLayout({ children }: { children: React.ReactNode }) {
  const authorization = await resolveMasterAuthorization();
  if (authorization.status === "unauthenticated") redirect("/login?next=%2Fmaster");
  if (authorization.status === "denied") notFound();
  if (authorization.status === "unavailable") {
    return <main className="master-error" role="alert"><h1>Não foi possível verificar o acesso</h1><p>O serviço de autenticação ou autorização está temporariamente indisponível. Tente novamente em instantes.</p></main>;
  }
  return <MasterShell email={authorization.user.email ?? "Usuário autenticado"}>{children}</MasterShell>;
}
