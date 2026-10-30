import Link from "next/link";
import { OperationalCatalog } from "@/app/components/operational-catalog";
import { getSupabaseEnv } from "@/lib/supabase/env";
import { getAuthorizedTransactionContexts } from "@/lib/companies/authorized-transaction-context";
import { createClient } from "@/lib/supabase/server";
import { listOperationalItems, listOperationalParties, listOperationalSupplierOptions } from "@/lib/operational/read-model";

export const dynamic = "force-dynamic";

type Search = { empresa?: string; q?: string; party_type?: string; party_status?: string; item_type?: string; item_status?: string; party_page?: string; item_page?: string };
const oneOf = (value: string | undefined, allowed: string[]) => value && allowed.includes(value) ? value : null;
const page = (value: string | undefined) => Number.isSafeInteger(Number(value)) && Number(value) > 0 ? Number(value) : 1;

function linkFor(values: Record<string, string | number | null | undefined>) {
  const query = new URLSearchParams();
  for (const [key, value] of Object.entries(values)) if (value !== null && value !== undefined && value !== "") query.set(key, String(value));
  return `/operacional/cadastros?${query.toString()}`;
}

function Pagination({ label, current, hasMore, search, keyName }: { label: string; current: number; hasMore: boolean; search: Search; keyName: "party_page" | "item_page" }) {
  const prior = current > 1 ? linkFor({ ...search, [keyName]: current - 1 }) : null;
  const next = hasMore ? linkFor({ ...search, [keyName]: current + 1 }) : null;
  return <nav className="master-pagination" aria-label={`Paginação de ${label}`}><span>Página {current}</span>{prior ? <Link href={prior}>Anterior</Link> : <span aria-disabled="true">Anterior</span>}{next ? <Link href={next}>Próxima</Link> : <span aria-disabled="true">Próxima</span>}</nav>;
}

export default async function OperationalCatalogPage({ searchParams }: { searchParams: Promise<Search> }) {
  const search = await searchParams; const client = await createClient();
  if (!client) return <p className="master-notice">Integração indisponível.</p>;
  const { data: { user } } = await client.auth.getUser();
  const contexts = user ? await getAuthorizedTransactionContexts(client, user.id) : [];
  const tenantId = contexts.some((context) => context.tenantId === search.empresa) ? search.empresa! : contexts[0]?.tenantId;
  const companies = [...new Map(contexts.map((context) => [context.tenantId, context.companyName])).entries()];
  const env = getSupabaseEnv(); const enabled = Boolean(env?.operationalEnabled);
  const partyType = oneOf(search.party_type, ["customer", "supplier", "both"]); const partyStatus = oneOf(search.party_status, ["active", "inactive"]);
  const itemType = oneOf(search.item_type, ["product", "service"]); const itemStatus = oneOf(search.item_status, ["active", "inactive"]);
  const partyPage = page(search.party_page); const itemPage = page(search.item_page);
  const [parties, items, suppliers] = tenantId && enabled ? await Promise.all([
    listOperationalParties(tenantId, { search: search.q?.trim() || null, partyType, status: partyStatus, page: partyPage }),
    listOperationalItems(tenantId, { search: search.q?.trim() || null, itemType, status: itemStatus, page: itemPage }),
    listOperationalSupplierOptions(tenantId),
  ]) : [];
  const filterSearch: Search = { empresa: tenantId, q: search.q?.trim() || undefined, party_type: partyType ?? undefined, party_status: partyStatus ?? undefined, item_type: itemType ?? undefined, item_status: itemStatus ?? undefined };
  return <>
    <div className="page-heading-row"><div><p className="page-kicker">E-CONTROL / CADASTROS OPERACIONAIS</p><h1>Clientes, fornecedores, produtos e serviços</h1><p className="page-subtitle">Dados persistentes por empresa, protegidos por autorização e auditoria.</p></div><span className="workspace-badge">{enabled ? "Operacional habilitado" : "Aguardando ativação"}</span></div>
    <form className="master-filter-form" method="get"><label>Empresa<select name="empresa" defaultValue={tenantId ?? ""}><option value="">Selecione</option>{companies.map(([id, name]) => <option key={id} value={id}>{name}</option>)}</select></label><label>Pesquisar<input name="q" type="search" maxLength={120} defaultValue={search.q ?? ""} placeholder="Nome, SKU ou documento" /></label><label>Tipo de pessoa<select name="party_type" defaultValue={partyType ?? ""}><option value="">Todos</option><option value="customer">Cliente</option><option value="supplier">Fornecedor</option><option value="both">Cliente e fornecedor</option></select></label><label>Situação de pessoa<select name="party_status" defaultValue={partyStatus ?? ""}><option value="">Todas</option><option value="active">Ativa</option><option value="inactive">Inativa</option></select></label><label>Tipo de item<select name="item_type" defaultValue={itemType ?? ""}><option value="">Todos</option><option value="product">Produto</option><option value="service">Serviço</option></select></label><label>Situação de item<select name="item_status" defaultValue={itemStatus ?? ""}><option value="">Todas</option><option value="active">Ativo</option><option value="inactive">Inativo</option></select></label><button type="submit">Consultar</button></form>
    {tenantId ? <>
      <OperationalCatalog tenantId={tenantId} enabled={enabled} parties={parties?.status === "ready" ? parties.data.rows : []} items={items?.status === "ready" ? items.data.rows : []} suppliers={suppliers?.status === "ready" ? suppliers.data : []} />
      {parties?.status === "ready" && <Pagination label="clientes e fornecedores" current={parties.data.page} hasMore={parties.data.hasMore} search={{ ...filterSearch, item_page: String(itemPage) }} keyName="party_page" />}
      {items?.status === "ready" && <Pagination label="produtos e serviços" current={items.data.page} hasMore={items.data.hasMore} search={{ ...filterSearch, party_page: String(partyPage) }} keyName="item_page" />}
    </> : <p className="master-notice">Nenhuma empresa autorizada está disponível para consulta.</p>}
    <p className="master-notice">O <Link href="/operacional/estoque">estoque</Link> usa apenas movimentos auditados e não permite saldo negativo.</p>
  </>;
}
