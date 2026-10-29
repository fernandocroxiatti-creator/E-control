import Link from "next/link";
import { createClient } from "@/lib/supabase/server";
import { InventoryMovementForm } from "@/app/components/operational-catalog";
import { getAuthorizedTransactionContexts } from "@/lib/companies/authorized-transaction-context";
import { getSupabaseEnv } from "@/lib/supabase/env";
import { listOperationalStock } from "@/lib/operational/read-model";

export const dynamic = "force-dynamic";
export default async function OperationalInventoryPage({ searchParams }: { searchParams: Promise<{ empresa?: string; filial?: string; q?: string }> }) {
  const { empresa, filial, q } = await searchParams; const client = await createClient(); if (!client) return <p className="master-notice">Integração indisponível.</p>;
  const { data: { user } } = await client.auth.getUser(); const contexts = user ? await getAuthorizedTransactionContexts(client,user.id) : [];
  const selected = contexts.find((context) => context.tenantId === empresa && context.branchId === filial) ?? contexts[0]; const enabled = Boolean(getSupabaseEnv()?.operationalEnabled);
  const stock = selected && enabled ? await listOperationalStock(selected.tenantId,selected.branchId,q ?? null) : null;
  return <><div className="page-heading-row"><div><p className="page-kicker">E-CONTROL / ESTOQUE</p><h1>Saldo por filial</h1><p className="page-subtitle">Apenas produtos ativos, movimentos auditados e saldo negativo bloqueado.</p></div><span className="workspace-badge">{enabled ? "Operacional habilitado" : "Aguardando ativação"}</span></div><form className="master-filter-form" method="get"><label>Contexto<select name="filial" defaultValue={selected?.branchId ?? ""}>{contexts.map((context) => <option key={context.branchId} value={context.branchId}>{context.companyName} · {context.branchCode} — {context.branchName}</option>)}</select></label><input type="hidden" name="empresa" value={selected?.tenantId ?? ""} /><label>Pesquisar<input name="q" type="search" defaultValue={q ?? ""} /></label><button type="submit">Consultar</button></form>{stock?.status === "ready" ? <><InventoryMovementForm tenantId={selected!.tenantId} branchId={selected!.branchId} enabled={enabled} rows={stock.data} /><div className="master-table-wrap"><table className="master-table"><thead><tr><th>SKU</th><th>Produto</th><th>Saldo</th><th>Mínimo</th><th>Reposição</th></tr></thead><tbody>{stock.data.map((row) => <tr key={row.item_id}><td><code>{row.code}</code></td><td><strong>{row.name}</strong></td><td>{row.quantity}</td><td>{row.minimum_stock}</td><td>{row.below_reorder_point ? "Atenção" : row.reorder_point}</td></tr>)}</tbody></table></div></> : <p className="master-notice">A consulta e os movimentos de estoque permanecem bloqueados até a ativação autorizada da fundação operacional.</p>}<p className="master-notice"><Link href="/operacional/cadastros">Cadastros operacionais</Link> · Produtos e serviços não movimentam estoque no momento do cadastro.</p></>;
}
