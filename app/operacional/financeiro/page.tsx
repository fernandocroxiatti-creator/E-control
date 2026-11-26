import { FinancialObligations } from "@/app/components/financial-obligations";
import { getOperationalTransactionContexts, operationalContextMessage } from "@/lib/companies/authorized-transaction-context";
import { listOperationalFinancialObligations, listOperationalParties } from "@/lib/operational/read-model";
import { authorizeRouteTransaction, isRouteAuthorized, operationalRouteTransaction } from "@/lib/operational/transaction-focus";
import { getSupabaseEnv } from "@/lib/supabase/env";
import { createClient } from "@/lib/supabase/server";

export const dynamic = "force-dynamic";
type Search = { empresa?: string; filial?: string; tx?: string; type?: string; status?: string };
const types = new Set(["payable", "receivable"]); const statuses = new Set(["open", "partially_settled", "settled", "cancelled"]);

export default async function OperationalFinancePage({ searchParams }: { searchParams: Promise<Search> }) {
  const search = await searchParams; const client = await createClient();
  if (!client) return <p className="master-notice">Integração indisponível.</p>;
  const { data: { user } } = await client.auth.getUser();
  const access = user ? await getOperationalTransactionContexts(client, user.id) : { status: "no_active_membership" as const, contexts: [] };
  const selected = access.contexts.find((context) => context.branchId === search.filial) ?? access.contexts.find((context) => context.tenantId === search.empresa) ?? access.contexts[0];
  const enabled = Boolean(getSupabaseEnv()?.operationalEnabled); const focus = operationalRouteTransaction(search.tx); const requestedTx = focus && ["ZFI01", "ZFI02", "ZFI03", "ZFI04"].includes(focus) ? focus : "ZFI04";
  const [payableAccess, receivableAccess, settlementAccess, readAccess] = selected && enabled ? await Promise.all([
    authorizeRouteTransaction(client, "ZFI01", selected.tenantId, selected.branchId), authorizeRouteTransaction(client, "ZFI02", selected.tenantId, selected.branchId), authorizeRouteTransaction(client, "ZFI03", selected.tenantId, selected.branchId), authorizeRouteTransaction(client, "ZFI04", selected.tenantId, selected.branchId),
  ]) : [];
  const allowPayable = payableAccess?.status === "authorized" && isRouteAuthorized(payableAccess); const allowReceivable = receivableAccess?.status === "authorized" && isRouteAuthorized(receivableAccess); const allowSettle = settlementAccess?.status === "authorized" && isRouteAuthorized(settlementAccess); const allowRead = readAccess?.status === "authorized" && isRouteAuthorized(readAccess);
  const type = types.has(search.type ?? "") ? search.type! : null; const status = statuses.has(search.status ?? "") ? search.status! : null;
  const [obligations, parties] = selected && enabled ? await Promise.all([
    allowRead ? listOperationalFinancialObligations(selected.tenantId, selected.branchId, { type, status }) : Promise.resolve(undefined),
    allowPayable || allowReceivable ? listOperationalParties(selected.tenantId, { search: null, status: "active", page: 1 }) : Promise.resolve(undefined),
  ]) : [];
  return <><div className="page-heading-row"><div><p className="page-kicker">E-CONTROL / FINANCEIRO / {requestedTx}</p><h1>{requestedTx === "ZFI01" ? "Criar conta a pagar" : requestedTx === "ZFI02" ? "Criar conta a receber" : requestedTx === "ZFI03" ? "Registrar baixa" : "Consultar contas"}</h1><p className="page-subtitle">Obrigações, parcelas, baixas e estornos com isolamento por empresa e filial.</p></div><span className="workspace-badge">{enabled ? "Operacional habilitado" : "Aguardando ativação"}</span></div>
    <form className="master-filter-form" method="get"><input type="hidden" name="tx" value={requestedTx} /><label>Contexto<select name="filial" defaultValue={selected?.branchId ?? ""}>{access.contexts.map((context) => <option key={`${context.tenantId}-${context.branchId}`} value={context.branchId}>{context.companyName} · {context.branchCode} — {context.branchName}</option>)}</select></label><label>Tipo<select name="type" defaultValue={type ?? ""}><option value="">Todos</option><option value="payable">A pagar</option><option value="receivable">A receber</option></select></label><label>Situação<select name="status" defaultValue={status ?? ""}><option value="">Todas</option><option value="open">Em aberto</option><option value="partially_settled">Parcial</option><option value="settled">Liquidada</option></select></label><button type="submit">Consultar</button></form>
    {selected ? <FinancialObligations tenantId={selected.tenantId} branchId={selected.branchId} enabled={enabled} parties={parties?.status === "ready" ? parties.data.rows : []} rows={obligations?.status === "ready" ? obligations.data.rows : []} allowPayable={Boolean(allowPayable)} allowReceivable={Boolean(allowReceivable)} allowRead={Boolean(allowRead)} allowSettle={Boolean(allowSettle)} /> : <p className="master-notice">{operationalContextMessage(access.status)}</p>}
    <p className="master-notice">ZFI01–ZFI04 permanecem pendentes por padrão. Aprovação global, disponibilidade por empresa e grant scoped por filial são manuais no Admin Master. Esta etapa não gera caixa, banco, fiscal ou contabilidade.</p></>;
}
