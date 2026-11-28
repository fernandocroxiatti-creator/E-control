import Link from "next/link";
import { loadReport } from "@/lib/reports/server";
import { reportKinds, statusLabels, displayCell, isReportKind } from "@/lib/reports/definition";
import { operationalReportContext } from "@/lib/erp-completion/read-model";
import { reportPeriod } from "@/lib/erp-completion/input";
import { PrintReport } from "@/app/components/print-report";
export const dynamic = "force-dynamic";
export default async function ReportsPage({ searchParams }: { searchParams: Promise<Record<string, string | string[] | undefined>> }) {
  const search = await searchParams; const params = new URLSearchParams(); Object.entries(search).forEach(([k, v]) => { if (typeof v === "string") params.set(k, v); });
  const printing = params.get("print") === "1";
  const result = await loadReport(params, printing); const context = result.context ?? await operationalReportContext(params.get("filial") ?? undefined);
  const kindValue = params.get("kind") ?? "purchases"; const kind = isReportKind(kindValue) ? kindValue : "purchases";
  const period = reportPeriod(params.get("from") ?? undefined, params.get("to") ?? undefined);
  const link = (extra: Record<string, string>) => { const query = new URLSearchParams(params); if (context?.selected) query.set("filial", context.selected.branchId); if (period) { query.set("from", period.from); query.set("to", period.to); } Object.entries(extra).forEach(([k, v]) => query.set(k, v)); return query.toString(); };
  return <section className="report-page"><div className="page-heading-row no-print"><div><p className="page-kicker">GESTÃO</p><h1>Central de relatórios</h1><p>Consulte os registros da filial e exporte o resultado completo dos filtros.</p></div><Link href="/operacional/gestao">Dashboard executivo</Link></div>
    <form className="master-filter-form no-print"><label>Área<select name="kind" defaultValue={kind}>{Object.entries(reportKinds).map(([k, v]) => <option key={k} value={k}>{v.title}</option>)}</select></label><label>Filial<select name="filial" defaultValue={context?.selected?.branchId ?? ""}>{context?.access.contexts.map(c => <option key={c.branchId} value={c.branchId}>{c.companyName} · {c.branchName}</option>)}</select></label><label>De<input name="from" type="date" defaultValue={period?.from} required /></label><label>Até<input name="to" type="date" defaultValue={period?.to} required /></label><label>Situação<select name="status" defaultValue={params.get("status") ?? ""}><option value="">Todas</option>{reportKinds[kind].statuses.map(s => <option key={s} value={s}>{statusLabels[s] ?? s}</option>)}</select></label><label>Pesquisa<input name="q" maxLength={120} defaultValue={params.get("q") ?? ""} /></label><button>Consultar</button></form>
    {"error" in result ? <p role="alert" className="master-notice">{result.error}</p> : <><header className="report-heading"><h2>{result.document.title}</h2><p>{result.document.company} · {result.document.branch}</p><p>{result.document.period} · {result.document.filters}</p><p>{result.document.note}</p><strong>{result.document.total} registros</strong></header>
      <nav className="report-actions no-print" aria-label="Exportar relatório">{["csv", "xlsx", "pdf"].map(format => <a key={format} href={`/operacional/relatorios/exportar?${link({ format })}`}>Baixar {format.toUpperCase()}</a>)}{printing ? <PrintReport /> : <Link href={`?${link({ print: "1", page: "1" })}`}>Versão para impressão</Link>}</nav>
      <div className="master-table-wrap" tabIndex={0} aria-label="Dados do relatório"><table className="master-table"><thead><tr>{result.document.columns.map(c => <th key={c.key}>{c.label}</th>)}</tr></thead><tbody>{result.document.rows.map(r => <tr key={r.id}>{result.document.columns.map(c => <td key={c.key}>{displayCell(r[c.key], c.type)}</td>)}</tr>)}{!result.document.rows.length ? <tr><td colSpan={result.document.columns.length}>Nenhum registro encontrado para os filtros selecionados.</td></tr> : null}</tbody></table></div>
      {!printing ? <nav className="master-pagination no-print" aria-label="Paginação do relatório"><span>Página {result.page}</span>{result.page > 1 ? <Link href={`?${link({ page: String(result.page - 1) })}`}>Anterior</Link> : null}{result.page * 100 < result.document.total ? <Link href={`?${link({ page: String(result.page + 1) })}`}>Próxima</Link> : null}</nav> : null}
    </>}</section>;
}
