export type SaasPolicyInput = { tenantId: string; enabled: boolean; blockOnOverdue: boolean; dueOn: string | null; graceDays: number; reason: string };
const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[1-8][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i;
function text(form: FormData, key: string) { const value = form.get(key); return typeof value === "string" ? value.trim() : ""; }
export function validSaasDate(value: string) { return /^\d{4}-\d{2}-\d{2}$/.test(value) && Number.isFinite(Date.parse(value)) && new Date(value).toISOString().slice(0,10) === value; }
export function parseSaasPolicy(form: FormData): SaasPolicyInput {
  const tenantId = text(form,"tenant_id"); const enabledValue = text(form,"enabled"); const blockValue = text(form,"block_on_overdue"); const dueOn = text(form,"due_on"); const grace = text(form,"grace_days"); const reason = text(form,"reason");
  if (!UUID.test(tenantId) || !["true","false"].includes(enabledValue) || !["true","false"].includes(blockValue) || !/^\d{1,2}$/.test(grace) || Number(grace)>90 || reason.length<10 || reason.length>1000 || (dueOn && !validSaasDate(dueOn)) || (enabledValue === "true" && !dueOn)) throw new Error("Confira a empresa, o vencimento, a tolerância (0–90 dias) e a justificativa de ao menos 10 caracteres.");
  return { tenantId, enabled: enabledValue === "true", blockOnOverdue: blockValue === "true", dueOn: dueOn || null, graceDays: Number(grace), reason };
}
export function parseSaasReactivation(form: FormData) {
  const tenantId=text(form,"tenant_id"), dueOn=text(form,"due_on"), reason=text(form,"reason");
  if (!UUID.test(tenantId) || !validSaasDate(dueOn) || reason.length<10 || reason.length>1000) throw new Error("Informe empresa, novo vencimento e justificativa de ao menos 10 caracteres.");
  return { tenantId, dueOn, reason };
}
export type CompanySubscription = { tenant_id: string; plan: string | null; status: string | null; due_on: string | null; grace_days: number; enforcement_enabled: boolean; operational_allowed: boolean; branches_used: number; users_used: number; max_branches: number | null; max_users: number | null };
export type CommercialPolicy = { tenant_id: string; enforcement_enabled: boolean; block_on_overdue: boolean; due_on: string | null; grace_days: number; operational_allowed: boolean };
export const subscriptionStatus: Record<string,string> = { pending: "Aguardando ativação", active: "Ativa", past_due: "Inadimplente", suspended: "Suspensa", cancelled: "Cancelada" };
