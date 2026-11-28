const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[1-8][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i;
const validDate = (value: string) => /^\d{4}-\d{2}-\d{2}$/.test(value) && Number.isFinite(Date.parse(value)) && new Date(value).toISOString().slice(0, 10) === value;
export function parseBillingReceivable(form: FormData) {
  const value = (name: string) => typeof form.get(name) === "string" ? String(form.get(name)).trim() : "";
  const tenant = value("tenant_id"), billing = value("billing_document_id"), request = value("request_id"), issue = value("issue_date"), terms = value("payment_terms"), existing = value("existing_obligation_id");
  if (![tenant, billing, request].every(id => UUID.test(id)) || !validDate(issue) || terms.length < 3 || terms.length > 500 || (existing && !UUID.test(existing))) throw new Error("Confira empresa, faturamento, data e condição de pagamento.");
  const mode = value("mode");
  if (!["generate", "existing"].includes(mode) || (mode === "existing" && !existing) || (mode === "generate" && existing)) throw new Error("Escolha gerar recebível ou vincular uma obrigação existente.");
  const dates = form.getAll("due_date"), amounts = form.getAll("amount");
  const installments: { due_date: string; amount: string }[] = [];
  if (mode === "generate") {
    if (dates.length < 1 || dates.length > 120 || dates.length !== amounts.length) throw new Error("Informe de 1 a 120 parcelas.");
    let previous = issue;
    for (let index = 0; index < dates.length; index++) {
      const due = typeof dates[index] === "string" ? String(dates[index]).trim() : "";
      const amount = typeof amounts[index] === "string" ? String(amounts[index]).trim().replace(",", ".") : "";
      if (!validDate(due) || due < previous || !/^\d{1,15}(\.\d{1,8})?$/.test(amount) || !/[1-9]/.test(amount)) throw new Error("Confira valores positivos e vencimentos em ordem, a partir da emissão.");
      previous = due; installments.push({ due_date: due, amount });
    }
  }
  return { p_tenant_id: tenant, p_billing_document_id: billing, p_issue_date: issue, p_payment_terms: terms, p_installments: installments, p_request_id: request, p_existing_obligation_id: existing || null };
}
