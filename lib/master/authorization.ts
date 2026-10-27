import "server-only";

import { notFound, redirect } from "next/navigation";
import { createClient } from "@/lib/supabase/server";
import { checkMasterAuthorization } from "./authorization-check";

export async function resolveMasterAuthorization() {
  try {
    const supabase = await createClient();
    if (!supabase) return { status: "unavailable" } as const;
    return await checkMasterAuthorization(supabase);
  } catch {
    return { status: "unavailable" } as const;
  }
}

/** Server-side gate. Missing sessions go to login; an explicit non-Master remains 404. */
export async function requireMasterUser() {
  const authorization = await resolveMasterAuthorization();
  if (authorization.status === "unauthenticated") redirect("/login?next=%2Fmaster");
  if (authorization.status === "denied") notFound();
  if (authorization.status === "unavailable") throw new Error("Master authorization check unavailable");
  return authorization.user;
}
