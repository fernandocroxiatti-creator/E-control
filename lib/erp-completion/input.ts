export type Field = { name: string; label: string; type: "uuid" | "text" | "decimal" | "date" | "integer" | "select"; options?: string[]; min?: number; max?: number; optional?: boolean };
export const commands = {
  updateAccount: { rpc: "operational_update_bank_account", label: "Atualizar conta bancária", fields: [
    { name: "account_id", label: "Conta", type: "uuid" }, { name: "name", label: "Nome", type: "text", min: 2, max: 160 }, { name: "status", label: "Situação", type: "select", options: ["active", "inactive"] }, { name: "reason", label: "Justificativa", type: "text", min: 10, max: 1000 }] },
  unreconcile: { rpc: "operational_unreconcile_bank_movement", label: "Desfazer conciliação", fields: [
    { name: "movement_id", label: "Movimento conciliado", type: "uuid" }, { name: "reference", label: "Referência atual do extrato", type: "text", min: 3, max: 160 }, { name: "reason", label: "Justificativa", type: "text", min: 10, max: 1000 }] },
  account: { rpc: "operational_create_bank_account", label: "Criar conta bancária", fields: [
    { name: "code", label: "Código", type: "text", min: 2, max: 32 }, { name: "name", label: "Nome", type: "text", min: 2, max: 160 }, { name: "kind", label: "Tipo", type: "select", options: ["checking", "savings", "wallet"] }, { name: "opening", label: "Saldo inicial (BRL)", type: "decimal" }], request: true, branch: true },
  transfer: { rpc: "operational_transfer_bank_funds", label: "Transferir entre contas", fields: [
    { name: "from", label: "Conta de origem", type: "uuid" }, { name: "to", label: "Conta de destino", type: "uuid" }, { name: "amount", label: "Valor (BRL)", type: "decimal", min: 0.00000001 }, { name: "occurred_on", label: "Data", type: "date" }, { name: "description", label: "Descrição", type: "text", min: 3, max: 1000 }], request: true },
  movement: { rpc: "operational_record_bank_movement", label: "Registrar movimento bancário", fields: [
    { name: "account_id", label: "Conta", type: "uuid" }, { name: "direction", label: "Direção", type: "select", options: ["in", "out"] }, { name: "amount", label: "Valor (BRL)", type: "decimal", min: 0.00000001 }, { name: "occurred_on", label: "Data", type: "date" }, { name: "description", label: "Descrição", type: "text", min: 3, max: 1000 }], request: true },
  reconcile: { rpc: "operational_reconcile_bank_movement", label: "Conciliar com extrato", fields: [
    { name: "movement_id", label: "Movimento", type: "uuid" }, { name: "reference", label: "Identificador único do extrato", type: "text", min: 3, max: 160 }, { name: "amount", label: "Valor do extrato (saída negativa)", type: "decimal" }, { name: "occurred_on", label: "Data do extrato", type: "date" }] },
  classify: { rpc: "operational_classify_financial_result", label: "Classificar obrigação na DRE", fields: [
    { name: "obligation_id", label: "ID da obrigação financeira", type: "uuid" }, { name: "category", label: "Categoria", type: "select", options: ["revenue", "deduction", "cost", "expense", "financial_income", "financial_expense", "excluded"] }, { name: "recognized_on", label: "Data de competência", type: "date" }, { name: "reason", label: "Justificativa", type: "text", min: 10, max: 1000 }] },
  plan: { rpc: "master_save_saas_plan", label: "Salvar plano (código existente atualiza)", fields: [
    { name: "code", label: "Código", type: "text", min: 2, max: 32 }, { name: "name", label: "Nome", type: "text", min: 2, max: 160 }, { name: "status", label: "Situação", type: "select", options: ["draft", "active", "retired"] }, { name: "max_branches", label: "Limite de filiais (vazio: ilimitado)", type: "integer", optional: true, min: 1 }, { name: "max_users", label: "Limite de usuários (vazio: ilimitado)", type: "integer", optional: true, min: 1 }], master: true },
  subscription: { rpc: "master_manage_saas_subscription", label: "Atualizar assinatura", fields: [
    { name: "plan_id", label: "Plano", type: "uuid" }, { name: "status", label: "Situação", type: "select", options: ["pending", "active", "past_due", "suspended", "cancelled"] }, { name: "reason", label: "Justificativa", type: "text", min: 10, max: 1000 }], master: true },
} satisfies Record<string, { rpc: string; label: string; fields: Field[]; request?: boolean; branch?: boolean; master?: boolean }>;
export type Command = keyof typeof commands;
export type CommandSpec = { rpc: string; label: string; fields: Field[]; request?: boolean; branch?: boolean; master?: boolean };
export const uuid = (v: string) => /^[0-9a-f]{8}-[0-9a-f]{4}-[1-8][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i.test(v);
export const validDate = (v: string) => /^\d{4}-\d{2}-\d{2}$/.test(v) && Number.isFinite(Date.parse(v)) && new Date(v).toISOString().slice(0, 10) === v;
export function parseCommand(command: string, form: FormData) {
  if (!Object.hasOwn(commands, command)) throw new Error("Operação inválida.");
  const spec: CommandSpec = commands[command as Command];
  const args: Record<string, string | number | null> = {};
  const fields: Field[] = [...spec.fields];
  if (command !== "plan") fields.push({ name: "tenant_id", label: "Empresa", type: "uuid" });
  if (spec.branch) fields.push({ name: "branch_id", label: "Filial", type: "uuid" });
  if (spec.request) fields.push({ name: "request_id", label: "Solicitação", type: "uuid" });
  for (const field of fields) {
    const raw = form.get(field.name); const value = typeof raw === "string" ? raw.trim() : "";
    if (!value && field.optional) { args[`p_${field.name}`] = null; continue; }
    let valid = Boolean(value);
    if (field.type === "uuid") valid = uuid(value);
    if (field.type === "date") valid = validDate(value);
    if (field.type === "select") valid = Boolean(field.options?.includes(value));
    if (field.type === "text") valid = value.length >= (field.min ?? 1) && value.length <= (field.max ?? 1000);
    if (field.type === "decimal") valid = /^-?\d{1,15}([.,]\d{1,8})?$/.test(value) && Number(value.replace(",", ".")) >= (field.min ?? -Infinity);
    if (field.type === "integer") valid = /^\d+$/.test(value) && Number.isSafeInteger(Number(value)) && Number(value) >= (field.min ?? 1) && Number(value) <= 2147483647;
    if (!valid) throw new Error(`Confira o campo ${field.label}.`);
    args[`p_${field.name}`] = field.type === "integer" ? Number(value) : field.type === "decimal" ? value.replace(",", ".") : value;
  }
  if (command === "transfer" && args.p_from === args.p_to) throw new Error("Escolha contas diferentes.");
  return { spec, args };
}
export function reportPeriod(from?: string, to?: string) {
  const today = new Intl.DateTimeFormat("en-CA", { timeZone: "America/Sao_Paulo" }).format(new Date());
  const start = from ?? `${today.slice(0, 7)}-01`; const end = to ?? today;
  if (!validDate(start) || !validDate(end) || start > end || Date.parse(end) - Date.parse(start) > 366 * 86400000) return null;
  return { from: start, to: end };
}
export function csvCell(value: unknown) {
  const text = String(value ?? "");
  return `"${(/^[\s]*[=+\-@\t\r]/.test(text) ? "'" : "") + text.replaceAll('"', '""')}"`;
}
export function csv(rows: unknown[][]) { return "\uFEFF" + rows.map(row => row.map(csvCell).join(";")).join("\r\n"); }
