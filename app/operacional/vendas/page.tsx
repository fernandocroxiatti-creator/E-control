import { SalesOrders } from "@/app/components/sales-orders";
import { getOperationalTransactionContexts, operationalContextMessage } from "@/lib/companies/authorized-transaction-context";
import { listOperationalItems, listOperationalParties, listOperationalQuotations, listOperationalSalesOrders } from "@/lib/operational/read-model";
import { authorizeRouteTransaction, isRouteAuthorized, operationalRouteTransaction } from "@/lib/operational/transaction-focus";
import { getSupabaseEnv } from "@/lib/supabase/env";
import { createClient } from "@/lib/supabase/server";

export const dynamic = "force-dynamic";
type Search = { empresa?: string; filial?: string; status?: string; tx?: string };
const status = (value: string | undefined) => ["draft", "confirmed", "fulfilled", "cancelled"].includes(value ?? "") ? value! : null;

export default async function OperationalSalesPage({ searchParams }: { searchParams: Promise<Search> }) {
  const search = await searchParams; const client = await createClient();
  if (!client) return <p className="master-notice">Integração indisponível.</p>;
  const { data: { user } } = await client.auth.getUser();
  const access = user ? await getOperationalTransactionContexts(client, user.id) : { status: "no_active_membership" as const, contexts: [] };
  const selected = access.contexts.find((context) => context.branchId === search.filial) ?? access.contexts.find((context) => context.tenantId === search.empresa) ?? access.contexts[0];
  const enabled = Boolean(getSupabaseEnv()?.operationalEnabled); const focus = operationalRouteTransaction(search.tx); const requestedTx = focus && ["ZVE01", "ZVE02", "ZVE03", "ZVE04", "ZVE05", "ZVE06", "ZVE07"].includes(focus) ? focus : "ZVE03";
  const [createAccess, manageAccess, readAccess, decideAccess, quotationReadAccess, reserveAccess, fulfillAccess, returnAccess] = selected && enabled ? await Promise.all([
    authorizeRouteTransaction(client, "ZVE01", selected.tenantId, selected.branchId), authorizeRouteTransaction(client, "ZVE02", selected.tenantId, selected.branchId),
    authorizeRouteTransaction(client, "ZVE03", selected.tenantId, selected.branchId), authorizeRouteTransaction(client, "ZVE04", selected.tenantId, selected.branchId),
    authorizeRouteTransaction(client, "ZQT03", selected.tenantId, selected.branchId),
    authorizeRouteTransaction(client, "ZVE05", selected.tenantId, selected.branchId), authorizeRouteTransaction(client, "ZVE06", selected.tenantId, selected.branchId), authorizeRouteTransaction(client, "ZVE07", selected.tenantId, selected.branchId),
  ]) : [];
  const allowCreate = isRouteAuthorized(createAccess ?? null) && createAccess?.status === "authorized";
  const allowManage = isRouteAuthorized(manageAccess ?? null) && manageAccess?.status === "authorized";
  const allowRead = isRouteAuthorized(readAccess ?? null) && readAccess?.status === "authorized";
  const allowDecide = isRouteAuthorized(decideAccess ?? null) && decideAccess?.status === "authorized";
  const allowQuoteRead = isRouteAuthorized(quotationReadAccess ?? null) && quotationReadAccess?.status === "authorized";
  const allowReserve = isRouteAuthorized(reserveAccess ?? null) && reserveAccess?.status === "authorized";
  const allowFulfill = isRouteAuthorized(fulfillAccess ?? null) && fulfillAccess?.status === "authorized";
  const allowReturn = isRouteAuthorized(returnAccess ?? null) && returnAccess?.status === "authorized";
  const [orders, customers, products, services, quotations] = selected && enabled ? await Promise.all([
    allowRead ? listOperationalSalesOrders(selected.tenantId, selected.branchId, { status: status(search.status) }) : Promise.resolve(undefined),
    allowCreate || allowManage ? listOperationalParties(selected.tenantId, { search: null, partyType: "customer", status: "active", page: 1 }) : Promise.resolve(undefined),
    allowCreate || allowManage ? listOperationalItems(selected.tenantId, { search: null, itemType: "product", status: "active", page: 1 }) : Promise.resolve(undefined),
    allowCreate || allowManage ? listOperationalItems(selected.tenantId, { search: null, itemType: "service", status: "active", page: 1 }) : Promise.resolve(undefined),
    allowCreate && allowQuoteRead ? listOperationalQuotations(selected.tenantId, selected.branchId, { status: "approved" }) : Promise.resolve(undefined),
  ]) : [];
  return <>
    <div className="page-heading-row"><div><p className="page-kicker">E-CONTROL / VENDAS / {requestedTx}</p><h1>{requestedTx === "ZVE01" ? "Criar pedido de venda" : requestedTx === "ZVE02" ? "Alterar pedido de venda" : requestedTx === "ZVE04" ? "Confirmar pedido de venda" : requestedTx === "ZVE05" ? "Reservar estoque" : requestedTx === "ZVE06" ? "Entregar pedido de venda" : requestedTx === "ZVE07" ? "Devolver venda" : "Consultar pedidos de venda"}</h1><p className="page-subtitle">Pedidos comerciais isolados por empresa e filial, com reserva e entrega valorada explicitamente autorizadas.</p></div><span className="workspace-badge">{enabled ? "Operacional habilitado" : "Aguardando ativação"}</span></div>
    <form className="master-filter-form" method="get"><input type="hidden" name="tx" value={requestedTx} /><label>Contexto<select name="filial" defaultValue={selected?.branchId ?? ""}>{access.contexts.map((context) => <option key={`${context.tenantId}-${context.branchId}`} value={context.branchId}>{context.companyName} · {context.branchCode} — {context.branchName}</option>)}</select></label><label>Situação<select name="status" defaultValue={status(search.status) ?? ""}><option value="">Todas</option><option value="draft">Rascunho</option><option value="confirmed">Confirmado</option><option value="fulfilled">Entregue</option><option value="cancelled">Cancelado</option></select></label><button type="submit">Consultar</button></form>
    {selected ? <SalesOrders tenantId={selected.tenantId} branchId={selected.branchId} enabled={enabled} customers={customers?.status === "ready" ? customers.data.rows : []} items={[...(products?.status === "ready" ? products.data.rows : []), ...(services?.status === "ready" ? services.data.rows : [])]} quotations={quotations?.status === "ready" ? quotations.data.rows : []} orders={orders?.status === "ready" ? orders.data.rows : []} allowCreate={allowCreate} allowManage={allowManage} allowRead={allowRead} allowDecide={allowDecide} allowReserve={allowReserve} allowFulfill={allowFulfill} allowReturn={allowReturn} /> : <p className="master-notice">{operationalContextMessage(access.status)}</p>}
  </>;
}
