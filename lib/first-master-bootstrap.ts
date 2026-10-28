import "server-only";

import { headers } from "next/headers";
import { getSupabaseEnv, getSiteUrl } from "@/lib/supabase/env";

export type FirstMasterBootstrapClient = {
  auth: { getUser(): Promise<{ data: { user: { id: string } | null }; error: unknown | null }> };
  rpc(name: "is_current_first_master_bootstrap_candidate" | "bootstrap_first_master"): PromiseLike<{
    data: unknown;
    error: unknown | null;
  }>;
};

export function isFirstMasterBootstrapInvokerEnabled(env: NodeJS.ProcessEnv = process.env): boolean {
  const target = getSupabaseEnv();
  return target?.target === "production"
    && env.ECONTROLL_PROD_FIRST_MASTER_BOOTSTRAP_INVOKER_ENABLED === "true";
}

export async function isCurrentSessionApprovedForFirstMaster(client: Pick<FirstMasterBootstrapClient, "auth" | "rpc">) {
  try {
    const authenticated = await client.auth.getUser();
    if (authenticated.error || !authenticated.data.user) return false;
    const approved = await client.rpc("is_current_first_master_bootstrap_candidate");
    return !approved.error && approved.data === true;
  } catch {
    return false;
  }
}

export async function assertFirstMasterBootstrapCsrf(): Promise<boolean> {
  try {
    const requestHeaders = await headers();
    const origin = requestHeaders.get("origin");
    const site = getSiteUrl();
    return origin === site.origin;
  } catch {
    return false;
  }
}
