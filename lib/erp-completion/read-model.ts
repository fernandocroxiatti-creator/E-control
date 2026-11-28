import "server-only";
import { createClient } from "@/lib/supabase/server";
import { getSupabaseEnv } from "@/lib/supabase/env";
import { isAuthorizedSupabaseTarget } from "@/lib/supabase/homologation-env";
import { getOperationalTransactionContexts } from "@/lib/companies/authorized-transaction-context";
export type BankData = { accounts: { id: string; code: string; name: string; status: string; balance: number; account_kind: string }[]; movements: { id: string; bank_account_id: string; direction: string; amount: number; occurred_on: string; description: string; reconciled_at: string | null; statement_reference: string | null }[] };
export type ManagementData = { dre: { category: string; amount: number }[]; unclassified: number; receivable_open: number; payable_open: number; cash_flow: { day: string; receipts: number; payments: number; expected_in: number; expected_out: number }[] };
export type SaasData = { plans: { id: string; code: string; name: string; status: string; max_branches: number | null; max_users: number | null }[]; subscriptions: { id: string; tenant_id: string; plan_id: string; status: string; starts_at: string | null; ends_at: string | null }[]; companies: { id: string; name: string; status: string; branches: number; members: number }[]; events: { id: string; tenant_id: string; event_key: string; reason: string; created_at: string }[] };
export async function operationalReportContext(branch?: string) {
  const client = await createClient();
  if (!client) return null;
  const { data: { user }, error } = await client.auth.getUser(); if (!user || error) return null;
  const access = await getOperationalTransactionContexts(client, user.id);
  const selected = branch ? access.contexts.find(c => c.branchId === branch) : access.contexts[0];
  const env = getSupabaseEnv();
  return { client, access, selected, enabled: Boolean(env && env.operationalEnabled && isAuthorizedSupabaseTarget(env)) };
}
export const formatMoney = (v: number) => new Intl.NumberFormat("pt-BR", { style: "currency", currency: "BRL" }).format(Number(v));
