import Link from "next/link";
import { OperationalCatalog, type CatalogFocus } from "@/app/components/operational-catalog";
import { getOperationalTransactionContexts, operationalContextMessage } from "@/lib/companies/authorized-transaction-context";
import { authorizeRouteTransaction, isRouteAuthorized, operationalRouteTransaction, routeTransactionTitle } from "@/lib/operational/transaction-focus";
import { listOperationalItems, listOperationalParties, listOperationalSupplierOptions } from "@/lib/operational/read-model";
import { getSupabaseEnv } from "@/lib/supabase/env";
import { createClient } from "@/lib/supabase/server";

export const dynamic = "force-dynamic";
type Search = { empresa?: string; q?: string; party_type?: string; party_status?: string; item_status?: string; party_page?: string; item_page?: string; tx?: string };
const oneOf = (value: string | undefined, allowed: string[]) => value && allowed.includes(value) ? value : null;
const page = (value: string | undefined) => Number.isSafeInteger(Number(value)) && Number(value) > 0 ? Number(value) : 1;
const focusFor = (tx: string | null): CatalogFocus => tx === "BP01" ? "parties" : tx === "MM01" ? "products" : tx === "SV01" ? "services" : "all";

function linkFor(values: Record<string, string | number | null | undefined>) {
  const query = new URLSearchParams();
  for (const [key, value] of Object.entries(values)) if (value !== null && value !== undefined && value !== "") query.set(key, String(value));
  return `/operacional/cadastros?${query.toString()}`;
}
function Pagination({ label, current, hasMore, search, keyName }: { label: string; current: number; hasMore: boolean; search: Search; keyName: "party_page" | "item_page" }) {
  const prior = current > 1 ? linkFor({ ...search, [keyName]: current - 1 }) : null; const next = hasMore ? linkFor({ ...search, [keyName]: current + 1 }) : null;
  return <nav className="master-pagination" aria-label={`Paginação de ${label}`}><span>Página {current}</span>{prior ? <Link href={prior}>Anterior</Link> : <span aria-disabled="true">Anterior</span>}{next ? <Link href={next}>Próxima</Link> : <span aria-disabled="true">Próxima</span>}</nav>;
}

