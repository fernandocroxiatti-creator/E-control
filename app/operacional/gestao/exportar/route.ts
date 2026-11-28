import { exportPdf, exportXlsx } from "@/lib/reports/export";
import type { ReportDocument, ReportRow } from "@/lib/reports/definition";
import { operationalReportContext, type ManagementData } from "@/lib/erp-completion/read-model";
import { reportPeriod, csv } from "@/lib/erp-completion/input";
export async function GET(request: Request) {
  const params = new URL(request.url).searchParams; const format = params.get("format") ?? "csv";
  if (!["csv", "xlsx", "pdf"].includes(format)) return new Response("Formato inválido", { status: 400 }); const branch = params.get("filial");
  const period = reportPeriod(params.get("from") ?? undefined, params.get("to") ?? undefined);
  if (!period || !branch) return new Response("Parâmetros inválidos", { status: 400 });
  const context = await operationalReportContext(branch);
  if (!context?.enabled || !context.selected) return new Response("Acesso negado", { status: 403 });
  const { data, error } = await context.client.rpc("operational_get_management_report", { p_tenant_id: context.selected.tenantId, p_branch_id: context.selected.branchId, p_from: period.from, p_to: period.to, p_export: true });
  if (error || !data) return new Response("Relatório indisponível ou não autorizado", { status: 403 });
  const report = data as ManagementData;
  const rows: unknown[][] = [["Empresa", context.selected.companyName], ["Filial", context.selected.branchCode], ["Período", period.from, period.to], ["DRE gerencial: obrigações classificadas; não substitui escrituração contábil"], ["Sem classificação", report.unclassified], ["A receber em aberto (atual)", report.receivable_open], ["A pagar em aberto (atual)", report.payable_open], ["Categoria", "Valor"], ...report.dre.map(r => [r.category, r.amount]), ["Fluxo financeiro: baixas válidas e parcelas abertas; sem somar caixa/banco"], ["Data", "Recebido", "Pago", "Previsto receber", "Previsto pagar"], ...report.cash_flow.map(r => [r.day, r.receipts, r.payments, r.expected_in, r.expected_out])];
  if (format !== "csv") {
    const records: ReportRow[] = [];
    const append = (group: string, description: string, amount: number, date = "") => records.push({ id: String(records.length), date, reference: group, description, status: "", quantity: null, amount: String(amount), balance: null });
    append("Posição atual", "A receber em aberto", report.receivable_open); append("Posição atual", "A pagar em aberto", report.payable_open);
    report.dre.forEach(r => append("DRE", r.category, r.amount));
    report.cash_flow.forEach(r => { append("Realizado", "Recebimentos", r.receipts, r.day); append("Realizado", "Pagamentos", r.payments, r.day); append("Previsto", "Recebimentos", r.expected_in, r.day); append("Previsto", "Pagamentos", r.expected_out, r.day); });
    const document: ReportDocument = { title: "DRE e fluxo financeiro", company: context.selected.companyName, branch: context.selected.branchCode, period: `${period.from} a ${period.to}`, filters: "Todas as categorias", note: `DRE gerencial; ${report.unclassified} obrigações sem classificação no período. Fluxo realizado líquido de estornos; não soma caixa/bancos. Saldos atuais.`, generatedAt: new Date().toISOString(), total: records.length, rows: records, columns: [{ key: "date", label: "Data", type: "text", width: 15 }, { key: "reference", label: "Grupo", type: "text", width: 23 }, { key: "description", label: "Descrição", type: "text", width: 45 }, { key: "amount", label: "Valor (BRL)", type: "money", width: 23 }] };
    try {
      const bytes = format === "xlsx" ? await exportXlsx(document) : await exportPdf(document);
      return new Response(new Uint8Array(bytes), { headers: { "Content-Type": format === "xlsx" ? "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet" : "application/pdf", "Content-Disposition": `attachment; filename="gestao.${format}"`, "Cache-Control": "private, no-store", "X-Content-Type-Options": "nosniff" } });
    } catch { return new Response("Não foi possível gerar o relatório.", { status: 500 }); }
  }
  return new Response(csv(rows), { headers: { "Content-Type": "text/csv; charset=utf-8", "Content-Disposition": 'attachment; filename="gestao.csv"', "Cache-Control": "private, no-store", "X-Content-Type-Options": "nosniff" } });
}
