import { CashTreasury } from "@/app/components/cash-treasury";
import { getOperationalTransactionContexts, operationalContextMessage } from "@/lib/companies/authorized-transaction-context";
import { listOperationalCashMovements, listOperationalCashRegisters, listOperationalCashSessions } from "@/lib/operational/read-model";
import { authorizeRouteTransaction, isRouteAuthorized, operationalRouteTransaction } from "@/lib/operational/transaction-focus";
import { getSupabaseEnv } from "@/lib/supabase/env";
import { createClient } from "@/lib/supabase/server";

export const dynamic = "force-dynamic";
type Search = { empresa?: string; filial?: string; tx?: string };
const cashTransactions = ["ZCX01", "ZCX02", "ZCX03", "ZCX04"] as const;
export default async function OperationalCashPage({ searchParams }: { searchParams: Promise<Search> }) {
  const search = await searchParams; const client = await createClient();
  if (!client) return <p className="master-notice">Integração indisponível.</p>;
  const { data: { user } } = await client.auth.getUser(); const access = user ? await getOperationalTransactionContexts(client, user.id) : { status: "no_active_membership" as const, contexts: [] };
  const selected = access.contexts.find((row) => row.branchId === search.filial) ?? access.contexts.find((row) => row.tenantId === search.empresa) ?? access.contexts[0]; const enabled = Boolean(getSupabaseEnv()?.operationalEnabled);
  const focus = operationalRouteTransaction(search.tx); const tx = focus && ["ZCX01", "ZCX02", "ZCX03", "ZCX04"].includes(focus) ? focus : "ZCX04";
  const [openAccess, moveAccess, closeAccess, readAccess] = selected && enabled ? await Promise.all(cashTransactions.map((code) => authorizeRouteTransaction(client, code, selected.tenantId, selected.branchId))) : [];
  const allowOpen = isRouteAuthorized(openAccess); const allowMove = isRouteAuthorized(moveAccess); const allowClose = isRouteAuthorized(closeAccess); const allowRead = isRouteAuthorized(readAccess);
  const [registers, sessions, movements] = selected && enabled && allowRead ? await Promise.all([listOperationalCashRegisters(selected.tenantId, selected.branchId, {}), listOperationalCashSessions(selected.tenantId, selected.branchId, {}), listOperationalCashMovements(selected.tenantId, selected.branchId, {})]) : [];
  return <><div className="page-heading-row"><div><p className="page-kicker">E-CONTROL / CAIXA / {tx}</p><h1>{tx === "ZCX01" ? "Abrir caixa" : tx === "ZCX02" ? "Movimentar caixa" : tx === "ZCX03" ? "Fechar caixa" : "Consultar caixa"}</h1><p className="page-subtitle">Caixa por empresa e filial, com saldo conferido e trilha de auditoria.</p></div><span className="workspace-badge">{enabled ? "Operacional habilitado" : "Aguardando ativação"}</span></div>{selected ? <CashTreasury tenantId={selected.tenantId} branchId={selected.branchId} enabled={enabled} registers={registers?.status === "ready" ? registers.data.rows : []} sessions={sessions?.status === "ready" ? sessions.data.rows : []} movements={movements?.status === "ready" ? movements.data.rows : []} allowOpen={allowOpen} allowMove={allowMove} allowClose={allowClose} allowRead={allowRead} /> : <p className="master-notice">{operationalContextMessage(access.status)}</p>}<p className="master-notice">ZCX01–ZCX04 permanecem bloqueadas por padrão até aprovação global, disponibilidade empresarial e grant scoped. Nenhuma ação desta tela cria baixa financeira, conciliação bancária, lançamento fiscal ou contábil.</p></>;
}
