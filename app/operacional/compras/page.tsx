import Link from "next/link";
import { PurchaseOrders } from "@/app/components/operational-catalog";
import { getAuthorizedTransactionContexts } from "@/lib/companies/authorized-transaction-context";
import { listOperationalProductOptions, listOperationalPurchaseOrders, listOperationalSupplierOptions } from "@/lib/operational/read-model";
import { getSupabaseEnv } from "@/lib/supabase/env";
import { createClient } from "@/lib/supabase/server";

export const dynamic = "force-dynamic";
type Search = { empresa?: string; filial?: string; q?: string; status?: string; page?: string };
const page = (value: string | undefined) => Number.isSafeInteger(Number(value)) && Number(value) > 0 ? Number(value) : 1;
const status = (value: string | undefined) => ["draft", "submitted", "cancelled"].includes(value ?? "") ? value! : null;
function pageLink(search: Search, value: number) { const query = new URLSearchParams(); for (const [key, item] of Object.entries({ ...search, page: value })) if (item) query.set(key, String(item)); return `/operacional/compras?${query}`; }

export default async function OperationalPurchasesPage({ searchParams }: { searchParams: Promise<Search> }) {
  const search = await searchParams; const client = await createClient();
  if (!client) return <p className="master-notice">Integração indisponível.</p>;
  const { data: { user } } = await client.auth.getUser(); const contexts = user ? await getAuthorizedTransactionContexts(client, user.id) : [];
  const selected = contexts.find((context) => context.branchId === search.filial) ?? contexts.find((context) => context.tenantId === search.empresa) ?? contexts[0];
  const enabled = Boolean(getSupabaseEnv()?.operationalEnabled); const currentPage = page(search.page); const selectedStatus = status(search.status);
  const [orders, suppliers, products] = selected && enabled ? await Promise.all([
    listOperationalPurchaseOrders(selected.tenantId, selected.branchId, { search: search.q?.trim() || null, status: selectedStatus, page: currentPage }),
    listOperationalSupplierOptions(selected.tenantId), listOperationalProductOptions(selected.tenantId),
  ]) : [];
  return <>
    <div className="page-heading-row"><div><p className="page-kicker">E-CONTROL / COMPRAS</p><h1>Pedidos de compra</h1><p className="page-subtitle">Rascunhos empresariais por filial, sem efeitos automáticos no estoque ou financeiro.</p></div><span className="workspace-badge">{enabled ? "Operacional habilitado" : "Aguardando ativação"}</span></div>
    <form className="master-filter-form" method="get"><label>Contexto<select name="filial" defaultValue={selected?.branchId ?? ""}>{contexts.map((context) => <option key={`${context.tenantId}-${context.branchId}`} value={context.branchId}>{context.companyName} · {context.branchCode} — {context.branchName}</option>)}</select></label><label>Pesquisar<input name="q" type="search" maxLength={120} defaultValue={search.q ?? ""} placeholder="Fornecedor ou número" /></label><label>Situação<select name="status" defaultValue={selectedStatus ?? ""}><option value="">Todas</option><option value="draft">Rascunho</option><option value="submitted">Enviado</option><option value="cancelled">Cancelado</option></select></label><button type="submit">Consultar</button></form>
    {selected ? <>
      <PurchaseOrders tenantId={selected.tenantId} branchId={selected.branchId} enabled={enabled} suppliers={suppliers?.status === "ready" ? suppliers.data : []} products={products?.status === "ready" ? products.data : []} orders={orders?.status === "ready" ? orders.data.rows : []} />
      {orders?.status === "ready" && <nav className="master-pagination" aria-label="Paginação de pedidos de compra"><span>Página {orders.data.page}</span>{orders.data.page > 1 ? <Link href={pageLink(search, orders.data.page - 1)}>Anterior</Link> : <span aria-disabled="true">Anterior</span>}{orders.data.hasMore ? <Link href={pageLink(search, orders.data.page + 1)}>Próxima</Link> : <span aria-disabled="true">Próxima</span>}</nav>}
    </> : <p className="master-notice">Nenhuma empresa e filial autorizadas estão disponíveis.</p>}
    <p className="master-notice">A consulta e os rascunhos exigem as transações ME21N e ME23N aprovadas e concedidas ao papel empresarial. <Link href="/operacional/estoque">Estoque</Link> permanece independente.</p>
  </>;
}
