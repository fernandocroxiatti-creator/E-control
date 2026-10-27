import { isAuthSessionMissingError } from "@supabase/supabase-js";

type MasterUser = {
  id: string;
  email?: string;
};

type MasterAuthorizationClient = {
  auth: {
    getUser(): Promise<{
      data: { user: MasterUser | null };
      error: unknown | null;
    }>;
  };
  rpc(name: "is_current_user_master"): PromiseLike<{
    data: unknown;
    error: unknown | null;
  }>;
};

export type MasterAuthorizationResult =
  | { status: "unauthenticated" }
  | { status: "denied" }
  | { status: "unavailable" }
  | { status: "authorized"; user: MasterUser };

/** Checks the current authenticated Supabase client without trusting browser state. */
export async function isCurrentSessionMaster(client: Pick<MasterAuthorizationClient, "rpc">): Promise<boolean> {
  try {
    const authorization = await client.rpc("is_current_user_master");
    return !authorization.error && authorization.data === true;
  } catch {
    return false;
  }
}

/** Resolve Master access using only the current server-side Auth session and RPC. */
export async function checkMasterAuthorization(
  client: MasterAuthorizationClient,
): Promise<MasterAuthorizationResult> {
  let authResult: Awaited<ReturnType<MasterAuthorizationClient["auth"]["getUser"]>>;

  try {
    authResult = await client.auth.getUser();
  } catch (error) {
    return { status: isAuthSessionMissingError(error) ? "unauthenticated" : "unavailable" };
  }

  const { data, error } = authResult;
  if (error) return { status: isAuthSessionMissingError(error) ? "unauthenticated" : "unavailable" };
  if (!data.user) return { status: "unauthenticated" };

  let authorization: Awaited<ReturnType<MasterAuthorizationClient["rpc"]>>;
  try {
    authorization = await client.rpc("is_current_user_master");
  } catch {
    return { status: "unavailable" };
  }
  if (authorization.error) return { status: "unavailable" };
  if (authorization.data !== true) return { status: "denied" };

  return { status: "authorized", user: data.user };
}
