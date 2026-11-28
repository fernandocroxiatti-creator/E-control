import {
  getErpTransactionDefinition,
  resolveTransactionForSession,
  type TransactionLookupClient,
  type TransactionLookupResult,
} from "@/lib/master/transaction-resolution";

export type OperationalRouteTransaction = "BP01" | "MM01" | "SV01" | "MIGO" | "ME21N" | "ME23N" | "ZGR01" | "ZIV01" | "MM02" | "MM03" | "MB52" | "MB51" | "MI01" | "MI04" | "MI07" | "ZTR01" | "ZOS01" | "ZOS02" | "ZOS03" | "ZOS04" | "ZQT01" | "ZQT02" | "ZQT03" | "ZQT04" | "ZVE01" | "ZVE02" | "ZVE03" | "ZVE04" | "ZVE05" | "ZVE06" | "ZVE07" | "ZFB01" | "ZFB02" | "ZFB03" | "ZFI01" | "ZFI02" | "ZFI03" | "ZFI04" | "ZCX01" | "ZCX02" | "ZCX03" | "ZCX04" | "ZTR02" | "ZTR03" | "ZTR04" | "ZTR05" | "ZGE01" | "ZGE02" | "ZTR06" | "ZFB04" | "ZRP01" | "ZRP02" | "ZRP03" | "ZRP04" | "ZRP05" | "ZRP06";

const routeTransactions = new Set<OperationalRouteTransaction>(["BP01", "MM01", "SV01", "MIGO", "ME21N", "ME23N", "ZGR01", "ZIV01", "MM02", "MM03", "MB52", "MB51", "MI01", "MI04", "MI07", "ZTR01", "ZOS01", "ZOS02", "ZOS03", "ZOS04", "ZQT01", "ZQT02", "ZQT03", "ZQT04", "ZVE01", "ZVE02", "ZVE03", "ZVE04", "ZVE05", "ZVE06", "ZVE07", "ZFB01", "ZFB02", "ZFB03", "ZFI01", "ZFI02", "ZFI03", "ZFI04", "ZCX01", "ZCX02", "ZCX03", "ZCX04", "ZTR02", "ZTR03", "ZTR04", "ZTR05", "ZGE01", "ZGE02", "ZTR06", "ZFB04", "ZRP01", "ZRP02", "ZRP03", "ZRP04", "ZRP05", "ZRP06"]);

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
