import Link from "next/link";
import { createClient } from "@/lib/supabase/server";
import { InventoryMovementForm, InventoryMovementHistory } from "@/app/components/operational-catalog";
import { getOperationalTransactionContexts, operationalContextMessage } from "@/lib/companies/authorized-transaction-context";
import { getSupabaseEnv } from "@/lib/supabase/env";
import { listOperationalInventoryMovements, listOperationalProductOptions, listOperationalStock } from "@/lib/operational/read-model";

export const dynamic = "force-dynamic";
type Search = { empresa?: string; filial?: string; q?: string; item?: string; movement_type?: string; from?: string; to?: string; page?: string; history_page?: string };
const requestedPage = (value: string | undefined) => Number.isSafeInteger(Number(value)) && Number(value) > 0 ? Number(value) : 1;
const uuid = (value: string | undefined) => value && /^[0-9a-f]{8}-[0-9a-f]{4}-[1-8][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i.test(value) ? value : null;
const movementType = (value: string | undefined) => ["initial", "entry", "exit", "adjustment_positive", "adjustment_negative"].includes(value ?? "") ? value! : null;
function pageLink(search: Search, key: "page" | "history_page", value: number) { const q = new URLSearchParams(); for (const [name, item] of Object.entries({ ...search, [key]: value })) if (item) q.set(name, String(item)); return `/operacional/estoque?${q}`; }

export default async function OperationalInventoryPage({ searchParams }: { searchParams: Promise<Search> }) {
  const search = await searchParams; const client = await createClient(); if (!client) return <p className="master-notice">Integração indisponível.</p>;
  const { data: { user } } = await client.auth.getUser(); const access = user ? await getOperationalTransactionContexts(client, user.id) : { status: "no_active_membership" as const, contexts: [] };
  const contexts = access.contexts;
  const selected = contexts.find((context) => context.branchId === search.filial) ?? contexts.find((context) => context.tenantId === search.empresa) ?? contexts[0]; const enabled = Boolean(getSupabaseEnv()?.operationalEnabled);
  const stockPage = requestedPage(search.page); const historyPage = requestedPage(search.history_page); const selectedItem = uuid(search.item); const selectedType = movementType(search.movement_type);
  const [stock, history, products] = selected && enabled ? await Promise.all([
    listOperationalStock(selected.tenantId, selected.branchId, { search: search.q?.trim() || null, page: stockPage }),
    listOperationalInventoryMovements(selected.tenantId, selected.branchId, { itemId: selectedItem, movementType: selectedType, from: search.from || null, to: search.to || null, page: historyPage }),
    listOperationalProductOptions(selected.tenantId),
  ]) : [];
  return <>
    <div className="page-heading-row"><div><p className="page-kicker">E-CONTROL / ESTOQUE</p><h1>Saldo e movimentações por filial</h1><p className="page-subtitle">Produtos ativos, movimentos auditados e saldo negativo bloqueado pela transação.</p></div><span className="workspace-badge">{enabled ? "Operacional habilitado" : "Aguardando ativação"}</span></div>
    <form className="master-filter-form" method="get"><label>Contexto<select name="filial" defaultValue={selected?.branchId ?? ""}>{contexts.map((context) => <option key={`${context.tenantId}-${context.branchId}`} value={context.branchId}>{context.companyName} · {context.branchCode} — {context.branchName}</option>)}</select></label><label>Pesquisar saldo<input name="q" type="search" maxLength={120} defaultValue={search.q ?? ""} placeholder="SKU ou produto" /></label><label>Produto no histórico<select name="item" defaultValue={selectedItem ?? ""}><option value="">Todos</option>{products?.status === "ready" && products.data.map((product) => <option key={product.item_id} value={product.item_id}>{product.code} · {product.name}</option>)}</select></label><label>Tipo de movimento<select name="movement_type" defaultValue={selectedType ?? ""}><option value="">Todos</option><option value="initial">Estoque inicial</option><option value="entry">Entrada</option><option value="exit">Saída</option><option value="adjustment_positive">Ajuste positivo</option><option value="adjustment_negative">Ajuste negativo</option></select></label><label>De<input name="from" type="date" defaultValue={search.from ?? ""} /></label><label>Até<input name="to" type="date" defaultValue={search.to ?? ""} /></label><button type="submit">Consultar</button></form>
    {stock?.status === "ready" ? <>
      <InventoryMovementForm tenantId={selected!.tenantId} branchId={selected!.branchId} enabled={enabled} rows={stock.data.rows} />
      {stock.data.rows.length ? <div className="master-table-wrap" tabIndex={0}><table className="master-table"><thead><tr><th>SKU</th><th>Produto</th><th>Saldo</th><th>Mínimo</th><th>Reposição</th></tr></thead><tbody>{stock.data.rows.map((row) => <tr key={row.item_id}><td><code>{row.code}</code></td><td><strong>{row.name}</strong></td><td>{row.quantity}</td><td>{row.minimum_stock}</td><td>{row.below_reorder_point ? "Atenção" : row.reorder_point}</td></tr>)}</tbody></table></div> : <p className="master-panel-empty">Nenhum produto ativo atende aos filtros desta filial.</p>}
      <nav className="master-pagination" aria-label="Paginação de saldo"><span>Página {stock.data.page}</span>{stock.data.page > 1 ? <Link href={pageLink(search, "page", stock.data.page - 1)}>Anterior</Link> : <span aria-disabled="true">Anterior</span>}{stock.data.hasMore ? <Link href={pageLink(search, "page", stock.data.page + 1)}>Próxima</Link> : <span aria-disabled="true">Próxima</span>}</nav>
      {history?.status === "ready" && <><InventoryMovementHistory movements={history.data.rows} /><nav className="master-pagination" aria-label="Paginação de movimentações"><span>Página {history.data.page}</span>{history.data.page > 1 ? <Link href={pageLink(search, "history_page", history.data.page - 1)}>Anterior</Link> : <span aria-disabled="true">Anterior</span>}{history.data.hasMore ? <Link href={pageLink(search, "history_page", history.data.page + 1)}>Próxima</Link> : <span aria-disabled="true">Próxima</span>}</nav></>}
    </> : <p className="master-notice">{access.status === "ready" ? "A consulta e os movimentos de estoque permanecem bloqueados até a ativação autorizada da fundação operacional." : operationalContextMessage(access.status)}</p>}
    <p className="master-notice"><Link href="/operacional/cadastros">Cadastros operacionais</Link> · A leitura do histórico é feita pela RPC autorizada e não expõe a tabela diretamente.</p>
  </>;
}
