import Link from "next/link";
import { CompletionForm } from "@/app/components/completion-form";
import { operationalReportContext, formatMoney, type ManagementData } from "@/lib/erp-completion/read-model";
import { reportPeriod } from "@/lib/erp-completion/input";
import { authorizeRouteTransaction } from "@/lib/operational/transaction-focus";
export const dynamic = "force-dynamic";
const labels: Record<string, string> = { revenue: "Receita bruta", deduction: "Deduções", cost: "Custos", expense: "Despesas operacionais", financial_income: "Receitas financeiras", financial_expense: "Despesas financeiras", excluded: "Fora do resultado" };
export default async function ManagementPage({ searchParams }: { searchParams: Promise<{ filial?: string; from?: string; to?: string }> }) {
  const search = await searchParams; const context = await operationalReportContext(search.filial); const period = reportPeriod(search.from, search.to);
  if (!context) return <p>Sessão indisponível.</p>;
  const { client, access, selected, enabled } = context;
  const result = selected && period && enabled ? await client.rpc("operational_get_management_report", { p_tenant_id: selected.tenantId, p_branch_id: selected.branchId, p_from: period.from, p_to: period.to }) : null;
  const data = result && !result.error ? result.data as ManagementData : null;
  const grants = selected && enabled ? await Promise.all((["ZGE02", "ZFI01", "ZFI02"] as const).map(tx => authorizeRouteTransaction(client, tx, selected.tenantId, selected.branchId))) : [];
  const net = data?.dre.reduce((sum, row) => sum + (row.category === "excluded" ? 0 : ["revenue", "financial_income"].includes(row.category) ? Number(row.amount) : -Number(row.amount)), 0) ?? 0;
  return <><h1>Dashboard executivo</h1><form className="master-filter-form"><label>Filial<select name="filial" defaultValue={selected?.branchId}>{access.contexts.map(c => <option key={c.branchId} value={c.branchId}>{c.companyName} · {c.branchName}</option>)}</select></label><label>De<input type="date" name="from" defaultValue={period?.from} required /></label><label>Até<input type="date" name="to" defaultValue={period?.to} required /></label><button>Consultar</button></form>
    {!period ? <p role="alert">Período inválido; limite de 367 dias.</p> : null}
    {data ? <><div className="master-split-grid"><section className="master-data-panel"><h2>A receber em aberto</h2><p>{formatMoney(data.receivable_open)}</p></section><section className="master-data-panel"><h2>A pagar em aberto</h2><p>{formatMoney(data.payable_open)}</p></section></div>
      <h2>DRE gerencial por competência</h2><p>Base: obrigações classificadas, pela data de competência informada. Não substitui a escrituração contábil. Obrigações canceladas são excluídas.</p><p role="status">Obrigações sem classificação emitidas no período: {data.unclassified}. {data.unclassified > 0 ? "Resultado parcial: classifique as pendências." : ""}</p>
      <table className="master-table"><thead><tr><th>Grupo</th><th>Valor</th></tr></thead><tbody>{data.dre.map(r => <tr key={r.category}><td>{labels[r.category]}</td><td>{formatMoney(r.amount)}</td></tr>)}<tr><th>Resultado classificado</th><td>{formatMoney(net)}</td></tr></tbody></table>
      <h2>Fluxo de caixa financeiro</h2><p>Realizado: baixas válidas, excluídos estornos. Previsto: saldo aberto por vencimento. O fluxo não soma novamente movimentos de caixa e banco nem transferências internas. Saldos em aberto refletem a situação atual.</p>
      <div className="master-table-wrap"><table className="master-table"><thead><tr><th>Data</th><th>Recebido</th><th>Pago</th><th>Saldo realizado</th><th>Previsto receber</th><th>Previsto pagar</th></tr></thead><tbody>{data.cash_flow.map(r => <tr key={r.day}><td>{r.day}</td><td>{formatMoney(r.receipts)}</td><td>{formatMoney(r.payments)}</td><td>{formatMoney(r.receipts - r.payments)}</td><td>{formatMoney(r.expected_in)}</td><td>{formatMoney(r.expected_out)}</td></tr>)}</tbody></table></div>
      {grants[0]?.status === "authorized" ? <a href={`/operacional/gestao/exportar?${new URLSearchParams({ filial: selected!.branchId, from: period!.from, to: period!.to })}`}>Exportar relatório CSV</a> : null}
    </> : <p className="master-notice">Relatórios indisponíveis. A consulta exige ZGE01 aprovado, disponível e concedido para esta filial.</p>}
    {selected && enabled && grants.slice(1).some(g => g?.status === "authorized") ? <CompletionForm key={selected.branchId} command="classify" tenantId={selected.tenantId} /> : null}<p><Link href="/operacional/financeiro">Consultar obrigações financeiras</Link> · <Link href="/operacional/bancos">Contas bancárias</Link></p></>;
}
