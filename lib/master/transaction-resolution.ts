export const transactionCatalog = {
  ME21N: {
    module: "PUR",
    label: "Criar pedido de compra",
    permissionKey: "transaction.purchasing.purchase_order.create",
    route: null,
    enabled: false,
  },
  ME23N: {
    module: "PUR",
    label: "Consultar pedido de compra",
    permissionKey: "transaction.purchasing.purchase_order.read",
    route: null,
    enabled: false,
  },
  MIGO: {
    module: "INV",
    label: "Movimentar estoque",
    permissionKey: "transaction.inventory.stock.move",
    route: null,
    enabled: false,
  },
} as const;

const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[1-8][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i;
const CODE = /^[A-Z][A-Z0-9]{1,19}$/;

export function normalizeTransactionInput(value: unknown): string | null {
  if (typeof value !== "string") return null;
  const normalized = value.trim().toUpperCase();
  return CODE.test(normalized) ? normalized : null;
}

export function validateTransactionContext(companyId: unknown, branchId: unknown): boolean {
  return typeof companyId === "string" && UUID.test(companyId)
    && typeof branchId === "string" && UUID.test(branchId);
}

export function transactionHasExecutableRoute(code: string): boolean {
  const entry = transactionCatalog[code as keyof typeof transactionCatalog];
  return Boolean(entry?.enabled && entry.route);
}

export type TransactionLookupClient = {
  auth: {
    getUser(): Promise<{ data: { user: { id: string } | null }; error: unknown | null }>;
  };
  rpc(name: string, args: Record<string, unknown>): PromiseLike<{ data: unknown; error: unknown | null }>;
};

export type TransactionLookupResult =
  | { status: "invalid" | "unknown" | "unauthenticated" | "context_required" | "unavailable" | "denied" | "authorized" };

/** Resolves an ERP transaction through the authenticated, tenant-and-branch-scoped database policy. */
export async function resolveTransactionForSession(
  client: TransactionLookupClient,
  rawCode: unknown,
  tenantId?: unknown,
  branchId?: unknown,
): Promise<TransactionLookupResult> {
  const code = normalizeTransactionInput(rawCode);
  if (!code) return { status: "invalid" };
  let user: { id: string } | null;
  try {
    const result = await client.auth.getUser();
    if (result.error || !result.data.user) return { status: "unauthenticated" };
    user = result.data.user;
  } catch {
    return { status: "unauthenticated" };
  }
  if (!user.id) return { status: "unauthenticated" };
  if (!Object.hasOwn(transactionCatalog, code)) return { status: "unknown" };
  if (!validateTransactionContext(tenantId, branchId)) return { status: "context_required" };
  try {
    const { data, error } = await client.rpc("authorize_company_transaction", {
      p_tenant_id: tenantId,
      p_branch_id: branchId,
      p_transaction_code: code,
    });
    if (error || typeof data !== "boolean") return { status: "unavailable" };
    return data ? { status: "authorized" } : { status: "denied" };
  } catch {
    return { status: "unavailable" };
  }
}
