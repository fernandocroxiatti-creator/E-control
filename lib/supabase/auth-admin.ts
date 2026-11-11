import "server-only";

import { createClient as createSupabaseClient } from "@supabase/supabase-js";
import { getSupabaseEnv } from "@/lib/supabase/env";

/**
 * This client is intentionally confined to Server Actions.  The key is never
 * imported by a Client Component or returned to a browser response.
 */
export function createAuthAdminClient() {
  const target = getSupabaseEnv();
  const serviceRoleKey = process.env.SUPABASE_SERVICE_ROLE_KEY;
  if (!target || !serviceRoleKey || serviceRoleKey.length < 32) return null;
  return createSupabaseClient(target.url, serviceRoleKey, {
    auth: { autoRefreshToken: false, persistSession: false, detectSessionInUrl: false },
  });
}

/** Separate from the database invitation flag: delivery through Auth Admin
 * remains impossible until a production operator explicitly configures it. */
export function authInvitationsEnabled() {
  return process.env.ECONTROLL_AUTH_INVITATIONS_ENABLED === "true";
}
