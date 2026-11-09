import { OperationalTeam } from "@/app/components/operational-catalog";
import { getOperationalTransactionContexts, operationalContextMessage } from "@/lib/companies/authorized-transaction-context";
import { listOperationalEmployeeInvitations, listOperationalMembershipAuthorizations, listOperationalMemberships } from "@/lib/operational/read-model";
import { getSupabaseEnv } from "@/lib/supabase/env";
import { createClient } from "@/lib/supabase/server";

export const dynamic = "force-dynamic";
export default async function OperationalTeamPage({ searchParams }: { searchParams: Promise<{ empresa?: string }> }) {
  const { empresa } = await searchParams; const client = await createClient();
  if (!client) return <p className="master-notice">Integração indisponível.</p>;
  const { data: { user } } = await client.auth.getUser(); const access = user ? await getOperationalTransactionContexts(client, user.id) : { status: "no_active_membership" as const, contexts: [] };
  const contexts = access.contexts;
  const tenantId = contexts.some((context) => context.tenantId === empresa) ? empresa! : contexts[0]?.tenantId;
  const companies = [...new Map(contexts.map((context) => [context.tenantId, context.companyName])).entries()];
  const enabled = Boolean(getSupabaseEnv()?.operationalEnabled);
  const [memberships, invitations, authorizations] = tenantId && enabled ? await Promise.all([
    listOperationalMemberships(tenantId), listOperationalEmployeeInvitations(tenantId), listOperationalMembershipAuthorizations(tenantId),
  ]) : [null, null, null];
  const branches = contexts.filter((context) => context.tenantId === tenantId).map((context) => ({ branchId: context.branchId, branchCode: context.branchCode, branchName: context.branchName }));
  const managementAvailable = invitations?.status === "ready" && authorizations?.status === "ready";
  return <><div className="page-heading-row"><div><p className="page-kicker">E-CONTROL / EQUIPE</p><h1>Funcionários, vínculos e permissões</h1><p className="page-subtitle">A empresa só consulta e administra vínculos para os quais a sessão possui autorização.</p></div><span className="workspace-badge">{enabled ? "Operacional habilitado" : "Aguardando ativação"}</span></div><form className="master-filter-form" method="get"><label>Empresa<select name="empresa" defaultValue={tenantId ?? ""}><option value="">Selecione</option>{companies.map(([id, name]) => <option key={id} value={id}>{name}</option>)}</select></label><button type="submit">Consultar</button></form>{tenantId ? <OperationalTeam tenantId={tenantId} enabled={enabled} managementAvailable={Boolean(managementAvailable)} memberships={memberships?.status === "ready" ? memberships.data : []} invitations={invitations?.status === "ready" ? invitations.data : []} authorizations={authorizations?.status === "ready" ? authorizations.data : []} branches={branches} /> : <p className="master-notice">{operationalContextMessage(access.status)}</p>}</>;
}
