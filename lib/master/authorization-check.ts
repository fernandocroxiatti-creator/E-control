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
  | { status: "authorized"; user: MasterUser };

/** Resolve Master access using only the current server-side Auth session and RPC. */
export async function checkMasterAuthorization(
  client: MasterAuthorizationClient,
): Promise<MasterAuthorizationResult> {
  let authResult: Awaited<ReturnType<MasterAuthorizationClient["auth"]["getUser"]>>;

  try {
    authResult = await client.auth.getUser();
  } catch {
    return { status: "unauthenticated" };
  }

  const { data, error } = authResult;
  if (error || !data.user) return { status: "unauthenticated" };

  try {
    const authorization = await client.rpc("is_current_user_master");
    if (authorization.error || authorization.data !== true) return { status: "denied" };
  } catch {
    return { status: "denied" };
  }

  return { status: "authorized", user: data.user };
}
