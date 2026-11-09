import Link from "next/link";
import { WorkOrders } from "@/app/components/operational-catalog";
import { getOperationalTransactionContexts, operationalContextMessage } from "@/lib/companies/authorized-transaction-context";
import { listOperationalParties, listOperationalWorkOrders } from "@/lib/operational/read-model";
import { getSupabaseEnv } from "@/lib/supabase/env";
import { createClient } from "@/lib/supabase/server";

export const dynamic = "force-dynamic";
type Search = { empresa?: string; filial?: string; status?: string; page?: string };
const page = (value: string | undefined) => Number.isSafeInteger(Number(value)) && Number(value) > 0 ? Number(value) : 1;
const status = (value: string | undefined) => ["open", "in_progress", "closed", "cancelled", "reversed"].includes(value ?? "") ? value! : null;

export default async function OperationalWorkOrdersPage({ searchParams }: { searchParams: Promise<Search> }) {
  const search = await searchParams; const client = await createClient();
  if (!client) return <p className="master-notice">Integração indisponível.</p>;
  const { data: { user } } = await client.auth.getUser();
  const access = user ? await getOperationalTransactionContexts(client, user.id) : { status: "no_active_membership" as const, contexts: [] };
  const contexts = access.contexts;
  const selected = contexts.find((context) => context.branchId === search.filial) ?? contexts.find((context) => context.tenantId === search.empresa) ?? contexts[0];
  const enabled = Boolean(getSupabaseEnv()?.operationalEnabled);
  const selectedStatus = status(search.status); const currentPage = page(search.page);
  const [orders, customers] = selected && enabled ? await Promise.all([
    listOperationalWorkOrders(selected.tenantId, selected.branchId, { status: selectedStatus, page: currentPage }),
    listOperationalParties(selected.tenantId, { search: null, partyType: "customer", status: "active", page: 1 }),
  ]) : [];
  // A denied ZOS read contract is not evidence that the schema is missing.
  // Production has the foundation installed; the list can still be denied by
  // the deliberately separate ZOS role grant and company availability.
  const foundationAvailable = true;
  const serviceAuthorized = Boolean(selected && enabled && orders?.status === "ready");
  return <>
    <div className="page-heading-row"><div><p className="page-kicker">E-CONTROL / SERVIÇOS</p><h1>Ordens de serviço</h1><p className="page-subtitle">Atendimento, serviços e peças isolados por empresa e filial.</p></div><span className="workspace-badge">{enabled ? "Operacional habilitado" : "Aguardando ativação"}</span></div>
    <form className="master-filter-form" method="get"><label>Contexto<select name="filial" defaultValue={selected?.branchId ?? ""}>{contexts.map((context) => <option key={`${context.tenantId}-${context.branchId}`} value={context.branchId}>{context.companyName} · {context.branchCode} — {context.branchName}</option>)}</select></label><label>Situação<select name="status" defaultValue={selectedStatus ?? ""}><option value="">Todas</option><option value="open">Aberta</option><option value="in_progress">Em andamento</option><option value="closed">Encerrada</option><option value="cancelled">Cancelada</option><option value="reversed">Estornada</option></select></label><button type="submit">Consultar</button></form>
    {selected ? <WorkOrders tenantId={selected.tenantId} branchId={selected.branchId} enabled={serviceAuthorized} customers={customers?.status === "ready" ? customers.data.rows : []} orders={orders?.status === "ready" ? orders.data.rows : []} foundationAvailable={foundationAvailable} /> : <p className="master-notice">{operationalContextMessage(access.status)}</p>}
    <p className="master-notice">{enabled && !serviceAuthorized ? "A fundação de O.S. está instalada, mas esta sessão ainda não possui ZOS01/ZOS03 aprovadas, concedidas e disponíveis para a empresa." : "A leitura exige ZOS03; abertura exige ZOS01. Reserva, consumo e estorno são auditados e só ficam disponíveis após autorização explícita."} <Link href="/operacional/estoque">Estoque</Link> mantém seu próprio controle.</p>
  </>;
}
