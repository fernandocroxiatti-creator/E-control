import "server-only";
import { operationalReportContext } from "@/lib/erp-completion/read-model";
import { reportPeriod } from "@/lib/erp-completion/input";
import { columnsFor, isReportKind, reportKinds, statusLabels, type ReportData, type ReportDocument } from "./definition";
export async function loadReport(params: URLSearchParams, exporting = false) {
  const kind = params.get("kind") ?? "purchases"; const period = reportPeriod(params.get("from") ?? undefined, params.get("to") ?? undefined);
  const status = params.get("status") ?? ""; const search = (params.get("q") ?? "").trim();
  const pageText = params.get("page") ?? "1";
  if (!isReportKind(kind) || !period || search.length > 120 || status.length > 32 || !/^\d{1,5}$/.test(pageText) || Number(pageText) < 1 || (status && !(reportKinds[kind].statuses as readonly string[]).includes(status))) return { error: "Filtros inválidos. Revise o período (até 367 dias) e a situação.", status: 400 } as const;
  const context = await operationalReportContext(params.get("filial") ?? undefined);
  if (!context?.enabled || !context.selected) return { error: "Selecione uma empresa e filial autorizadas. O acesso operacional precisa estar habilitado.", status: 403, context } as const;
  const { selected, client } = context; const page = Number(pageText);
  const result = await client.rpc("operational_get_report", { p_tenant_id: selected.tenantId, p_branch_id: selected.branchId, p_kind: kind, p_from: period.from, p_to: period.to, p_status: status || null, p_search: search || null, p_limit: exporting ? 5000 : 100, p_offset: exporting ? 0 : (page - 1) * 100, p_export: exporting });
  if (result.error || !result.data) return { error: "Não foi possível consultar este relatório. Verifique a liberação da transação, o acesso à área e a situação comercial da empresa.", status: 403, context } as const;
  const data = result.data as ReportData;
  if (exporting && data.total_count > 5000) return { error: "O relatório excede 5.000 registros. Reduza o período ou refine a pesquisa para exportar todos os resultados.", status: 422, context } as const;
  const document: ReportDocument = { title: reportKinds[kind].title, company: selected.companyName, branch: `${selected.branchCode} - ${selected.branchName}`, period: `${period.from} a ${period.to}`, filters: `Situação: ${statusLabels[status] ?? (status || "Todas")} | Pesquisa: ${search || "Sem filtro"}`, note: reportKinds[kind].note, generatedAt: new Date().toISOString(), columns: columnsFor(kind), rows: data.rows.map(r => ({ ...r, status: statusLabels[r.status] ?? r.status })), total: data.total_count };
  return { document, data, context, kind, period, page, search, selectedStatus: status } as const;
}
