"use server";

import { createClient } from "@/lib/supabase/server";
import { resolveTransactionForSession } from "@/lib/master/transaction-resolution";

export async function lookupTransactionCode(rawCode: unknown, tenantId?: unknown, branchId?: unknown) {
  const client = await createClient();
  if (!client) return { status: "unavailable" as const };
  return resolveTransactionForSession(client, rawCode, tenantId, branchId);
}
