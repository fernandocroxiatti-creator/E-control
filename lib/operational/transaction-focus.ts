import {
  getErpTransactionDefinition,
  resolveTransactionForSession,
  type TransactionLookupClient,
  type TransactionLookupResult,
} from "@/lib/master/transaction-resolution";

export type OperationalRouteTransaction = "BP01" | "MM01" | "SV01" | "MIGO" | "ME21N" | "ME23N";

const routeTransactions = new Set<OperationalRouteTransaction>(["BP01", "MM01", "SV01", "MIGO", "ME21N", "ME23N"]);

/**
 * A route focus is presentation metadata only. The caller must still invoke
 * authorize_company_transaction through authorizeRouteTransaction before using
 * it, so a hand-written URL cannot bypass the database contract.
 */
export function operationalRouteTransaction(value: string | undefined): OperationalRouteTransaction | null {
  const code = value?.trim().toUpperCase();
  return code && routeTransactions.has(code as OperationalRouteTransaction) ? code as OperationalRouteTransaction : null;
}

export async function authorizeRouteTransaction(
  client: TransactionLookupClient,
  code: OperationalRouteTransaction | null,
  tenantId: string | undefined,
  branchId: string | undefined,
): Promise<TransactionLookupResult | null> {
  if (!code) return null;
  return resolveTransactionForSession(client, code, tenantId, branchId);
}

export function isRouteAuthorized(result: TransactionLookupResult | null) {
  return result === null || result.status === "authorized";
}

export function routeTransactionTitle(code: OperationalRouteTransaction | null) {
  return code ? getErpTransactionDefinition(code)?.name ?? "Operação" : null;
}
