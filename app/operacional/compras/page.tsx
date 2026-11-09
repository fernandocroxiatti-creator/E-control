import Link from "next/link";
import { PurchaseOrders } from "@/app/components/operational-catalog";
import { getOperationalTransactionContexts, operationalContextMessage } from "@/lib/companies/authorized-transaction-context";
import { authorizeRouteTransaction, isRouteAuthorized, operationalRouteTransaction, routeTransactionTitle } from "@/lib/operational/transaction-focus";
import { listOperationalProductOptions, listOperationalPurchaseOrders, listOperationalSupplierOptions } from "@/lib/operational/read-model";
import { getSupabaseEnv } from "@/lib/supabase/env";
import { createClient } from "@/lib/supabase/server";

export const dynamic = "force-dynamic";
type Search = { empresa?: string; filial?: string; q?: string; status?: string; page?: string; tx?: string };
const page = (value: string | undefined) => Number.isSafeInteger(Number(value)) && Number(value) > 0 ? Number(value) : 1;
const status = (value: string | undefined) => ["draft", "submitted", "cancelled"].includes(value ?? "") ? value! : null;
function pageLink(search: Search, value: number) { const query = new URLSearchParams(); for (const [key, item] of Object.entries({ ...search, page: value })) if (item) query.set(key, String(item)); return `/operacional/compras?${query}`; }

export default async function OperationalPurchasesPage({ searchParams }: { searchParams: Promise<Search> }) {
  const search = await searchParams; const client = await createClient();
  if (!client) return <p className="master-notice">Integração indisponível.</p>;
  const { data: { user } } = await client.auth.getUser(); const access = user ? await getOperationalTransactionContexts(client, user.id) : { status: "no_active_membership" as const, contexts: [] };
  const contexts = access.contexts; const selected = contexts.find((context) => context.branchId === search.filial) ?? contexts.find((context) => context.tenantId === search.empresa) ?? contexts[0];
  const tx = operationalRouteTransaction(search.tx); const requestedTx = tx === "ME21N" || tx === "ME23N" ? tx : null;
  const [createAccess, readAccess] = selected ? await Promise.all([
    authorizeRouteTransaction(client, "ME21N", selected.tenantId, selected.branchId),
    authorizeRouteTransaction(client, "ME23N", selected.tenantId, selected.branchId),
  ]) : [null, null];
  const allowCreate = isRouteAuthorized(createAccess) && createAccess?.status === "authorized";
  const allowRead = isRouteAuthorized(readAccess) && readAccess?.status === "authorized";
  const requestedAllowed = requestedTx === "ME21N" ? allowCreate : requestedTx === "ME23N" ? allowRead : allowCreate || allowRead;
  const enabled = Boolean(getSupabaseEnv()?.operationalEnabled); const currentPage = page(search.page); const selectedStatus = status(search.status);
  const [orders, suppliers, products] = selected && enabled && requestedAllowed ? await Promise.all([
    allowRead ? listOperationalPurchaseOrders(selected.tenantId, selected.branchId, { search: search.q?.trim() || null, status: selectedStatus, page: currentPage }) : Promise.resolve(undefined),
    allowCreate ? listOperationalSupplierOptions(selected.tenantId) : Promise.resolve(undefined),
    allowCreate ? listOperationalProductOptions(selected.tenantId) : Promise.resolve(undefined),
  ]) : [];
  const sourceUnavailable = Boolean(enabled && allowCreate && (suppliers?.status === "unavailable" || products?.status === "unavailable"));
  const orderReadUnavailable = Boolean(enabled && allowRead && orders?.status === "unavailable");
  const title = routeTransactionTitle(requestedTx) ?? "Pedidos de compra";
  const subtitle = requestedTx === "ME21N" ? "Crie rascunhos reais por filial; nenhum estoque, pagamento ou financeiro é gerado automaticamente." : requestedTx === "ME23N" ? "Consulte pedidos reais da empresa e filial selecionadas." : "Rascunhos empresariais por filial, sem efeitos automáticos no estoque ou financeiro.";
  return <>
    <div className="page-heading-row"><div><p className="page-kicker">E-CONTROL / COMPRAS{requestedTx ? ` / ${requestedTx}` : ""}</p><h1>{title}</h1><p className="page-subtitle">{subtitle}</p></div><div className="master-inline-actions"><span className="workspace-badge">{enabled ? "Operacional habilitado" : "Aguardando ativação"}</span>{requestedTx && <Link className="master-action" href="/operacional/compras">Voltar a compras</Link>}</div></div>
    {!requestedAllowed && selected ? <p className="master-notice">Acesso negado para {requestedTx ?? "Compras"}. O acesso direto pela URL não substitui a autorização da transação no banco.</p> : <><form className="master-filter-form" method="get"><input type="hidden" name="tx" value={requestedTx ?? ""} /><label>Contexto<select name="filial" defaultValue={selected?.branchId ?? ""}>{contexts.map((context) => <option key={`${context.tenantId}-${context.branchId}`} value={context.branchId}>{context.companyName} · {context.branchCode} — {context.branchName}</option>)}</select></label>{allowRead && <><label>Pesquisar<input name="q" type="search" maxLength={120} defaultValue={search.q ?? ""} placeholder="Fornecedor ou número" /></label><label>Situação<select name="status" defaultValue={selectedStatus ?? ""}><option value="">Todas</option><option value="draft">Rascunho</option><option value="submitted">Enviado</option><option value="cancelled">Cancelado</option></select></label></>}<button type="submit">Consultar</button></form>
      {selected ? <><PurchaseOrders tenantId={selected.tenantId} branchId={selected.branchId} enabled={enabled} allowCreate={allowCreate} allowRead={allowRead} suppliers={suppliers?.status === "ready" ? suppliers.data : []} products={products?.status === "ready" ? products.data : []} orders={orders?.status === "ready" ? orders.data.rows : []} />{(sourceUnavailable || orderReadUnavailable) && <p className="master-notice">A transação foi validada, mas não foi possível carregar fornecedores, produtos ou pedidos para este contexto. Nenhuma criação é simulada; atualize a página e consulte a administração se o problema persistir.</p>}{allowRead && orders?.status === "ready" && <nav className="master-pagination" aria-label="Paginação de pedidos de compra"><span>Página {orders.data.page}</span>{orders.data.page > 1 ? <Link href={pageLink(search, orders.data.page - 1)}>Anterior</Link> : <span aria-disabled="true">Anterior</span>}{orders.data.hasMore ? <Link href={pageLink(search, orders.data.page + 1)}>Próxima</Link> : <span aria-disabled="true">Próxima</span>}</nav>}</> : <p className="master-notice">{operationalContextMessage(access.status)}</p>}<p className="master-notice">A consulta e os rascunhos exigem ME21N e ME23N aprovadas, concedidas ao papel e disponíveis para a empresa; criar um pedido não movimenta estoque nem financeiro.</p></>}
  </>;
}
