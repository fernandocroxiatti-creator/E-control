export type MasterCompanyInput = {
  legalName: string;
  requestId: string;
};

export type MasterCompanyResult =
  | { status: "created"; companyId: string }
  | { status: "unauthenticated" | "denied" | "unavailable" | "invalid" };

export type MasterCompanyFormState = {
  status: "idle" | "error" | "success";
  message?: string;
  companyId?: string;
};

type CompanyCreationClient = {
  auth: {
    getUser(): Promise<{
      data: { user: { id: string } | null };
      error: unknown | null;
    }>;
  };
  rpc(
    name: "master_create_company",
    args: { p_request_id: string; p_legal_name: string },
  ): PromiseLike<{ data: unknown; error: { code?: string } | null }>;
};

const UUID_PATTERN = /^[0-9a-f]{8}-[0-9a-f]{4}-[1-8][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i;

export function validateMasterCompanyInput(
  legalName: unknown,
  requestId: unknown,
): MasterCompanyInput | null {
  if (typeof legalName !== "string" || typeof requestId !== "string") return null;

  const normalizedName = legalName.trim();
  const characterCount = [...normalizedName].length;
  if (characterCount < 1 || characterCount > 200 || !UUID_PATTERN.test(requestId)) return null;

  return { legalName: normalizedName, requestId: requestId.toLowerCase() };
}

/** The browser never supplies an actor ID; the database derives it from auth.uid(). */
export async function createMasterCompany(
  client: CompanyCreationClient,
  input: MasterCompanyInput,
): Promise<MasterCompanyResult> {
  try {
    const { data, error } = await client.auth.getUser();
    if (error || !data.user) return { status: "unauthenticated" };
  } catch {
    return { status: "unauthenticated" };
  }

  try {
    const { data, error } = await client.rpc("master_create_company", {
      p_request_id: input.requestId,
      p_legal_name: input.legalName,
    });
    if (error) {
      return { status: error.code === "42501" ? "denied" : "unavailable" };
    }
    if (typeof data !== "string" || !UUID_PATTERN.test(data)) return { status: "unavailable" };
    return { status: "created", companyId: data };
  } catch {
    return { status: "unavailable" };
  }
}
