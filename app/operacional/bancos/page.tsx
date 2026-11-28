import Link from "next/link";
import { CompletionForm } from "@/app/components/completion-form";
import { operationalReportContext, formatMoney, type BankData } from "@/lib/erp-completion/read-model";
import { reportPeriod } from "@/lib/erp-completion/input";
import { authorizeRouteTransaction } from "@/lib/operational/transaction-focus";
export const dynamic = "force-dynamic";
export default async function BankPage({ searchParams }: { searchParams: Promise<{ filial?: string; from?: string; to?: string; page?: string }> }) {
  const search = await searchParams; const context = await operationalReportContext(search.filial); const period = reportPeriod(search.from, search.to);
  if (!context) return <p className="master-notice">Sessão indisponível.</p>;
  const { client, access, selected, enabled } = context;
  const grants = selected && enabled ? await Promise.all((["ZTR02", "ZTR03", "ZTR04", "ZTR05"] as const).map(tx => authorizeRouteTransaction(client, tx, selected.tenantId, selected.branchId))) : [];
  const allowed = (i: number) => grants[i]?.status === "authorized";
  const page = /^\d{1,6}$/.test(search.page ?? "") ? Math.max(1, Number(search.page)) : 1;
  const result = selected && period && enabled && allowed(3) ? await client.rpc("operational_get_bank_treasury", { p_tenant_id: selected.tenantId, p_branch_id: selected.branchId, p_from: period.from, p_to: period.to, p_offset: (page - 1) * 100 }) : null;
  const data = result && !result.error ? result.data as BankData : null;
  const accountOptions = data?.accounts.filter(a => a.status === "active").map(a => ({ id: a.id, name: `${a.code} · ${a.name}` })) ?? [];
  const movements = data?.movements.slice(0, 100) ?? [];
  return <><h1>Contas bancárias, transferências e conciliação</h1><p>Movimentos em BRL, isolados por empresa e filial. Transferências internas não geram receita nem liquidam obrigações.</p>
    <form className="master-filter-form"><label>Filial<select name="filial" defaultValue={selected?.branchId}>{access.contexts.map(c => <option key={c.branchId} value={c.branchId}>{c.companyName} · {c.branchName}</option>)}</select></label><label>De<input type="date" name="from" defaultValue={period?.from} required /></label><label>Até<input type="date" name="to" defaultValue={period?.to} required /></label><button>Consultar</button></form>
    {!period ? <p role="alert">Período inválido. Informe até 367 dias.</p> : null}
    {!enabled || !selected ? <p className="master-notice">Operação bloqueada até ativação e autorização empresarial.</p> : <>
      {allowed(0) ? <CompletionForm key={`a${selected.branchId}`} command="account" tenantId={selected.tenantId} branchId={selected.branchId} /> : null}
      {allowed(1) && data ? <div className="master-split-grid"><CompletionForm key={`t${selected.branchId}`} command="transfer" tenantId={selected.tenantId} options={{ from: accountOptions, to: accountOptions }} /><CompletionForm key={`m${selected.branchId}`} command="movement" tenantId={selected.tenantId} options={{ account_id: accountOptions }} /></div> : null}
      {data ? <><h2>Saldos até {period?.to}</h2><div className="master-table-wrap"><table className="master-table"><thead><tr><th>Conta</th><th>Tipo</th><th>Saldo</th></tr></thead><tbody>{data.accounts.map(a => <tr key={a.id}><td>{a.code} · {a.name}</td><td>{a.account_kind}</td><td>{formatMoney(a.balance)}</td></tr>)}</tbody></table></div>
        {allowed(0) ? <CompletionForm key={`u${selected.branchId}`} command="updateAccount" tenantId={selected.tenantId} options={{ account_id: data.accounts.map(a => ({ id: a.id, name: `${a.code} · ${a.name} (${a.status})` })) }} /> : null}
        <h2>Movimentos</h2><div className="master-table-wrap"><table className="master-table"><thead><tr><th>Data</th><th>Conta</th><th>Descrição</th><th>Valor</th><th>Conciliação</th></tr></thead><tbody>{movements.map(m => <tr key={m.id}><td>{m.occurred_on}</td><td>{data.accounts.find(a => a.id === m.bank_account_id)?.code}</td><td>{m.description}</td><td>{formatMoney(m.direction === "in" ? m.amount : -m.amount)}</td><td>{m.reconciled_at ? m.statement_reference : "Pendente"}</td></tr>)}</tbody></table></div>
        {allowed(2) ? <CompletionForm key={`r${selected.branchId}`} command="reconcile" tenantId={selected.tenantId} options={{ movement_id: movements.filter(m => !m.reconciled_at).map(m => ({ id: m.id, name: `${m.occurred_on} · ${m.description} · ${formatMoney(m.direction === "in" ? m.amount : -m.amount)}` })) }} /> : null}
        {allowed(2) ? <CompletionForm key={`ur${selected.branchId}`} command="unreconcile" tenantId={selected.tenantId} options={{ movement_id: movements.filter(m => m.reconciled_at).map(m => ({ id: m.id, name: `${m.occurred_on} · ${m.description} · ${m.statement_reference}` })) }} /> : null}
        {page > 1 ? <Link href={`?${new URLSearchParams({ filial: selected.branchId, from: period!.from, to: period!.to, page: String(page - 1) })}`}>Anterior</Link> : null}{data.movements.length > 100 ? <Link href={`?${new URLSearchParams({ filial: selected.branchId, from: period!.from, to: period!.to, page: String(page + 1) })}`}>Próxima</Link> : null}
      </> : <p className="master-notice">Consulta indisponível. Verifique implantação e autorização ZTR05; saldos não foram carregados.</p>}
    </>}<Link href="/operacional/gestao">Fluxo de caixa e gestão</Link></>;
}
