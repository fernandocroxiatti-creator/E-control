"use client";

import { useOperationalRequest } from "@/lib/operational/use-operational-request";
import { operationalIdle } from "@/lib/operational/action-state";

import { useActionState } from "react";
import { cancelCommercialBillingAction, issueCommercialBillingAction } from "@/app/actions/operational";
import type { OperationalCommercialBilling, OperationalSalesOrder, OperationalWorkOrder } from "@/lib/operational/read-model";

import { BillingReceivable, type BillingFinancialLink } from "@/app/components/billing-receivable";

const money = (value: number) => Number(value).toLocaleString("pt-BR", { style: "currency", currency: "BRL" });
type Source = { sourceType: "sales_order" | "work_order"; sourceId: string; label: string };

function Feedback({ state }: { state: { status: string; message?: string } }) {
  return state.status === "idle" ? null : <p className={state.status === "success" ? "master-success" : "master-error"}>{state.message}</p>;
}

function IssueForm({ tenantId, sources }: { tenantId: string; sources: Source[] }) {
  const [state, action, pending] = useActionState(issueCommercialBillingAction, operationalIdle);
  const { request, prepareRequest } = useOperationalRequest(state);
  return <form action={action} className="master-company-form master-v2-form" onSubmit={() => { prepareRequest(); }}>
    <input type="hidden" name="tenant_id" value={tenantId} /><input ref={request} type="hidden" name="request_id" />
    <label>Origem faturável<select name="source_key" onChange={(event) => {
      const [type, id] = event.currentTarget.value.split(":");
      const sourceType = event.currentTarget.form?.elements.namedItem("source_type") as HTMLInputElement | null;
      const sourceId = event.currentTarget.form?.elements.namedItem("source_id") as HTMLInputElement | null;
      if (sourceType && sourceId) { sourceType.value = type ?? ""; sourceId.value = id ?? ""; }
    }} defaultValue={sources[0] ? `${sources[0].sourceType}:${sources[0].sourceId}` : ""}>{sources.map((source) => <option key={`${source.sourceType}-${source.sourceId}`} value={`${source.sourceType}:${source.sourceId}`}>{source.label}</option>)}</select></label>
    <input type="hidden" name="source_type" value={sources[0]?.sourceType ?? ""} /><input type="hidden" name="source_id" value={sources[0]?.sourceId ?? ""} />
    <button disabled={pending || !sources.length}>{pending ? "Emitindo…" : "Emitir faturamento comercial"}</button><Feedback state={state} />
  </form>;
}

function CancelForm({ tenantId, documentId }: { tenantId: string; documentId: string }) {
  const [state, action, pending] = useActionState(cancelCommercialBillingAction, operationalIdle);
  const { request, prepareRequest } = useOperationalRequest(state);
  return <details className="master-row-editor"><summary>Cancelar faturamento</summary><form action={action} className="master-v2-form" onSubmit={() => { prepareRequest(); }}>
    <input type="hidden" name="tenant_id" value={tenantId} /><input type="hidden" name="billing_document_id" value={documentId} /><input ref={request} type="hidden" name="request_id" />
    <p>Recebíveis vinculados serão cancelados junto ao faturamento somente depois do estorno explícito de todas as baixas. Dependências em caixa ou banco bloqueiam o cancelamento.</p><label>Justificativa<textarea name="reason" minLength={3} maxLength={1000} required /></label><button disabled={pending}>{pending ? "Cancelando…" : "Cancelar"}</button><Feedback state={state} />
  </form></details>;
}

export function CommercialBilling({ tenantId, enabled, billing, salesOrders, workOrders, allowIssue, allowRead, allowCancel, allowLink = false, financialLinks = [] }: { tenantId: string; enabled: boolean; billing: OperationalCommercialBilling[]; salesOrders: OperationalSalesOrder[]; workOrders: OperationalWorkOrder[]; allowIssue: boolean; allowRead: boolean; allowCancel: boolean; allowLink?: boolean; financialLinks?: BillingFinancialLink[] }) {
  const billed = new Set(billing.map((document) => `${document.source_type}:${document.source_id}`));
  const sources: Source[] = [
    ...salesOrders.filter((order) => (order.status === "confirmed" || order.status === "fulfilled") && !billed.has(`sales_order:${order.sales_order_id}`)).map((order) => ({ sourceType: "sales_order" as const, sourceId: order.sales_order_id, label: `Venda #${order.sales_order_number} · ${order.customer_name} · ${money(order.total_amount)}` })),
    ...workOrders.filter((order) => order.status === "closed" && !billed.has(`work_order:${order.work_order_id}`)).map((order) => ({ sourceType: "work_order" as const, sourceId: order.work_order_id, label: `O.S. #${order.order_number} · ${order.customer_name} · ${money(order.total_amount)}` })),
  ];
  return <section className="master-data-panel"><header><div><h2>Faturamento comercial</h2><p>Registro interno, auditável e reversível por cancelamento. A integração de recebíveis é explícita e auditada. Não emite documento fiscal nem movimenta caixa automaticamente.</p></div></header>
    {enabled && allowIssue ? <IssueForm tenantId={tenantId} sources={sources} /> : <p className="master-notice">Emissão exige ZFB01 aprovada, disponibilizada pela empresa e concedida no escopo da filial.</p>}
    {allowRead ? (billing.length ? <table className="master-table"><thead><tr><th>Documento</th><th>Origem</th><th>Cliente</th><th>Situação</th><th>Valor</th><th>Ações</th></tr></thead><tbody>{billing.map((document) => <tr key={document.billing_document_id}><td>#{document.billing_number}</td><td>{document.source_type === "sales_order" ? `Venda #${document.source_number}` : `O.S. #${document.source_number}`}</td><td>{document.customer_name}</td><td>{document.status === "issued" ? "Emitido" : "Cancelado"}</td><td>{money(document.total_amount)}</td><td><BillingReceivable tenantId={tenantId} billingId={document.billing_document_id} total={document.total_amount} link={financialLinks.find(link => link.billing_document_id === document.billing_document_id)} allowLink={enabled && allowLink && document.status === "issued"} />{allowCancel && document.status === "issued" ? <CancelForm tenantId={tenantId} documentId={document.billing_document_id} /> : "—"}</td></tr>)}</tbody></table> : <p className="master-notice">Nenhum faturamento comercial visível para a filial selecionada.</p>) : <p className="master-notice">A consulta exige ZFB02. A URL não substitui a autorização empresarial.</p>}
  </section>;
}
