"use client";

import { useOperationalRequest } from "@/lib/operational/use-operational-request";
import { operationalIdle } from "@/lib/operational/action-state";

import { useActionState, useMemo, useState } from "react";
import { createFinancialObligationAction, reverseFinancialSettlementAction, settleFinancialInstallmentAction } from "@/app/actions/operational";
import type { OperationalFinancialObligation, OperationalParty } from "@/lib/operational/read-model";

type InstallmentInput = { due_date: string; amount: string };
const money = (value: number) => new Intl.NumberFormat("pt-BR", { style: "currency", currency: "BRL" }).format(Number(value));

function Feedback({ state }: { state: { status: string; message?: string } }) { return state.message ? <p className={`master-company-feedback ${state.status === "success" ? "is-success" : "is-error"}`} role={state.status === "success" ? "status" : "alert"}>{state.message}</p> : null; }

function ObligationForm({ tenantId, branchId, type, parties }: { tenantId: string; branchId: string; type: "payable" | "receivable"; parties: OperationalParty[] }) {
  const [state, action, pending] = useActionState(createFinancialObligationAction, operationalIdle); const { request, prepareRequest } = useOperationalRequest(state);
  const [installments, setInstallments] = useState<InstallmentInput[]>([{ due_date: "", amount: "" }]);
  const payload = useMemo(() => JSON.stringify(installments.map((row) => ({ due_date: row.due_date, amount: Number(row.amount) }))), [installments]);
  const update = (index: number, key: keyof InstallmentInput, value: string) => setInstallments((rows) => rows.map((row, current) => current === index ? { ...row, [key]: value } : row));
  return <form action={action} className="master-company-form master-v2-form" onSubmit={() => { prepareRequest(); }}>
    <input type="hidden" name="tenant_id" value={tenantId} /><input type="hidden" name="branch_id" value={branchId} /><input type="hidden" name="obligation_type" value={type} /><input ref={request} type="hidden" name="request_id" /><input type="hidden" name="installments" value={payload} />
    <label>{type === "payable" ? "Fornecedor (opcional)" : "Cliente (opcional)"}<select name="counterparty_id"><option value="">Não vinculado</option>{parties.map((party) => <option key={party.party_id} value={party.party_id}>{party.legal_name}</option>)}</select></label>
    <label>Descrição<input name="description" maxLength={1000} required /></label><label>Data de emissão<input name="issue_date" type="date" required /></label>
    <fieldset className="master-line-editor"><legend>Parcelas</legend>{installments.map((row, index) => <div className="purchase-line" key={index}><input aria-label={`Vencimento ${index + 1}`} type="date" value={row.due_date} onChange={(event) => update(index, "due_date", event.target.value)} required /><input aria-label={`Valor da parcela ${index + 1}`} inputMode="decimal" placeholder="Valor" value={row.amount} onChange={(event) => update(index, "amount", event.target.value)} required />{installments.length > 1 && <button type="button" onClick={() => setInstallments((rows) => rows.filter((_, current) => current !== index))}>Remover</button>}</div>)}<button type="button" onClick={() => setInstallments((rows) => [...rows, { due_date: "", amount: "" }])}>Adicionar parcela</button></fieldset>
    <button className="master-action" disabled={pending}>{pending ? "Registrando…" : type === "payable" ? "Registrar conta a pagar" : "Registrar conta a receber"}</button><Feedback state={state} />
  </form>;
}

function SettleInstallment({ tenantId, installmentId, openAmount }: { tenantId: string; installmentId: string; openAmount: number }) {
  const [state, action, pending] = useActionState(settleFinancialInstallmentAction, operationalIdle); const { request, prepareRequest } = useOperationalRequest(state);
  return <form action={action} className="master-v2-form" onSubmit={() => { prepareRequest(); }}><input type="hidden" name="tenant_id" value={tenantId} /><input type="hidden" name="installment_id" value={installmentId} /><input ref={request} type="hidden" name="request_id" /><label>Valor<input name="amount" inputMode="decimal" defaultValue={openAmount} required /></label><label>Data<input name="settled_on" type="date" required /></label><label>Método<input name="method" maxLength={80} placeholder="Ex.: transferência" required /></label><label>Referência<input name="reference" maxLength={300} /></label><button disabled={pending}>{pending ? "Registrando…" : "Registrar baixa"}</button><Feedback state={state} /></form>;
}

