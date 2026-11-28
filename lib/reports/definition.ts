export const reportKinds = {
  purchases: { title: "Compras", code: "ZRP01", note: "Pedidos por data de criação. Valores incluem as situações selecionadas.", statuses: ["draft", "submitted", "partially_received", "received", "cancelled"] },
  sales: { title: "Vendas", code: "ZRP02", note: "Pedidos por data de criação. Faturamento e recebimento são eventos separados.", statuses: ["draft", "confirmed", "fulfilled", "cancelled"] },
  inventory: { title: "Movimentações de estoque", code: "ZRP03", note: "Movimentos persistidos no período. Saldo corresponde à posição após cada movimento; não some saldos.", statuses: ["initial", "entry", "exit", "adjustment_positive", "adjustment_negative", "transfer_in", "transfer_out", "physical_count_in", "physical_count_out", "service_consumption", "service_reversal"] },
  finance: { title: "Contas a pagar e receber", code: "ZRP04", note: "Obrigações por data de emissão. Saldo em aberto reflete a posição atual; valores cancelados continuam identificados.", statuses: ["open", "partially_settled", "settled", "cancelled"] },
  banks: { title: "Movimentos bancários", code: "ZRP05", note: "Entradas positivas e saídas negativas por data do movimento, incluindo transferências internas.", statuses: ["pending", "reconciled"] },
  work_orders: { title: "Ordens de serviço", code: "ZRP06", note: "Ordens por data de criação, com total e situação persistidos.", statuses: ["open", "in_progress", "closed", "cancelled", "reversed"] },
} as const;
export type ReportKind = keyof typeof reportKinds;
export type ReportRow = { id: string; date: string; reference: string; description: string; status: string; quantity: string | null; amount: string | null; balance: string | null };
export type ReportData = { total_count: number; amount_total: string | null; rows: ReportRow[] };
export type ReportDocument = { title: string; company: string; branch: string; period: string; filters: string; note: string; generatedAt: string; columns: { key: keyof ReportRow; label: string; type: "text" | "date" | "number" | "money"; width: number }[]; rows: ReportRow[]; total: number };
export function isReportKind(value: string): value is ReportKind { return Object.hasOwn(reportKinds, value); }
export const statusLabels: Record<string, string> = { draft: "Rascunho", submitted: "Enviado", partially_received: "Recebido parcialmente", received: "Recebido", cancelled: "Cancelado", confirmed: "Confirmado", fulfilled: "Entregue", open: "Em aberto", partially_settled: "Baixa parcial", settled: "Liquidado", pending: "Pendente", reconciled: "Conciliado", in_progress: "Em andamento", closed: "Encerrado", reversed: "Estornado", initial: "Saldo inicial", entry: "Entrada", exit: "Saída", adjustment_positive: "Ajuste positivo", adjustment_negative: "Ajuste negativo", transfer_in: "Transferência entrada", transfer_out: "Transferência saída", physical_count_in: "Inventário entrada", physical_count_out: "Inventário saída", service_consumption: "Consumo em OS", service_reversal: "Estorno em OS" };
export function columnsFor(kind: ReportKind): ReportDocument["columns"] {
  const columns: ReportDocument["columns"] = [
    { key: "date", label: "Data", type: "date", width: 12 }, { key: "reference", label: kind === "banks" ? "Conta" : kind === "inventory" ? "Produto" : "Referência", type: "text", width: 18 },
    { key: "description", label: ["finance", "banks"].includes(kind) ? "Descrição" : kind === "inventory" ? "Produto" : "Parceiro", type: "text", width: 42 },
    { key: "status", label: "Situação", type: "text", width: 23 },
  ];
  if (kind === "inventory") columns.push({ key: "quantity", label: "Quantidade", type: "number", width: 15 });
  columns.push({ key: "amount", label: "Valor (BRL)", type: "money", width: 20 });
  if (kind === "inventory" || kind === "finance") columns.push({ key: "balance", label: kind === "inventory" ? "Saldo após" : "Em aberto (BRL)", type: kind === "inventory" ? "number" : "money", width: 20 });
  return columns;
}
export function displayCell(value: string | null, type: string) {
  if (value === null) return "—";
  if (type === "date" && /^\d{4}-\d{2}-\d{2}$/.test(value)) return value.split("-").reverse().join("/");
  if (type === "number" || type === "money") {
    const [integer, decimals = ""] = value.split(".");
    const grouped = integer.replace(/\B(?=(\d{3})+(?!\d))/g, ".");
    const fraction = decimals.replace(/0+$/, "").padEnd(type === "money" ? 2 : 0, "0");
    return `${type === "money" ? "R$ " : ""}${grouped}${fraction ? `,${fraction}` : ""}`;
  }
  return value;
}
