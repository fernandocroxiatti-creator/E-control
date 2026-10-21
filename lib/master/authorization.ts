import "server-only";

import { notFound, redirect } from "next/navigation";
import { createClient } from "@/lib/supabase/server";
import { checkMasterAuthorization } from "./authorization-check";

/** Server-side gate. Every request must pass Auth identity and the persistent Master RPC. */
export async function requireMasterUser() {
  const supabase = await createClient();
  if (!supabase) redirect("/login?next=%2Fmaster");

  const authorization = await checkMasterAuthorization(supabase);
  if (authorization.status === "unauthenticated") redirect("/login?next=%2Fmaster");
  if (authorization.status !== "authorized") notFound();

  return authorization.user;
}
