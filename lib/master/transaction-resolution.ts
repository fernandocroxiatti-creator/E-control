export type ErpTransactionDefinition = {
  code: string;
  moduleCode: "MDM" | "INV" | "PUR" | "SVC" | "BUD" | "SAL" | "FIN" | "CSH";
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
    permissionKey: "transaction.masterdata.party.manage", route: "/operacional/cadastros?tx=BP01",
  },
  MM01: {
    code: "MM01", moduleCode: "MDM", moduleName: "Estoque e produtos", name: "Cadastro de produtos",
    description: "Consulta e gestão do catálogo de produtos.",
    permissionKey: "transaction.masterdata.catalog.product.manage", route: "/operacional/cadastros?tx=MM01",
  },
  SV01: {
    code: "SV01", moduleCode: "MDM", moduleName: "Cadastros", name: "Cadastro de serviços",
    description: "Consulta e gestão do catálogo de serviços.",
    permissionKey: "transaction.masterdata.catalog.service.manage", route: "/operacional/cadastros?tx=SV01",
  },
  MIGO: {
    code: "MIGO", moduleCode: "INV", moduleName: "Estoque e produtos", name: "Movimentação de estoque",
    description: "Entradas, saídas e ajustes de estoque autorizados.",
    permissionKey: "transaction.inventory.stock.move", route: "/operacional/estoque?tx=MIGO",
  },
  ME21N: {
    code: "ME21N", moduleCode: "PUR", moduleName: "Compras", name: "Criar pedido de compra",
    description: "Criação de pedidos de compra em rascunho.",
    permissionKey: "transaction.purchasing.purchase_order.create", route: "/operacional/compras?tx=ME21N",
  },
  ME23N: {
    code: "ME23N", moduleCode: "PUR", moduleName: "Compras", name: "Consultar pedidos de compra",
    description: "Consulta dos pedidos de compra autorizados.",
    permissionKey: "transaction.purchasing.purchase_order.read", route: "/operacional/compras?tx=ME23N",
  },
  ZGR01: {
    code: "ZGR01", moduleCode: "PUR", moduleName: "Compras", name: "Receber pedido de compra",
    description: "Recebimento parcial ou total, custo médio e estorno auditáveis.",
    permissionKey: "transaction.purchasing.receipt.manage", route: "/operacional/compras?tx=ZGR01",
  },
  ZIV01: {
    code: "ZIV01", moduleCode: "INV", moduleName: "Estoque", name: "Avaliação inicial de estoque",
    description: "Regularização auditada de saldo legado sem custo confiável.",
    permissionKey: "transaction.inventory.valuation.initial", route: "/operacional/estoque?tx=ZIV01",
  },
  MM02: { code: "MM02", moduleCode: "MDM", moduleName: "Estoque e produtos", name: "Alterar produtos", description: "Alteração autorizada de produtos cadastrados.", permissionKey: "transaction.masterdata.catalog.product.update", route: "/operacional/cadastros?tx=MM02&item_type=product" },
  MM03: { code: "MM03", moduleCode: "MDM", moduleName: "Estoque e produtos", name: "Consultar produtos", description: "Consulta autorizada do catálogo de produtos.", permissionKey: "transaction.masterdata.catalog.product.read", route: "/operacional/cadastros?tx=MM03&item_type=product" },
  MB52: { code: "MB52", moduleCode: "INV", moduleName: "Estoque", name: "Saldos por filial", description: "Consulta de saldos por filial autorizada.", permissionKey: "transaction.inventory.balance.read", route: "/operacional/estoque?tx=MB52" },
  MB51: { code: "MB51", moduleCode: "INV", moduleName: "Estoque", name: "Histórico de estoque", description: "Consulta auditável de movimentações por filial.", permissionKey: "transaction.inventory.history.read", route: "/operacional/estoque?tx=MB51" },
  MI01: { code: "MI01", moduleCode: "INV", moduleName: "Estoque", name: "Iniciar inventário", description: "Abertura de inventário físico por filial.", permissionKey: "transaction.inventory.physical.create", route: "/operacional/estoque?tx=MI01" },
  MI04: { code: "MI04", moduleCode: "INV", moduleName: "Estoque", name: "Registrar contagem", description: "Registro de contagem física autorizado.", permissionKey: "transaction.inventory.physical.count", route: "/operacional/estoque?tx=MI04" },
  MI07: { code: "MI07", moduleCode: "INV", moduleName: "Estoque", name: "Aplicar inventário", description: "Aplicação auditada de diferenças de inventário.", permissionKey: "transaction.inventory.physical.adjust", route: "/operacional/estoque?tx=MI07" },
  ZTR01: { code: "ZTR01", moduleCode: "INV", moduleName: "Estoque", name: "Transferir entre filiais", description: "Transferência atômica e rastreável entre filiais autorizadas.", permissionKey: "transaction.inventory.transfer", route: "/operacional/estoque?tx=ZTR01" },
  ZOS01: { code: "ZOS01", moduleCode: "SVC", moduleName: "Ordem de serviço", name: "Criar ordem de serviço", description: "Abertura de O.S. por empresa e filial.", permissionKey: "transaction.service_order.create", route: "/operacional/ordens-servico?tx=ZOS01" },
  ZOS02: { code: "ZOS02", moduleCode: "SVC", moduleName: "Ordem de serviço", name: "Alterar ordem de serviço", description: "Diagnóstico, serviços e peças de uma O.S.", permissionKey: "transaction.service_order.update", route: "/operacional/ordens-servico?tx=ZOS02" },
  ZOS03: { code: "ZOS03", moduleCode: "SVC", moduleName: "Ordem de serviço", name: "Consultar ordem de serviço", description: "Consulta de O.S. autorizada por filial.", permissionKey: "transaction.service_order.read", route: "/operacional/ordens-servico?tx=ZOS03" },
  ZOS04: { code: "ZOS04", moduleCode: "SVC", moduleName: "Ordem de serviço", name: "Encerrar ordem de serviço", description: "Consumo, encerramento e estorno auditáveis.", permissionKey: "transaction.service_order.close", route: "/operacional/ordens-servico?tx=ZOS04" },
  ZQT01: { code: "ZQT01", moduleCode: "BUD", moduleName: "Orçamentos", name: "Criar orçamento", description: "Criação de rascunho comercial por empresa e filial.", permissionKey: "transaction.quotation.create", route: "/operacional/orcamentos?tx=ZQT01" },
  ZQT02: { code: "ZQT02", moduleCode: "BUD", moduleName: "Orçamentos", name: "Alterar orçamento", description: "Alteração de rascunho comercial com nova fotografia de itens.", permissionKey: "transaction.quotation.manage", route: "/operacional/orcamentos?tx=ZQT02" },
  ZQT03: { code: "ZQT03", moduleCode: "BUD", moduleName: "Orçamentos", name: "Consultar orçamentos", description: "Consulta empresarial e por filial de orçamentos.", permissionKey: "transaction.quotation.read", route: "/operacional/orcamentos?tx=ZQT03" },
  ZQT04: { code: "ZQT04", moduleCode: "BUD", moduleName: "Orçamentos", name: "Aprovar orçamento", description: "Aprovação ou reprovação com justificativa auditável.", permissionKey: "transaction.quotation.approve", route: "/operacional/orcamentos?tx=ZQT04" },
  ZVE01: { code: "ZVE01", moduleCode: "SAL", moduleName: "Vendas", name: "Criar pedido de venda", description: "Criação de pedido comercial por empresa e filial.", permissionKey: "transaction.sales.order.create", route: "/operacional/vendas?tx=ZVE01" },
  ZVE02: { code: "ZVE02", moduleCode: "SAL", moduleName: "Vendas", name: "Alterar pedido de venda", description: "Alteração de rascunho comercial por empresa e filial.", permissionKey: "transaction.sales.order.manage", route: "/operacional/vendas?tx=ZVE02" },
  ZVE03: { code: "ZVE03", moduleCode: "SAL", moduleName: "Vendas", name: "Consultar pedidos de venda", description: "Consulta de pedidos comerciais por empresa e filial.", permissionKey: "transaction.sales.order.read", route: "/operacional/vendas?tx=ZVE03" },
  ZVE04: { code: "ZVE04", moduleCode: "SAL", moduleName: "Vendas", name: "Confirmar pedido de venda", description: "Confirmação ou cancelamento auditável de pedido comercial.", permissionKey: "transaction.sales.order.decide", route: "/operacional/vendas?tx=ZVE04" },
  ZFB01: { code: "ZFB01", moduleCode: "FIN", moduleName: "Faturamento", name: "Emitir faturamento comercial", description: "Emissão interna auditável de faturamento, sem documento fiscal ou recebível automático.", permissionKey: "transaction.billing.issue", route: "/operacional/faturamento?tx=ZFB01" },
  ZFB02: { code: "ZFB02", moduleCode: "FIN", moduleName: "Faturamento", name: "Consultar faturamento comercial", description: "Consulta empresarial e por filial de faturamentos internos.", permissionKey: "transaction.billing.read", route: "/operacional/faturamento?tx=ZFB02" },
  ZFB03: { code: "ZFB03", moduleCode: "FIN", moduleName: "Faturamento", name: "Cancelar faturamento comercial", description: "Cancelamento auditável de faturamento interno sem estorno fiscal ou financeiro.", permissionKey: "transaction.billing.cancel", route: "/operacional/faturamento?tx=ZFB03" },
  ZFI01: { code: "ZFI01", moduleCode: "FIN", moduleName: "Financeiro", name: "Criar contas a pagar", description: "Registro empresarial e parcelado de obrigações a pagar.", permissionKey: "transaction.finance.payable.manage", route: "/operacional/financeiro?tx=ZFI01" },
  ZFI02: { code: "ZFI02", moduleCode: "FIN", moduleName: "Financeiro", name: "Criar contas a receber", description: "Registro empresarial e parcelado de direitos a receber.", permissionKey: "transaction.finance.receivable.manage", route: "/operacional/financeiro?tx=ZFI02" },
  ZFI03: { code: "ZFI03", moduleCode: "FIN", moduleName: "Financeiro", name: "Baixas financeiras", description: "Baixas parciais, totais e estornos auditáveis por filial.", permissionKey: "transaction.finance.settlement.manage", route: "/operacional/financeiro?tx=ZFI03" },
  ZFI04: { code: "ZFI04", moduleCode: "FIN", moduleName: "Financeiro", name: "Consultar contas", description: "Consulta empresarial de obrigações e parcelas.", permissionKey: "transaction.finance.read", route: "/operacional/financeiro?tx=ZFI04" },
  ZVE05: { code: "ZVE05", moduleCode: "SAL", moduleName: "Vendas", name: "Reservar estoque da venda", description: "Reserva auditável de saldo para pedido de venda confirmado.", permissionKey: "transaction.sales.inventory.reserve", route: "/operacional/vendas?tx=ZVE05" },
  ZVE06: { code: "ZVE06", moduleCode: "SAL", moduleName: "Vendas", name: "Entregar pedido de venda", description: "Baixa valorada de estoque por entrega de venda confirmada.", permissionKey: "transaction.sales.inventory.fulfill", route: "/operacional/vendas?tx=ZVE06" },
  ZVE07: { code: "ZVE07", moduleCode: "SAL", moduleName: "Vendas", name: "Devolver venda", description: "Devolução auditável que usa o custo imutável da entrega.", permissionKey: "transaction.sales.inventory.return", route: "/operacional/vendas?tx=ZVE07" },
  ZCX01: { code: "ZCX01", moduleCode: "CSH", moduleName: "Caixa e tesouraria", name: "Abrir caixa", description: "Criar caixa e abrir sessão por empresa e filial.", permissionKey: "transaction.cash.register.open", route: "/operacional/caixa?tx=ZCX01" },
  ZCX02: { code: "ZCX02", moduleCode: "CSH", moduleName: "Caixa e tesouraria", name: "Movimentar caixa", description: "Registrar suprimento, sangria, recebimento ou pagamento auditável.", permissionKey: "transaction.cash.register.move", route: "/operacional/caixa?tx=ZCX02" },
  ZCX03: { code: "ZCX03", moduleCode: "CSH", moduleName: "Caixa e tesouraria", name: "Fechar caixa", description: "Apurar conferência e diferença de sessão de caixa.", permissionKey: "transaction.cash.register.close", route: "/operacional/caixa?tx=ZCX03" },
  ZCX04: { code: "ZCX04", moduleCode: "CSH", moduleName: "Caixa e tesouraria", name: "Consultar caixa", description: "Consultar caixas, sessões e movimentos por filial.", permissionKey: "transaction.cash.register.read", route: "/operacional/caixa?tx=ZCX04" },
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
