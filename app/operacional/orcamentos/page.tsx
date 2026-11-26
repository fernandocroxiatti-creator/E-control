import { Quotations } from "@/app/components/operational-catalog";
import { getOperationalTransactionContexts, operationalContextMessage } from "@/lib/companies/authorized-transaction-context";
import { listOperationalItems, listOperationalParties, listOperationalQuotations } from "@/lib/operational/read-model";
import { authorizeRouteTransaction, isRouteAuthorized, operationalRouteTransaction } from "@/lib/operational/transaction-focus";
import { getSupabaseEnv } from "@/lib/supabase/env";
import { createClient } from "@/lib/supabase/server";

export const dynamic = "force-dynamic";
type Search = { empresa?: string; filial?: string; status?: string; tx?: string };
const status = (value: string | undefined) => ["draft", "approved", "rejected", "cancelled"].includes(value ?? "") ? value! : null;

export default async function OperationalQuotationsPage({ searchParams }: { searchParams: Promise<Search> }) {
  const search = await searchParams; const client = await createClient();
  if (!client) return <p className="master-notice">Integração indisponível.</p>;
  const { data: { user } } = await client.auth.getUser();
  const access = user ? await getOperationalTransactionContexts(client, user.id) : { status: "no_active_membership" as const, contexts: [] };
  const selected = access.contexts.find((context) => context.branchId === search.filial) ?? access.contexts.find((context) => context.tenantId === search.empresa) ?? access.contexts[0];
  const enabled = Boolean(getSupabaseEnv()?.operationalEnabled); const focus = operationalRouteTransaction(search.tx); const requestedTx = focus && ["ZQT01", "ZQT02", "ZQT03", "ZQT04"].includes(focus) ? focus : "ZQT03";
  const [createAccess, manageAccess, readAccess, approveAccess, serviceCreateAccess, serviceUpdateAccess] = selected && enabled ? await Promise.all([
    authorizeRouteTransaction(client, "ZQT01", selected.tenantId, selected.branchId), authorizeRouteTransaction(client, "ZQT02", selected.tenantId, selected.branchId),
    authorizeRouteTransaction(client, "ZQT03", selected.tenantId, selected.branchId), authorizeRouteTransaction(client, "ZQT04", selected.tenantId, selected.branchId),
    authorizeRouteTransaction(client, "ZOS01", selected.tenantId, selected.branchId), authorizeRouteTransaction(client, "ZOS02", selected.tenantId, selected.branchId),
  ]) : [];
  const allowCreate = isRouteAuthorized(createAccess ?? null) && createAccess?.status === "authorized";
  const allowManage = isRouteAuthorized(manageAccess ?? null) && manageAccess?.status === "authorized";
  const allowRead = isRouteAuthorized(readAccess ?? null) && readAccess?.status === "authorized";
  const allowApprove = isRouteAuthorized(approveAccess ?? null) && approveAccess?.status === "authorized";
  const allowConversion = isRouteAuthorized(serviceCreateAccess ?? null) && serviceCreateAccess?.status === "authorized" && isRouteAuthorized(serviceUpdateAccess ?? null) && serviceUpdateAccess?.status === "authorized" && allowRead;
  const [quotes, customers, products, services] = selected && enabled ? await Promise.all([
    allowRead ? listOperationalQuotations(selected.tenantId, selected.branchId, { status: status(search.status) }) : Promise.resolve(undefined),
    allowCreate || allowManage ? listOperationalParties(selected.tenantId, { search: null, partyType: "customer", status: "active", page: 1 }) : Promise.resolve(undefined),
    allowCreate || allowManage ? listOperationalItems(selected.tenantId, { search: null, itemType: "product", status: "active", page: 1 }) : Promise.resolve(undefined),
    allowCreate || allowManage ? listOperationalItems(selected.tenantId, { search: null, itemType: "service", status: "active", page: 1 }) : Promise.resolve(undefined),
  ]) : [];
  return <>
    <div className="page-heading-row"><div><p className="page-kicker">E-CONTROL / ORÇAMENTOS / {requestedTx}</p><h1>{requestedTx === "ZQT01" ? "Criar orçamento" : requestedTx === "ZQT02" ? "Alterar orçamento" : requestedTx === "ZQT04" ? "Aprovar orçamento" : "Consultar orçamentos"}</h1><p className="page-subtitle">Propostas comerciais por empresa e filial, com fotografia de preço, custo e desconto.</p></div><span className="workspace-badge">{enabled ? "Operacional habilitado" : "Aguardando ativação"}</span></div>
    <form className="master-filter-form" method="get"><input type="hidden" name="tx" value={requestedTx} /><label>Contexto<select name="filial" defaultValue={selected?.branchId ?? ""}>{access.contexts.map((context) => <option key={`${context.tenantId}-${context.branchId}`} value={context.branchId}>{context.companyName} · {context.branchCode} — {context.branchName}</option>)}</select></label><label>Situação<select name="status" defaultValue={status(search.status) ?? ""}><option value="">Todas</option><option value="draft">Rascunho</option><option value="approved">Aprovado</option><option value="rejected">Reprovado</option><option value="cancelled">Cancelado</option></select></label><button type="submit">Consultar</button></form>
    {selected ? <Quotations tenantId={selected.tenantId} branchId={selected.branchId} enabled={enabled} customers={customers?.status === "ready" ? customers.data.rows : []} items={[...(products?.status === "ready" ? products.data.rows : []), ...(services?.status === "ready" ? services.data.rows : [])]} quotations={quotes?.status === "ready" ? quotes.data.rows : []} allowCreate={allowCreate} allowManage={allowManage} allowRead={allowRead} allowApprove={allowApprove} allowConversion={allowConversion} /> : <p className="master-notice">{operationalContextMessage(access.status)}</p>}
    <p className="master-notice">ZQT01 cria rascunhos; ZQT02 altera apenas rascunhos; ZQT03 consulta; ZQT04 decide com justificativa. A disponibilização empresarial é manual pelo Admin Master e nenhuma venda, O.S., estoque ou financeiro é gerado nesta etapa.</p>
  </>;
}
