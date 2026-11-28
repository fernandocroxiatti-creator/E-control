import { loadReport } from "@/lib/reports/server";
import { exportPdf, exportXlsx } from "@/lib/reports/export";
import { csv } from "@/lib/erp-completion/input";
export const runtime = "nodejs";
export const dynamic = "force-dynamic";
export async function GET(request: Request) {
  const params = new URL(request.url).searchParams; const format = params.get("format") ?? "csv";
  if (!["csv", "xlsx", "pdf"].includes(format)) return new Response("Formato inválido", { status: 400 });
  const result = await loadReport(params, true);
  if ("error" in result) return new Response(result.error, { status: result.status, headers: { "Cache-Control": "private, no-store" } });
  try {
    const { document } = result;
    const bytes = format === "xlsx" ? await exportXlsx(document) : format === "pdf" ? await exportPdf(document) : new TextEncoder().encode(csv([[document.title], [document.company, document.branch], [document.period, document.filters], [document.note], ["Registros", document.total], document.columns.map(c => c.label), ...document.rows.map(r => document.columns.map(c => r[c.key]))]));
    return new Response(new Uint8Array(bytes), { headers: { "Content-Type": format === "xlsx" ? "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet" : format === "pdf" ? "application/pdf" : "text/csv; charset=utf-8", "Content-Disposition": `attachment; filename="econtroll-${result.kind}.${format}"`, "Cache-Control": "private, no-store", "X-Content-Type-Options": "nosniff" } });
  } catch { return new Response("Não foi possível gerar o arquivo. Reduza o período e tente novamente.", { status: 500, headers: { "Cache-Control": "private, no-store" } }); }
}
