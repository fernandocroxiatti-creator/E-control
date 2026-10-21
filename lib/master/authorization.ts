import "server-only";

import { notFound, redirect } from "next/navigation";
import { createClient } from "@/lib/supabase/server";

/**
 * Server-side gate for the visual Admin Master area.
 *
 * Only a role written to trusted Auth app_metadata by an administrative
 * channel is considered. user_metadata, email, query parameters and browser
 * state are deliberately ignored. This task does not assign that role.
 */
export async function requireMasterUser() {
  const supabase = await createClient();
  if (!supabase) redirect("/login?next=%2Fmaster");

  const { data, error } = await supabase.auth.getUser();
  if (error || !data.user) redirect("/login?next=%2Fmaster");

  if (data.user.app_metadata?.econtrol_role !== "admin_master") notFound();

  return data.user;
}