function ReverseSettlement({ tenantId, settlementId }: { tenantId: string; settlementId: string }) {
  const [state, action, pending] = useActionState(reverseFinancialSettlementAction, operationalIdle); const { request, prepareRequest } = useOperationalRequest(state);
  return <form action={action} className="master-v2-form" onSubmit={(event) => { if (!window.confirm("Confirmar estorno da baixa? A baixa original será preservada e o saldo será restaurado.")) event.preventDefault(); else prepareRequest(); }}><input type="hidden" name="tenant_id" value={tenantId} /><input type="hidden" name="settlement_id" value={settlementId} /><input ref={request} type="hidden" name="request_id" /><label>Justificativa<textarea name="reason" minLength={3} maxLength={1000} required /></label><button disabled={pending}>{pending ? "Estornando…" : "Estornar baixa"}</button><Feedback state={state} /></form>;
}

/** Settlement reversal requires its immutable settlement id; it is deliberately available only from the audit detail API, not inferred from an installment. */
function ObligationRows({ tenantId, rows, allowSettle }: { tenantId: string; rows: OperationalFinancialObligation[]; allowSettle: boolean }) {
  if (!rows.length) return <p className="master-panel-empty">Nenhuma conta visível para esta filial.</p>;
  return <div className="master-table-wrap"><table className="master-table"><thead><tr><th>Conta</th><th>Tipo</th><th>Total</th><th>Baixado</th><th>Em aberto</th><th>Situação</th><th>Parcelas</th></tr></thead><tbody>{rows.map((row) => <tr key={row.obligation_id}><td><strong>{row.description}</strong><small>{new Date(row.created_at).toLocaleString("pt-BR")}</small></td><td>{row.obligation_type === "payable" ? "A pagar" : "A receber"}</td><td>{money(row.gross_amount)}</td><td>{money(row.settled_amount)}</td><td>{money(row.open_amount)}</td><td>{row.status}</td><td><details><summary>{row.installments.length} parcela(s)</summary>{row.installments.map((installment) => <div className="master-row-editor" key={installment.installment_id}><strong>#{installment.number} · {money(installment.open_amount)}</strong><small>Vencimento: {new Date(`${installment.due_date}T00:00:00`).toLocaleDateString("pt-BR")} · {installment.status}</small>{allowSettle && row.status !== "cancelled" && installment.status !== "cancelled" && installment.open_amount > 0 ? <SettleInstallment tenantId={tenantId} installmentId={installment.installment_id} openAmount={installment.open_amount} /> : null}{allowSettle && installment.settlements.map((settlement) => <div key={settlement.settlement_id}><small>Baixa {money(settlement.amount)} · {settlement.method}{settlement.reversed ? " · estornada" : ""}</small>{!settlement.reversed ? <ReverseSettlement tenantId={tenantId} settlementId={settlement.settlement_id} /> : null}</div>)}</div>)}</details></td></tr>)}</tbody></table></div>;
}

export function FinancialObligations({ tenantId, branchId, enabled, parties, rows, allowPayable, allowReceivable, allowRead, allowSettle }: { tenantId: string; branchId: string; enabled: boolean; parties: OperationalParty[]; rows: OperationalFinancialObligation[]; allowPayable: boolean; allowReceivable: boolean; allowRead: boolean; allowSettle: boolean }) {
  return <section className="master-data-panel"><header><div><h2>Contas a pagar e receber</h2><p>Parcelas e baixas são fatos empresariais auditáveis. Esta fundação não movimenta caixa, bancos, fiscal ou contabilidade.</p></div></header>{enabled && (allowPayable || allowReceivable) ? <div className="master-split-grid">{allowPayable ? <ObligationForm tenantId={tenantId} branchId={branchId} type="payable" parties={parties.filter((party) => party.party_type !== "customer")} /> : null}{allowReceivable ? <ObligationForm tenantId={tenantId} branchId={branchId} type="receivable" parties={parties.filter((party) => party.party_type !== "supplier")} /> : null}</div> : <p className="master-notice">A criação permanece bloqueada até aprovação, disponibilidade empresarial e grant scoped de ZFI01/ZFI02.</p>}{allowRead ? <ObligationRows tenantId={tenantId} rows={rows} allowSettle={enabled && allowSettle} /> : <p className="master-notice">A consulta exige ZFI04 aprovado, disponível e concedido no escopo da filial.</p>}</section>;
}
