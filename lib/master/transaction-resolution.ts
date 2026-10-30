export type ErpTransactionDefinition = {
  code: string;
  moduleCode: "MDM" | "INV" | "PUR";
  moduleName: string;
  name: string;
  description: string;
  permissionKey: string;
  route: string;
};

/**
 * Browser-safe presentation metadata. Authorization never relies on this map:
 * every lookup is verified by authorize_company_transaction on the server.
 */
export const erpTransactionCatalog = {
  BP01: {
    code: "BP01", moduleCode: "MDM", moduleName: "Cadastros", name: "Clientes e fornecedores",
    description: "Consulta e gestão de parceiros comerciais autorizados.",
    permissionKey: "transaction.masterdata.party.manage", route: "/operacional/cadastros",
  },
  MM01: {
    code: "MM01", moduleCode: "MDM", moduleName: "Estoque e produtos", name: "Cadastro de produtos",
    description: "Consulta e gestão do catálogo de produtos.",
    permissionKey: "transaction.masterdata.catalog.product.manage", route: "/operacional/cadastros?item_type=product",
  },
  SV01: {
    code: "SV01", moduleCode: "MDM", moduleName: "Cadastros", name: "Cadastro de serviços",
    description: "Consulta e gestão do catálogo de serviços.",
    permissionKey: "transaction.masterdata.catalog.service.manage", route: "/operacional/cadastros?item_type=service",
  },
  MIGO: {
    code: "MIGO", moduleCode: "INV", moduleName: "Estoque e produtos", name: "Movimentação de estoque",
    description: "Entradas, saídas e ajustes de estoque autorizados.",
    permissionKey: "transaction.inventory.stock.move", route: "/operacional/estoque",
  },
  ME21N: {
    code: "ME21N", moduleCode: "PUR", moduleName: "Compras", name: "Criar pedido de compra",
    description: "Criação de pedidos de compra em rascunho.",
    permissionKey: "transaction.purchasing.purchase_order.create", route: "/operacional/compras",
  },
  ME23N: {
    code: "ME23N", moduleCode: "PUR", moduleName: "Compras", name: "Consultar pedidos de compra",
    description: "Consulta dos pedidos de compra autorizados.",
    permissionKey: "transaction.purchasing.purchase_order.read", route: "/operacional/compras",
  },
} as const satisfies Record<string, ErpTransactionDefinition>;

export type ErpTransactionCode = keyof typeof erpTransactionCatalog;

export function getErpTransactionDefinition(code: string | null | undefined): ErpTransactionDefinition | null {
  if (!code || !Object.hasOwn(erpTransactionCatalog, code)) return null;
  return erpTransactionCatalog[code as ErpTransactionCode];
}


export const transactionCatalog = erpTransactionCatalog;

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
  return Boolean(getErpTransactionDefinition(code)?.route);
}

export type TransactionLookupClient = {
  auth: {
    getUser(): Promise<{ data: { user: { id: string } | null }; error: unknown | null }>;
  };
  rpc(name: string, args: Record<string, unknown>): PromiseLike<{ data: unknown; error: unknown | null }>;
};

export type TransactionLookupResult =
  | { status: "invalid" | "unknown" | "unauthenticated" | "context_required" | "unavailable" | "denied" }
  | { status: "authorized"; code: string; route: string; name: string };

/** Resolves one known transaction through the authenticated, tenant-and-branch-scoped database policy. */
export async function resolveTransactionForSession(
  client: TransactionLookupClient,
  rawCode: unknown,
  tenantId?: unknown,
  branchId?: unknown,
): Promise<TransactionLookupResult> {
  const code = normalizeTransactionInput(rawCode);
  if (!code) return { status: "invalid" };
  const definition = getErpTransactionDefinition(code);
  if (!definition) return { status: "unknown" };
  let user: { id: string } | null;
  try {
    const result = await client.auth.getUser();
    if (result.error || !result.data.user) return { status: "unauthenticated" };
    user = result.data.user;
  } catch {
    return { status: "unauthenticated" };
  }
  if (!user.id) return { status: "unauthenticated" };
  if (!validateTransactionContext(tenantId, branchId)) return { status: "context_required" };
  try {
    const { data, error } = await client.rpc("authorize_company_transaction", {
      p_tenant_id: tenantId,
      p_branch_id: branchId,
      p_transaction_code: code,
    });
    if (error || typeof data !== "boolean") return { status: "unavailable" };
    return data ? { status: "authorized", code, route: definition.route, name: definition.name } : { status: "denied" };
  } catch {
    return { status: "unavailable" };
  }
}
