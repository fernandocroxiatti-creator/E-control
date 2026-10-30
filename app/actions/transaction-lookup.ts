"use server";

import { createClient } from "@/lib/supabase/server";
import { getSupabaseEnv } from "@/lib/supabase/env";
import { resolveTransactionForSession } from "@/lib/master/transaction-resolution";

export async function lookupTransactionCode(rawCode: unknown, tenantId?: unknown, branchId?: unknown) {
  const client = await createClient();
  if (!client) return { status: "unavailable" as const };
  const result = await resolveTransactionForSession(client, rawCode, tenantId, branchId);
  if (result.status !== "authorized") return result;
  // Navigation is withheld until the environment is explicitly enabled, after
  // the database authorization has confirmed the real session and context.
  if (!getSupabaseEnv()?.operationalEnabled) return { status: "disabled" as const };
  return result;
}
