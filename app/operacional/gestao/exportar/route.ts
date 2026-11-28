import { operationalReportContext, type ManagementData } from "@/lib/erp-completion/read-model";
import { reportPeriod, csv } from "@/lib/erp-completion/input";
export async function GET(request: Request) {
  const params = new URL(request.url).searchParams; const branch = params.get("filial");
  const period = reportPeriod(params.get("from") ?? undefined, params.get("to") ?? undefined);
  if (!period || !branch) return new Response("Parâmetros inválidos", { status: 400 });
  const context = await operationalReportContext(branch);
  if (!context?.enabled || !context.selected) return new Response("Acesso negado", { status: 403 });
  const { data, error } = await context.client.rpc("operational_get_management_report", { p_tenant_id: context.selected.tenantId, p_branch_id: context.selected.branchId, p_from: period.from, p_to: period.to, p_export: true });
  if (error || !data) return new Response("Relatório indisponível ou não autorizado", { status: 403 });
  const report = data as ManagementData;
  const rows: unknown[][] = [["Empresa", context.selected.companyName], ["Filial", context.selected.branchCode], ["Período", period.from, period.to], ["DRE gerencial: obrigações classificadas; não substitui escrituração contábil"], ["Sem classificação", report.unclassified], ["A receber em aberto (atual)", report.receivable_open], ["A pagar em aberto (atual)", report.payable_open], ["Categoria", "Valor"], ...report.dre.map(r => [r.category, r.amount]), ["Fluxo financeiro: baixas válidas e parcelas abertas; sem somar caixa/banco"], ["Data", "Recebido", "Pago", "Previsto receber", "Previsto pagar"], ...report.cash_flow.map(r => [r.day, r.receipts, r.payments, r.expected_in, r.expected_out])];
  return new Response(csv(rows), { headers: { "Content-Type": "text/csv; charset=utf-8", "Content-Disposition": 'attachment; filename="gestao.csv"', "Cache-Control": "private, no-store", "X-Content-Type-Options": "nosniff" } });
}
