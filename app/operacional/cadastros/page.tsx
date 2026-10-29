import Link from "next/link";
import { OperationalCatalog } from "@/app/components/operational-catalog";
import { getSupabaseEnv } from "@/lib/supabase/env";
import { getAuthorizedTransactionContexts } from "@/lib/companies/authorized-transaction-context";
import { createClient } from "@/lib/supabase/server";
import { listOperationalItems, listOperationalParties } from "@/lib/operational/read-model";

export const dynamic = "force-dynamic";
export default async function OperationalCatalogPage({ searchParams }: { searchParams: Promise<{ empresa?: string; q?: string }> }) {
  const { empresa, q } = await searchParams; const client = await createClient();
  if (!client) return <p className="master-notice">Integração indisponível.</p>;
  const { data: { user } } = await client.auth.getUser();
  const contexts = user ? await getAuthorizedTransactionContexts(client, user.id) : [];
  const tenantId = contexts.some((context) => context.tenantId === empresa) ? empresa! : contexts[0]?.tenantId;
  const companies = [...new Map(contexts.map((context) => [context.tenantId, context.companyName])).entries()];
  const env = getSupabaseEnv(); const enabled = Boolean(env?.operationalEnabled);
  const [parties, items] = tenantId && enabled ? await Promise.all([listOperationalParties(tenantId, q ?? null), listOperationalItems(tenantId, q ?? null)]) : [];
  return <><div className="page-heading-row"><div><p className="page-kicker">E-CONTROL / CADASTROS OPERACIONAIS</p><h1>Clientes, fornecedores, produtos e serviços</h1><p className="page-subtitle">Dados persistentes por empresa, protegidos por autorização e auditoria.</p></div><span className="workspace-badge">{enabled ? "Operacional habilitado" : "Aguardando ativação"}</span></div><form className="master-filter-form" method="get"><label>Empresa<select name="empresa" defaultValue={tenantId ?? ""}><option value="">Selecione</option>{companies.map(([id,name]) => <option key={id} value={id}>{name}</option>)}</select></label><label>Pesquisar<input name="q" type="search" maxLength={120} defaultValue={q ?? ""} placeholder="Nome, SKU ou documento" /></label><button type="submit">Consultar</button></form>{tenantId ? <OperationalCatalog tenantId={tenantId} enabled={enabled} parties={parties?.status === "ready" ? parties.data : []} items={items?.status === "ready" ? items.data : []} /> : <p className="master-notice">Nenhuma empresa autorizada está disponível para consulta.</p>}<p className="master-notice">O <Link href="/operacional/estoque">estoque</Link> usa apenas movimentos auditados e não permite saldo negativo.</p></>;
}
