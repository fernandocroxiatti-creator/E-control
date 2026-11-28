import { resolveTransactionForSession } from "@/lib/master/transaction-resolution";
import type { BillingFinancialLink } from "@/app/components/billing-receivable";
import { CommercialBilling } from "@/app/components/commercial-billing";
import { getOperationalTransactionContexts, operationalContextMessage } from "@/lib/companies/authorized-transaction-context";
import { listOperationalCommercialBilling, listOperationalSalesOrders, listOperationalWorkOrders } from "@/lib/operational/read-model";
import { authorizeRouteTransaction, isRouteAuthorized, operationalRouteTransaction } from "@/lib/operational/transaction-focus";
import { getSupabaseEnv } from "@/lib/supabase/env";
import { createClient } from "@/lib/supabase/server";

export const dynamic = "force-dynamic";
type Search = { empresa?: string; filial?: string; status?: string; tx?: string };
const billingStatus = (value: string | undefined) => ["issued", "cancelled"].includes(value ?? "") ? value! : null;

export default async function OperationalBillingPage({ searchParams }: { searchParams: Promise<Search> }) {
  const search = await searchParams; const client = await createClient();
  if (!client) return <p className="master-notice">Integração indisponível.</p>;
  const { data: { user } } = await client.auth.getUser();
  const access = user ? await getOperationalTransactionContexts(client, user.id) : { status: "no_active_membership" as const, contexts: [] };
  const selected = access.contexts.find((context) => context.branchId === search.filial) ?? access.contexts.find((context) => context.tenantId === search.empresa) ?? access.contexts[0];
  const enabled = Boolean(getSupabaseEnv()?.operationalEnabled); const focus = operationalRouteTransaction(search.tx); const requestedTx = focus && ["ZFB01", "ZFB02", "ZFB03", "ZFB04"].includes(focus) ? focus : "ZFB02";
  const [issueAccess, readAccess, cancelAccess, linkAccess] = selected && enabled ? await Promise.all([
    authorizeRouteTransaction(client, "ZFB01", selected.tenantId, selected.branchId), authorizeRouteTransaction(client, "ZFB02", selected.tenantId, selected.branchId), authorizeRouteTransaction(client, "ZFB03", selected.tenantId, selected.branchId), resolveTransactionForSession(client, "ZFB04", selected.tenantId, selected.branchId),
  ]) : [];
  const allowIssue = isRouteAuthorized(issueAccess ?? null) && issueAccess?.status === "authorized";
  const allowRead = isRouteAuthorized(readAccess ?? null) && readAccess?.status === "authorized";
  const allowCancel = isRouteAuthorized(cancelAccess ?? null) && cancelAccess?.status === "authorized";
  const [billing, salesOrders, workOrders] = selected && enabled ? await Promise.all([
    allowRead ? listOperationalCommercialBilling(selected.tenantId, selected.branchId, { status: billingStatus(search.status) }) : Promise.resolve(undefined),
    allowIssue ? listOperationalSalesOrders(selected.tenantId, selected.branchId, { status: "confirmed" }) : Promise.resolve(undefined),
    allowIssue ? listOperationalWorkOrders(selected.tenantId, selected.branchId, { status: "closed" }) : Promise.resolve(undefined),
  ]) : [];
  const financeResult = selected && enabled && allowRead ? await client.rpc("operational_list_billing_financial_links", { p_tenant_id: selected.tenantId, p_branch_id: selected.branchId, p_limit: 100, p_offset: 0 }) : null;
  const financialLinks = financeResult && !financeResult.error && Array.isArray(financeResult.data) ? financeResult.data as BillingFinancialLink[] : [];
  return <><div className="page-heading-row"><div><p className="page-kicker">E-CONTROL / FATURAMENTO / {requestedTx}</p><h1>{requestedTx === "ZFB01" ? "Emitir faturamento comercial" : requestedTx === "ZFB03" ? "Cancelar faturamento comercial" : "Consultar faturamento comercial"}</h1><p className="page-subtitle">Faturamento e recebíveis vinculados por confirmação explícita, mantendo caixa e bancos independentes.</p></div><span className="workspace-badge">{enabled ? "Operacional habilitado" : "Aguardando ativação"}</span></div>
    <form className="master-filter-form" method="get"><input type="hidden" name="tx" value={requestedTx} /><label>Contexto<select name="filial" defaultValue={selected?.branchId ?? ""}>{access.contexts.map((context) => <option key={`${context.tenantId}-${context.branchId}`} value={context.branchId}>{context.companyName} · {context.branchCode} — {context.branchName}</option>)}</select></label><label>Situação<select name="status" defaultValue={billingStatus(search.status) ?? ""}><option value="">Todas</option><option value="issued">Emitidos</option><option value="cancelled">Cancelados</option></select></label><button type="submit">Consultar</button></form>
    {selected ? <CommercialBilling tenantId={selected.tenantId} enabled={enabled} billing={billing?.status === "ready" ? billing.data.rows : []} salesOrders={salesOrders?.status === "ready" ? salesOrders.data.rows : []} workOrders={workOrders?.status === "ready" ? workOrders.data.rows : []} allowIssue={allowIssue} allowRead={allowRead} allowCancel={allowCancel} allowLink={linkAccess?.status === "authorized"} financialLinks={financialLinks} /> : <p className="master-notice">{operationalContextMessage(access.status)}</p>}
  </>;
}
