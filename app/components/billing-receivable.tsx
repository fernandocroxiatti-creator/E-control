"use client";
import { useActionState, useRef, useState } from "react";
import { integrateBillingReceivableAction, type BillingFinanceState } from "@/app/actions/billing-finance";
export type BillingFinancialLink = { billing_document_id: string; obligation_id: string; link_mode: string; payment_terms: string; status: string; gross_amount: number; settled_amount: number; installments: { due_date: string; amount: number; settled_amount: number }[] };
export function BillingReceivable({ tenantId, billingId, total, link, allowLink }: { tenantId: string; billingId: string; total: number; link?: BillingFinancialLink; allowLink: boolean }) {
  const [state, action, pending] = useActionState(integrateBillingReceivableAction, { status: "idle" } as BillingFinanceState);
  const [mode, setMode] = useState("generate"); const [count, setCount] = useState(1); const request = useRef<HTMLInputElement>(null);
  if (link) return <details><summary>Recebível vinculado · {link.status}</summary><p>ID: {link.obligation_id}</p><p>{link.payment_terms}</p><p>Recebido: {Number(link.settled_amount).toLocaleString("pt-BR", { style: "currency", currency: "BRL" })}</p><ul>{link.installments.map((p, i) => <li key={i}>{p.due_date} · {Number(p.amount).toLocaleString("pt-BR", { style: "currency", currency: "BRL" })}</li>)}</ul></details>;
  if (!allowLink) return null;
  return <details className="master-row-editor"><summary>Integrar contas a receber</summary><form action={action} className="master-v2-form" onSubmit={() => { if (request.current && !request.current.value) request.current.value = crypto.randomUUID(); }}>
    <input type="hidden" name="tenant_id" value={tenantId} /><input type="hidden" name="billing_document_id" value={billingId} /><input ref={request} type="hidden" name="request_id" />
    <p>Confira antes se já existe recebível para este faturamento. Total: {Number(total).toLocaleString("pt-BR", { style: "currency", currency: "BRL" })}.</p>
    <label>Operação<select name="mode" value={mode} onChange={e => setMode(e.target.value)}><option value="generate">Gerar recebível com parcelas</option><option value="existing">Vincular obrigação já existente</option></select></label>
    <label>Data de emissão / competência<input type="date" name="issue_date" required /></label>
    <label>Condição de pagamento<input name="payment_terms" minLength={3} maxLength={500} placeholder="Ex.: entrada + 30/60 dias" required /></label>
    {mode === "existing" ? <><label>ID do recebível existente<input name="existing_obligation_id" required /></label><p>Os vencimentos, baixas e a classificação existentes serão preservados. Informe a data de emissão original.</p></> : <>
      <label>Número de parcelas<input type="number" min={1} max={120} value={count} onChange={e => setCount(Math.min(120, Math.max(1, Number(e.target.value) || 1)))} /></label>
      {Array.from({ length: count }, (_, i) => <fieldset key={i}><legend>Parcela {i + 1}</legend><label>Vencimento<input type="date" name="due_date" required /></label><label>Valor<input name="amount" inputMode="decimal" required /></label></fieldset>)}
      <p>Os valores devem totalizar o faturamento. A geração classifica a receita na DRE pela competência informada.</p>
    </>}
    <button className="master-action" disabled={pending || state.status === "success"}>{pending ? "Integrando…" : "Confirmar integração"}</button>
    {state.message ? <p role="status" className="master-notice">{state.message}{state.obligationId ? ` ID: ${state.obligationId}` : ""}</p> : null}
  </form></details>;
}