export default async function OperationalCatalogPage({ searchParams }: { searchParams: Promise<Search> }) {
  const search = await searchParams; const client = await createClient();
  if (!client) return <p className="master-notice">Integração indisponível.</p>;
  const { data: { user } } = await client.auth.getUser();
  const access = user ? await getOperationalTransactionContexts(client, user.id) : { status: "no_active_membership" as const, contexts: [] };
  const contexts = access.contexts; const tenantId = contexts.some((context) => context.tenantId === search.empresa) ? search.empresa! : contexts[0]?.tenantId;
  const selectedContext = contexts.find((context) => context.tenantId === tenantId);
  const tx = operationalRouteTransaction(search.tx); const focus = focusFor(tx);
  const routeAccess = await authorizeRouteTransaction(client, tx, selectedContext?.tenantId, selectedContext?.branchId);
  const routeAuthorized = isRouteAuthorized(routeAccess);
  const companies = [...new Map(contexts.map((context) => [context.tenantId, context.companyName])).entries()];
  const enabled = Boolean(getSupabaseEnv()?.operationalEnabled); const partyType = oneOf(search.party_type, ["customer", "supplier", "both"]); const partyStatus = oneOf(search.party_status, ["active", "inactive"]); const itemStatus = oneOf(search.item_status, ["active", "inactive"]); const partyPage = page(search.party_page); const itemPage = page(search.item_page);
  const itemType = focus === "products" ? "product" : focus === "services" ? "service" : null;
  const [parties, items, suppliers] = tenantId && enabled && routeAuthorized ? await Promise.all([
    focus !== "products" && focus !== "services" ? listOperationalParties(tenantId, { search: search.q?.trim() || null, partyType, status: partyStatus, page: partyPage }) : Promise.resolve(undefined),
    focus !== "parties" ? listOperationalItems(tenantId, { search: search.q?.trim() || null, itemType, status: itemStatus, page: itemPage }) : Promise.resolve(undefined),
    focus !== "parties" ? listOperationalSupplierOptions(tenantId) : Promise.resolve(undefined),
  ]) : [];
  const title = routeTransactionTitle(tx) ?? "Clientes, fornecedores, produtos e serviços";
  const subtitle = tx === "BP01" ? "Cadastro e consulta de clientes e fornecedores autorizados." : tx === "MM01" ? "Cadastro e consulta de produtos autorizados." : tx === "SV01" ? "Cadastro e consulta de serviços autorizados." : "Dados persistentes por empresa, protegidos por autorização e auditoria.";
  const filters: Search = { empresa: tenantId, tx: tx ?? undefined, q: search.q?.trim() || undefined, party_type: partyType ?? undefined, party_status: partyStatus ?? undefined, item_status: itemStatus ?? undefined };
  const readUnavailable = Boolean(enabled && routeAuthorized && ((focus === "parties" && parties?.status === "unavailable") || (focus !== "parties" && items?.status === "unavailable")));
  return <>
    <div className="page-heading-row"><div><p className="page-kicker">E-CONTROL / CADASTROS OPERACIONAIS{tx ? ` / ${tx}` : ""}</p><h1>{title}</h1><p className="page-subtitle">{subtitle}</p></div><div className="master-inline-actions"><span className="workspace-badge">{enabled ? "Operacional habilitado" : "Aguardando ativação"}</span>{tx && <Link className="master-action" href={linkFor({ empresa: tenantId })}>Voltar aos cadastros</Link>}</div></div>
    {tx && !routeAuthorized ? <p className="master-notice">Acesso negado para {tx}. A URL não substitui a autorização por empresa, filial, papel, grant e transação.</p> : <>
      <form className="master-filter-form" method="get"><input type="hidden" name="tx" value={tx ?? ""} /><label>Empresa<select name="empresa" defaultValue={tenantId ?? ""}><option value="">Selecione</option>{companies.map(([id, name]) => <option key={id} value={id}>{name}</option>)}</select></label><label>Pesquisar<input name="q" type="search" maxLength={120} defaultValue={search.q ?? ""} placeholder={focus === "parties" ? "Nome ou documento" : "SKU ou descrição"} /></label>{focus === "parties" && <><label>Tipo<select name="party_type" defaultValue={partyType ?? ""}><option value="">Todos</option><option value="customer">Cliente</option><option value="supplier">Fornecedor</option><option value="both">Cliente e fornecedor</option></select></label><label>Situação<select name="party_status" defaultValue={partyStatus ?? ""}><option value="">Todas</option><option value="active">Ativa</option><option value="inactive">Inativa</option></select></label></>}{focus !== "parties" && <label>Situação<select name="item_status" defaultValue={itemStatus ?? ""}><option value="">Todas</option><option value="active">Ativo</option><option value="inactive">Inativo</option></select></label>}<button type="submit">Consultar</button></form>
      {tenantId ? <><OperationalCatalog tenantId={tenantId} enabled={enabled} focus={focus} parties={parties?.status === "ready" ? parties.data.rows : []} items={items?.status === "ready" ? items.data.rows : []} suppliers={suppliers?.status === "ready" ? suppliers.data : []} />{readUnavailable && <p className="master-notice">A transação foi validada, mas não foi possível carregar os registros deste contexto. Nenhum dado foi exposto por atalho; atualize a página e consulte a administração se o problema persistir.</p>}{parties?.status === "ready" && <Pagination label="clientes e fornecedores" current={parties.data.page} hasMore={parties.data.hasMore} search={{ ...filters, item_page: String(itemPage) }} keyName="party_page" />}{items?.status === "ready" && <Pagination label="itens" current={items.data.page} hasMore={items.data.hasMore} search={{ ...filters, party_page: String(partyPage) }} keyName="item_page" />}</> : <p className="master-notice">{operationalContextMessage(access.status)}</p>}
    </>}
  </>;
}
