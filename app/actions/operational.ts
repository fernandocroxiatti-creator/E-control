"use server";

import { revalidatePath } from "next/cache";
import { AUTH_ACTIVATION_FLOWS, getAuthActivationRedirectUrl } from "@/lib/supabase/auth-activation";
import { getSiteUrl, getSupabaseEnv } from "@/lib/supabase/env";
import { isAuthorizedSupabaseTarget } from "@/lib/supabase/homologation-env";
import { createClient } from "@/lib/supabase/server";
import { authInvitationsEnabled, createAuthAdminClient } from "@/lib/supabase/auth-admin";

type ActionState = { status: "idle" | "success" | "error"; message?: string };
export const operationalIdle: ActionState = { status: "idle" };
export type EmployeeInvitationActionState = ActionState & { invitationLink?: string; expiresAt?: string };
export type EmployeeInvitationAcceptState = { status: "idle" | "accepted" | "rejected" | "error"; message?: string };
const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[1-8][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i;
const TOKEN = /^[0-9a-f]{64}$/;

async function operationalClient() {
  const env = getSupabaseEnv();
  if (!env || !isAuthorizedSupabaseTarget(env) || !env.operationalEnabled) return null;
  const client = await createClient();
  if (!client) return null;
  const { data: { user }, error } = await client.auth.getUser();
  return error || !user ? null : client;
}
function value(form: FormData, key: string, max = 500) { const raw = form.get(key); return typeof raw === "string" ? raw.trim().slice(0, max) : ""; }
function decimal(input: string) { const parsed = Number(input.replace(",", ".")); return Number.isFinite(parsed) && parsed >= 0 ? parsed : null; }
function requestId(form: FormData) { const id = value(form, "request_id", 36); return UUID.test(id) ? id : null; }
function employeeBranchIds(form: FormData) {
  const ids = form.getAll("branch_id").filter((candidate): candidate is string => typeof candidate === "string" && UUID.test(candidate));
  return ids.length && new Set(ids).size === ids.length ? ids : null;
}
function purchaseItems(form: FormData) {
  const raw = value(form, "items", 20000);
  try {
    const parsed: unknown = JSON.parse(raw);
    if (!Array.isArray(parsed) || parsed.length < 1 || parsed.length > 100) return null;
    const items = parsed.map((item) => {
      if (!item || typeof item !== "object" || Array.isArray(item)) return null;
      const row = item as Record<string, unknown>; const itemId = typeof row.item_id === "string" ? row.item_id : "";
      const quantity = typeof row.quantity === "number" ? row.quantity : Number(row.quantity); const unitPrice = typeof row.unit_price === "number" ? row.unit_price : Number(row.unit_price);
      return UUID.test(itemId) && Number.isFinite(quantity) && quantity > 0 && Number.isFinite(unitPrice) && unitPrice >= 0 ? { item_id: itemId, quantity, unit_price: unitPrice } : null;
    });
    return items.every(Boolean) && new Set(items.map((item) => item!.item_id)).size === items.length ? items : null;
  } catch { return null; }
}
function workOrderLines(form: FormData) {
  const raw = value(form, "lines", 30000);
  try {
    const parsed: unknown = JSON.parse(raw);
    if (!Array.isArray(parsed) || parsed.length > 100) return null;
    const lines = parsed.map((line) => {
      if (!line || typeof line !== "object" || Array.isArray(line)) return null;
      const row = line as Record<string, unknown>; const itemId = typeof row.item_id === "string" ? row.item_id : "";
      const lineType = typeof row.line_type === "string" ? row.line_type : "";
      const quantity = Number(row.quantity); const unitPrice = Number(row.unit_price); const discountAmount = Number(row.discount_amount ?? 0);
      return UUID.test(itemId) && ["service", "part"].includes(lineType) && Number.isFinite(quantity) && quantity > 0 && Number.isFinite(unitPrice) && unitPrice >= 0 && Number.isFinite(discountAmount) && discountAmount >= 0 && discountAmount <= quantity * unitPrice
        ? { item_id: itemId, line_type: lineType, quantity, unit_price: unitPrice, discount_amount: discountAmount } : null;
    });
    return lines.every(Boolean) ? lines : null;
  } catch { return null; }
}

export async function createBusinessPartyAction(_: ActionState, form: FormData): Promise<ActionState> {
  try {
    const client = await operationalClient(); const tenantId = value(form, "tenant_id", 36); const id = requestId(form);
    const partyType = value(form, "party_type", 10); const legalName = value(form, "legal_name", 200);
    if (!client || !UUID.test(tenantId) || !id || !["customer", "supplier", "both"].includes(partyType) || !legalName) return { status: "error", message: "Ação indisponível ou dados inválidos." };
    const { error } = await client.rpc("operational_create_business_party", { p_tenant_id: tenantId, p_party_type: partyType, p_legal_name: legalName, p_document_number: value(form, "document_number", 18) || null, p_contact_email: value(form, "contact_email", 254) || null, p_contact_phone: value(form, "contact_phone", 40) || null, p_address: {}, p_request_id: id });
    if (error) return { status: "error", message: "Não foi possível cadastrar. A autorização continua negada até que o banco aceite a operação." };
    revalidatePath("/operacional/cadastros"); return { status: "success", message: "Cadastro registrado e auditado." };
  } catch { return { status: "error", message: "Não foi possível concluir a operação." }; }
}

export async function createCatalogItemAction(_: ActionState, form: FormData): Promise<ActionState> {
  try {
    const client = await operationalClient(); const tenantId = value(form, "tenant_id", 36); const id = requestId(form);
    const itemType = value(form, "item_type", 10); const code = value(form, "code", 64); const name = value(form, "name", 160);
    const cost = decimal(value(form, "current_cost", 32)); const price = decimal(value(form, "selling_price", 32));
    if (!client || !UUID.test(tenantId) || !id || !["product", "service"].includes(itemType) || !code || !name || cost === null || price === null) return { status: "error", message: "Ação indisponível ou dados inválidos." };
    const { error } = await client.rpc("operational_create_catalog_item", { p_tenant_id: tenantId, p_item_type: itemType, p_code: code, p_name: name, p_description: value(form, "description", 500) || null, p_category: value(form, "category", 100) || null, p_brand: value(form, "brand", 100) || null, p_application_model: value(form, "application_model", 160) || null, p_unit_of_measure: value(form, "unit", 8) || "UN", p_supplier_code: value(form, "supplier_code", 64) || null, p_preferred_supplier_id: UUID.test(value(form, "preferred_supplier_id", 36)) ? value(form, "preferred_supplier_id", 36) : null, p_current_cost: cost, p_selling_price: price, p_default_markup_percent: decimal(value(form, "default_markup_percent", 32)), p_target_margin_percent: decimal(value(form, "target_margin_percent", 32)), p_minimum_stock: itemType === "product" ? decimal(value(form, "minimum_stock", 32)) ?? 0 : 0, p_reorder_point: itemType === "product" ? decimal(value(form, "reorder_point", 32)) ?? 0 : 0, p_estimated_minutes: null, p_service_cost: null, p_request_id: id });
    if (error) return { status: "error", message: "Não foi possível cadastrar. A autorização continua negada até que o banco aceite a operação." };
    revalidatePath("/operacional/cadastros"); return { status: "success", message: "Item cadastrado e auditado." };
  } catch { return { status: "error", message: "Não foi possível concluir a operação." }; }
}

export async function updateBusinessPartyAction(_: ActionState, form: FormData): Promise<ActionState> {
  try {
    const client = await operationalClient(); const tenantId = value(form, "tenant_id", 36); const partyId = value(form, "party_id", 36); const id = requestId(form);
    const legalName = value(form, "legal_name", 200);
    if (!client || !UUID.test(tenantId) || !UUID.test(partyId) || !id || !legalName) return { status: "error", message: "Ação indisponível ou dados inválidos." };
    const { error } = await client.rpc("operational_update_business_party", { p_tenant_id: tenantId, p_party_id: partyId, p_legal_name: legalName, p_contact_email: value(form, "contact_email", 254) || null, p_contact_phone: value(form, "contact_phone", 40) || null, p_address: {}, p_request_id: id });
    if (error) return { status: "error", message: "Não foi possível atualizar o cadastro. A autorização empresarial continua obrigatória." };
    revalidatePath("/operacional/cadastros"); return { status: "success", message: "Cadastro atualizado e auditado." };
  } catch { return { status: "error", message: "Não foi possível concluir a operação." }; }
}

export async function updateCatalogItemAction(_: ActionState, form: FormData): Promise<ActionState> {
  try {
    const client = await operationalClient(); const tenantId = value(form, "tenant_id", 36); const itemId = value(form, "item_id", 36); const id = requestId(form);
    const name = value(form, "name", 160); const price = decimal(value(form, "selling_price", 32)); const minimum = decimal(value(form, "minimum_stock", 32)); const reorder = decimal(value(form, "reorder_point", 32)); const status = value(form, "status", 16);
    if (!client || !UUID.test(tenantId) || !UUID.test(itemId) || !id || !name || price === null || minimum === null || reorder === null || !["active", "inactive"].includes(status)) return { status: "error", message: "Ação indisponível ou dados inválidos." };
    const { error } = await client.rpc("operational_update_catalog_item", { p_tenant_id: tenantId, p_item_id: itemId, p_name: name, p_description: value(form, "description", 500) || null, p_category: value(form, "category", 100) || null, p_selling_price: price, p_minimum_stock: minimum, p_reorder_point: reorder, p_status: status, p_request_id: id });
    if (error) return { status: "error", message: "Não foi possível atualizar o item. A autorização empresarial continua obrigatória." };
    revalidatePath("/operacional/cadastros"); revalidatePath("/operacional/estoque"); return { status: "success", message: "Item atualizado e auditado." };
  } catch { return { status: "error", message: "Não foi possível concluir a operação." }; }
}

export async function createPurchaseOrderAction(_: ActionState, form: FormData): Promise<ActionState> {
  try {
    const client = await operationalClient(); const tenantId = value(form, "tenant_id", 36); const branchId = value(form, "branch_id", 36); const supplierId = value(form, "supplier_id", 36); const id = requestId(form); const items = purchaseItems(form);
    if (!client || !UUID.test(tenantId) || !UUID.test(branchId) || !UUID.test(supplierId) || !id || !items) return { status: "error", message: "Pedido inválido. Informe fornecedor e pelo menos um produto com quantidade e preço válidos." };
    const { data: purchaseOrderId, error } = await client.rpc("operational_create_purchase_order", { p_tenant_id: tenantId, p_branch_id: branchId, p_supplier_id: supplierId, p_items: items, p_notes: value(form, "notes", 1000) || null, p_request_id: id });
    if (error) return { status: "error", message: "Não foi possível criar o pedido. A autorização, a filial, o fornecedor e os produtos são validados pelo banco." };
    // ME21N remains usable without ME23N. When the same session also has the
    // read transaction, show the canonical number returned by the protected
    // listing contract; otherwise never expose a direct table read.
    let receipt = "Pedido em rascunho criado e auditado.";
    if (typeof purchaseOrderId === "string" && UUID.test(purchaseOrderId)) {
      const { data: rows, error: listError } = await client.rpc("operational_list_purchase_orders", { p_tenant_id: tenantId, p_branch_id: branchId, p_search: null, p_status: null, p_limit: 100, p_offset: 0 });
      if (!listError && Array.isArray(rows)) {
        const created = rows.find((row) => row && typeof row === "object" && (row as { purchase_order_id?: unknown }).purchase_order_id === purchaseOrderId) as { order_number?: unknown } | undefined;
        if (typeof created?.order_number === "number") receipt = `Pedido #${created.order_number} criado em rascunho e auditado.`;
      }
    }
    revalidatePath("/operacional/compras"); return { status: "success", message: receipt };
  } catch { return { status: "error", message: "Não foi possível concluir a operação." }; }
}

export async function updatePurchaseOrderAction(_: ActionState, form: FormData): Promise<ActionState> {
  try {
    const client = await operationalClient(); const tenantId = value(form, "tenant_id", 36); const orderId = value(form, "purchase_order_id", 36); const supplierId = value(form, "supplier_id", 36); const id = requestId(form); const items = purchaseItems(form);
    if (!client || !UUID.test(tenantId) || !UUID.test(orderId) || !UUID.test(supplierId) || !id || !items) return { status: "error", message: "Pedido inválido. Informe fornecedor e pelo menos um produto com quantidade e preço válidos." };
    const { error } = await client.rpc("operational_update_purchase_order", { p_tenant_id: tenantId, p_purchase_order_id: orderId, p_supplier_id: supplierId, p_items: items, p_notes: value(form, "notes", 1000) || null, p_request_id: id });
    if (error) return { status: "error", message: "Não foi possível editar o pedido. Somente rascunhos autorizados podem ser alterados." };
    revalidatePath("/operacional/compras"); return { status: "success", message: "Pedido em rascunho atualizado e auditado." };
  } catch { return { status: "error", message: "Não foi possível concluir a operação." }; }
}

export async function recordInventoryMovementAction(_: ActionState, form: FormData): Promise<ActionState> {
  try {
    const client = await operationalClient(); const tenantId = value(form, "tenant_id", 36); const branchId = value(form, "branch_id", 36); const itemId = value(form, "item_id", 36); const id = requestId(form);
    const type = value(form, "movement_type", 24); const quantity = decimal(value(form, "quantity", 32));
    if (!client || !UUID.test(tenantId) || !UUID.test(branchId) || !UUID.test(itemId) || !id || !["initial", "entry", "exit", "adjustment_positive", "adjustment_negative"].includes(type) || quantity === null || quantity <= 0) return { status: "error", message: "Ação indisponível ou dados inválidos." };
    const { error } = await client.rpc("operational_record_inventory_movement", { p_tenant_id: tenantId, p_branch_id: branchId, p_item_id: itemId, p_movement_type: type, p_quantity: quantity, p_request_id: id, p_reference_note: value(form, "reference_note", 500) || null });
    if (error) return { status: "error", message: "Movimento recusado. Saldo negativo, duplicidade ou falta de autorização não são aceitos." };
    revalidatePath("/operacional/estoque"); return { status: "success", message: "Movimento registrado e auditado." };
  } catch { return { status: "error", message: "Não foi possível concluir a operação." }; }
}

export async function createInventoryTransferAction(_: ActionState, form: FormData): Promise<ActionState> {
  try {
    const client = await operationalClient(); const tenantId = value(form, "tenant_id", 36); const sourceBranchId = value(form, "source_branch_id", 36); const destinationBranchId = value(form, "destination_branch_id", 36); const itemId = value(form, "item_id", 36); const quantity = decimal(value(form, "quantity", 32)); const id = requestId(form);
    if (!client || !UUID.test(tenantId) || !UUID.test(sourceBranchId) || !UUID.test(destinationBranchId) || !UUID.test(itemId) || !id || quantity === null || quantity <= 0) return { status: "error", message: "Informe origem, destino, produto e quantidade válidos." };
    const { error } = await client.rpc("operational_create_inventory_transfer", { p_tenant_id: tenantId, p_source_branch_id: sourceBranchId, p_destination_branch_id: destinationBranchId, p_item_id: itemId, p_quantity: quantity, p_reference_note: value(form, "reference_note", 500) || null, p_request_id: id });
    if (error) return { status: "error", message: "Transferência recusada. A operação exige acesso às duas filiais, saldo suficiente e identificação idempotente." };
    revalidatePath("/operacional/estoque"); return { status: "success", message: "Transferência registrada de forma atômica e auditada." };
  } catch { return { status: "error", message: "Não foi possível concluir a operação." }; }
}

export async function createInventoryCountAction(_: ActionState, form: FormData): Promise<ActionState> {
  try {
    const client = await operationalClient(); const tenantId = value(form, "tenant_id", 36); const branchId = value(form, "branch_id", 36); const id = requestId(form);
    if (!client || !UUID.test(tenantId) || !UUID.test(branchId) || !id) return { status: "error", message: "Ação indisponível ou dados inválidos." };
    const { data, error } = await client.rpc("operational_create_inventory_count", { p_tenant_id: tenantId, p_branch_id: branchId, p_notes: value(form, "notes", 1000) || null, p_request_id: id });
    if (error || typeof data !== "string" || !UUID.test(data)) return { status: "error", message: "Não foi possível abrir o inventário. Empresa, filial e autorização são validadas pelo banco." };
    revalidatePath("/operacional/estoque"); return { status: "success", message: "Inventário físico aberto e auditado. Selecione-o em MI04 para registrar as contagens." };
  } catch { return { status: "error", message: "Não foi possível concluir a operação." }; }
}

export async function recordInventoryCountAction(_: ActionState, form: FormData): Promise<ActionState> {
  try {
    const client = await operationalClient(); const tenantId = value(form, "tenant_id", 36); const sessionId = value(form, "session_id", 36); const itemId = value(form, "item_id", 36); const quantity = decimal(value(form, "counted_quantity", 32));
    if (!client || !UUID.test(tenantId) || !UUID.test(sessionId) || !UUID.test(itemId) || quantity === null) return { status: "error", message: "Informe inventário, produto e contagem válidos." };
    const { data, error } = await client.rpc("operational_record_inventory_count", { p_tenant_id: tenantId, p_session_id: sessionId, p_item_id: itemId, p_counted_quantity: quantity });
    if (error || data !== "recorded") return { status: "error", message: "Não foi possível registrar a contagem. Somente inventários abertos e produtos ativos são aceitos." };
    revalidatePath("/operacional/estoque"); return { status: "success", message: "Contagem registrada; nenhum ajuste foi aplicado ainda." };
  } catch { return { status: "error", message: "Não foi possível concluir a operação." }; }
}

export async function postInventoryCountAction(_: ActionState, form: FormData): Promise<ActionState> {
  try {
    const client = await operationalClient(); const tenantId = value(form, "tenant_id", 36); const sessionId = value(form, "session_id", 36);
    if (!client || !UUID.test(tenantId) || !UUID.test(sessionId)) return { status: "error", message: "Ação indisponível ou inventário inválido." };
    const { data, error } = await client.rpc("operational_post_inventory_count", { p_tenant_id: tenantId, p_session_id: sessionId });
    if (error || !["posted", "unchanged"].includes(typeof data === "string" ? data : "")) return { status: "error", message: "Não foi possível aplicar o inventário. Diferenças são recalculadas sob bloqueio pelo banco." };
    revalidatePath("/operacional/estoque"); return { status: "success", message: data === "posted" ? "Inventário aplicado e auditado." : "Este inventário já estava aplicado; nenhum ajuste foi repetido." };
  } catch { return { status: "error", message: "Não foi possível concluir a operação." }; }
}

export async function createWorkOrderAction(_: ActionState, form: FormData): Promise<ActionState> {
  try {
    const client = await operationalClient();
    const tenantId = value(form, "tenant_id", 36); const branchId = value(form, "branch_id", 36);
    const customerId = value(form, "customer_id", 36); const id = requestId(form); const problem = value(form, "problem_description", 4000);
    if (!client || !UUID.test(tenantId) || !UUID.test(branchId) || !UUID.test(customerId) || !id || !problem) return { status: "error", message: "Informe cliente e descrição do problema. A autorização será verificada pelo banco." };
    const { error } = await client.rpc("operational_create_work_order", { p_tenant_id: tenantId, p_branch_id: branchId, p_customer_id: customerId, p_equipment_description: value(form, "equipment_description", 500) || null, p_problem_description: problem, p_request_id: id });
    if (error) return { status: "error", message: "Não foi possível abrir a O.S. Empresa, filial, transação e permissão são validadas pelo banco." };
    revalidatePath("/operacional/ordens-servico"); return { status: "success", message: "Ordem de serviço aberta e auditada." };
  } catch { return { status: "error", message: "Não foi possível concluir a operação." }; }
}

export async function updateWorkOrderAction(_: ActionState, form: FormData): Promise<ActionState> {
  try {
    const client = await operationalClient(); const tenantId = value(form, "tenant_id", 36); const workOrderId = value(form, "work_order_id", 36); const id = requestId(form); const lines = workOrderLines(form);
    if (!client || !UUID.test(tenantId) || !UUID.test(workOrderId) || !id || !lines) return { status: "error", message: "Linhas inválidas. Serviços e peças precisam ter quantidade, preço e desconto válidos." };
    const { error } = await client.rpc("operational_update_work_order", { p_tenant_id: tenantId, p_work_order_id: workOrderId, p_diagnosis: value(form, "diagnosis", 4000) || null, p_lines: lines, p_request_id: id });
    if (error) return { status: "error", message: "Não foi possível atualizar a O.S. Reservas ativas, permissões e itens são conferidos pelo banco." };
    revalidatePath("/operacional/ordens-servico"); return { status: "success", message: "O.S. atualizada e auditada." };
  } catch { return { status: "error", message: "Não foi possível concluir a operação." }; }
}

export async function reserveWorkOrderPartsAction(_: ActionState, form: FormData): Promise<ActionState> {
  try {
    const client = await operationalClient(); const tenantId = value(form, "tenant_id", 36); const workOrderId = value(form, "work_order_id", 36);
    if (!client || !UUID.test(tenantId) || !UUID.test(workOrderId)) return { status: "error", message: "Ação indisponível ou ordem inválida." };
    const { data, error } = await client.rpc("operational_reserve_work_order_parts", { p_tenant_id: tenantId, p_work_order_id: workOrderId });
    if (error || data !== "reserved") return { status: "error", message: "Não foi possível reservar as peças. O saldo disponível e a autorização continuam protegidos." };
    revalidatePath("/operacional/ordens-servico"); return { status: "success", message: "Peças reservadas; nenhum saldo foi baixado." };
  } catch { return { status: "error", message: "Não foi possível concluir a operação." }; }
}

export async function closeWorkOrderAction(_: ActionState, form: FormData): Promise<ActionState> {
  try {
    const client = await operationalClient(); const tenantId = value(form, "tenant_id", 36); const workOrderId = value(form, "work_order_id", 36);
    if (!client || !UUID.test(tenantId) || !UUID.test(workOrderId)) return { status: "error", message: "Ação indisponível ou ordem inválida." };
    const { data, error } = await client.rpc("operational_close_work_order", { p_tenant_id: tenantId, p_work_order_id: workOrderId });
    if (error || data !== "closed") return { status: "error", message: "Não foi possível encerrar a O.S. Peças sem reserva não são consumidas." };
    revalidatePath("/operacional/ordens-servico"); revalidatePath("/operacional/estoque"); return { status: "success", message: "O.S. encerrada; o consumo de peças foi registrado uma única vez." };
  } catch { return { status: "error", message: "Não foi possível concluir a operação." }; }
}

export async function reverseWorkOrderConsumptionAction(_: ActionState, form: FormData): Promise<ActionState> {
  try {
    const client = await operationalClient(); const tenantId = value(form, "tenant_id", 36); const workOrderId = value(form, "work_order_id", 36);
    if (!client || !UUID.test(tenantId) || !UUID.test(workOrderId)) return { status: "error", message: "Ação indisponível ou ordem inválida." };
    const { data, error } = await client.rpc("operational_reverse_work_order_consumption", { p_tenant_id: tenantId, p_work_order_id: workOrderId });
    if (error || data !== "reversed") return { status: "error", message: "Não foi possível estornar a O.S. Apenas consumo já encerrado pode ser revertido." };
    revalidatePath("/operacional/ordens-servico"); revalidatePath("/operacional/estoque"); return { status: "success", message: "Consumo estornado e auditado." };
  } catch { return { status: "error", message: "Não foi possível concluir a operação." }; }
}

export async function setOperationalMembershipStatusAction(_: ActionState, form: FormData): Promise<ActionState> {
  try {
    const client = await operationalClient();
    const tenantId = value(form, "tenant_id", 36); const membershipId = value(form, "membership_id", 36); const status = value(form, "status", 16);
    if (!client || !UUID.test(tenantId) || !UUID.test(membershipId) || !["suspended", "revoked"].includes(status)) return { status: "error", message: "Ação indisponível ou dados inválidos." };
    const { data, error } = await client.rpc("company_set_membership_status", { p_tenant_id: tenantId, p_membership_id: membershipId, p_status: status });
    if (error || data !== status) return { status: "error", message: "O vínculo não foi alterado. A operação exige permissão empresarial e não permite autoalteração." };
    revalidatePath("/operacional/equipe"); revalidatePath("/dashboard");
    return { status: "success", message: status === "suspended" ? "Vínculo suspenso e auditado." : "Vínculo revogado e auditado." };
  } catch { return { status: "error", message: "Não foi possível concluir a operação." }; }
}

export async function createEmployeeInvitationAction(_: EmployeeInvitationActionState, form: FormData): Promise<EmployeeInvitationActionState> {
  try {
    const authAdmin = authInvitationsEnabled() ? createAuthAdminClient() : null;
    if (authInvitationsEnabled() && !authAdmin) return { status: "error", message: "O envio de ativação não está configurado neste ambiente. Nenhum convite foi criado." };
    const client = await operationalClient();
    const tenantId = value(form, "tenant_id", 36); const recipientEmail = value(form, "recipient_email", 254).toLowerCase();
    const id = requestId(form); const branchIds = employeeBranchIds(form);
    if (!client || !UUID.test(tenantId) || !id || !branchIds || recipientEmail.length > 254 || !/^[^\s@]+@[^\s@]+\.[^\s@]+$/.test(recipientEmail)) {
      return { status: "error", message: "Informe e-mail, ao menos uma filial autorizada e dados válidos." };
    }
    const { data, error } = await client.rpc("company_create_employee_invitation", {
      p_tenant_id: tenantId, p_recipient_email: recipientEmail, p_branch_ids: branchIds, p_request_id: id,
    });
    if (error || !Array.isArray(data) || data.length !== 1) return { status: "error", message: "O convite não foi emitido. A permissão da empresa e as filiais são verificadas pelo banco." };
    const result = data[0] as { invitation_token?: unknown; expires_at?: unknown };
    if (typeof result.invitation_token !== "string" || !TOKEN.test(result.invitation_token) || typeof result.expires_at !== "string") {
      return { status: "error", message: "O convite não foi confirmado. Nenhum link foi exibido." };
    }
    const inviteUrl = new URL("/convites/funcionario/aceitar", getSiteUrl());
    inviteUrl.hash = new URLSearchParams({ token: result.invitation_token }).toString();
    if (authAdmin) {
      const { error: deliveryError } = await authAdmin.auth.admin.inviteUserByEmail(recipientEmail, {
        redirectTo: getAuthActivationRedirectUrl(AUTH_ACTIVATION_FLOWS.employeeInvite),
      });
      if (deliveryError) {
        return { status: "error", message: "O convite foi registrado, mas a ativação por e-mail não foi confirmada. Nenhum vínculo foi criado; revogue e reenvie após conferir a configuração de e-mail.", invitationLink: inviteUrl.toString(), expiresAt: result.expires_at };
      }
      revalidatePath("/operacional/equipe");
      return { status: "success", message: "Convite registrado e ativação enviada por e-mail. O vínculo continuará pendente até a aprovação empresarial.", expiresAt: result.expires_at };
    }
    revalidatePath("/operacional/equipe");
    return { status: "success", message: "Convite criado. Copie o link agora e envie somente ao destinatário por um canal seguro.", invitationLink: inviteUrl.toString(), expiresAt: result.expires_at };
  } catch { return { status: "error", message: "Não foi possível concluir a emissão do convite." }; }
}

export async function revokeEmployeeInvitationAction(_: ActionState, form: FormData): Promise<ActionState> {
  try {
    const client = await operationalClient(); const tenantId = value(form, "tenant_id", 36); const invitationId = value(form, "invitation_id", 36);
    if (!client || !UUID.test(tenantId) || !UUID.test(invitationId)) return { status: "error", message: "Ação indisponível ou convite inválido." };
    const { data, error } = await client.rpc("company_revoke_employee_invitation", { p_tenant_id: tenantId, p_invitation_id: invitationId });
    if (error || data !== "revoked") return { status: "error", message: "O convite não foi revogado. Atualize a lista antes de tentar novamente." };
    revalidatePath("/operacional/equipe"); return { status: "success", message: "Convite revogado e auditado." };
  } catch { return { status: "error", message: "Não foi possível concluir a revogação." }; }
}

export async function activateEmployeeMembershipAction(_: ActionState, form: FormData): Promise<ActionState> {
  try {
    const client = await operationalClient(); const tenantId = value(form, "tenant_id", 36); const membershipId = value(form, "membership_id", 36);
    if (!client || !UUID.test(tenantId) || !UUID.test(membershipId)) return { status: "error", message: "Ação indisponível ou vínculo inválido." };
    const { data, error } = await client.rpc("company_activate_employee_membership", { p_tenant_id: tenantId, p_membership_id: membershipId });
    if (error || data !== "active") return { status: "error", message: "O vínculo não foi ativado. A ativação exige uma filial ativa e autorização empresarial." };
    revalidatePath("/operacional/equipe"); revalidatePath("/dashboard"); return { status: "success", message: "Vínculo ativado e auditado." };
  } catch { return { status: "error", message: "Não foi possível concluir a ativação." }; }
}

export async function reactivateEmployeeMembershipAction(_: ActionState, form: FormData): Promise<ActionState> {
  try {
    const client = await operationalClient(); const tenantId = value(form, "tenant_id", 36); const membershipId = value(form, "membership_id", 36);
    if (!client || !UUID.test(tenantId) || !UUID.test(membershipId)) return { status: "error", message: "Ação indisponível ou vínculo inválido." };
    const { data, error } = await client.rpc("company_reactivate_employee_membership", { p_tenant_id: tenantId, p_membership_id: membershipId });
    if (error || data !== "active") return { status: "error", message: "O vínculo não foi reativado. Uma filial ativa e a autorização empresarial são obrigatórias." };
    revalidatePath("/operacional/equipe"); revalidatePath("/dashboard"); return { status: "success", message: "Vínculo reativado e auditado." };
  } catch { return { status: "error", message: "Não foi possível concluir a reativação." }; }
}

export async function setOperationalMembershipRoleAction(_: ActionState, form: FormData): Promise<ActionState> {
  try {
    const client = await operationalClient(); const tenantId = value(form, "tenant_id", 36); const membershipId = value(form, "membership_id", 36);
    const roleKey = value(form, "role_key", 64); const operation = value(form, "operation", 16); const branchId = value(form, "branch_id", 36) || null;
    const roles = ["company_manager", "branch_supervisor", "branch_operator"];
    if (!client || !UUID.test(tenantId) || !UUID.test(membershipId) || !roles.includes(roleKey) || !["assign", "revoke"].includes(operation) || (branchId && !UUID.test(branchId))) {
      return { status: "error", message: "Ação indisponível ou dados de papel inválidos." };
    }
    const rpc = operation === "assign" ? "assign_company_membership_role" : "revoke_company_membership_role";
    const { data, error } = await client.rpc(rpc, { p_tenant_id: tenantId, p_membership_id: membershipId, p_role_key: roleKey, p_branch_id: branchId });
    const expected = operation === "assign" ? "assigned" : "revoked";
    if (error || data !== expected) return { status: "error", message: "A alteração de papel foi recusada. O banco bloqueia autoelevação e delegação acima da autoridade efetiva." };
    revalidatePath("/operacional/equipe"); return { status: "success", message: operation === "assign" ? "Papel atribuído e auditado." : "Papel revogado e auditado." };
  } catch { return { status: "error", message: "Não foi possível concluir a alteração de papel." }; }
}

export async function setOperationalBranchAccessAction(_: ActionState, form: FormData): Promise<ActionState> {
  try {
    const client = await operationalClient(); const tenantId = value(form, "tenant_id", 36); const membershipId = value(form, "membership_id", 36); const branchId = value(form, "branch_id", 36); const status = value(form, "status", 16);
    if (!client || !UUID.test(tenantId) || !UUID.test(membershipId) || !UUID.test(branchId) || !["active", "revoked"].includes(status)) return { status: "error", message: "Ação indisponível ou filial inválida." };
    const { data, error } = await client.rpc("set_company_member_branch_access", { p_tenant_id: tenantId, p_membership_id: membershipId, p_branch_id: branchId, p_status: status });
    if (error || data !== status) return { status: "error", message: "O acesso de filial não foi alterado. A filial e a autoridade do solicitante são verificadas pelo banco." };
    revalidatePath("/operacional/equipe"); revalidatePath("/dashboard"); return { status: "success", message: status === "active" ? "Filial autorizada e auditada." : "Acesso à filial revogado e auditado." };
  } catch { return { status: "error", message: "Não foi possível concluir a alteração de filial." }; }
}

export async function acceptEmployeeInvitationAction(_: EmployeeInvitationAcceptState, form: FormData): Promise<EmployeeInvitationAcceptState> {
  const token = value(form, "invitation_token", 64);
  try {
    const client = await operationalClient();
    if (!client) return { status: "error", message: "Entre na sua conta e aguarde a habilitação explícita do ambiente antes de aceitar o convite." };
    const { data, error } = TOKEN.test(token)
      ? await client.rpc("accept_company_employee_invitation", { p_invitation_token: token })
      : await client.rpc("accept_current_company_employee_invitation");
    if (error || !Array.isArray(data) || data.length !== 1) return { status: "error", message: "Não foi possível validar o convite. Nenhum vínculo foi confirmado." };
    const outcome = (data[0] as { outcome?: unknown }).outcome;
    if (outcome === "pending_approval") {
      revalidatePath("/dashboard"); return { status: "accepted", message: "Convite aceito. Seu vínculo e suas filiais aguardam aprovação do administrador da empresa." };
    }
    if (outcome === "expired") return { status: "rejected", message: "Este convite expirou. Solicite um novo convite." };
    if (outcome === "ambiguous") return { status: "rejected", message: "Há mais de um convite pendente para este e-mail. Use o link seguro correspondente ou solicite revisão ao administrador." };
    return { status: "rejected", message: "Este convite não é válido para esta conta ou já foi utilizado/revogado." };
  } catch { return { status: "error", message: "Não foi possível confirmar a aceitação. Atualize o estado antes de tentar novamente." }; }
}

export async function setOperationalEntityStatusAction(_: ActionState, form: FormData): Promise<ActionState> {
  try {
    const client = await operationalClient(); const tenantId = value(form, "tenant_id", 36); const entityId = value(form, "entity_id", 36); const entity = value(form, "entity", 16); const status = value(form, "status", 16); const id = requestId(form);
    if (!client || !UUID.test(tenantId) || !UUID.test(entityId) || !id || !["party", "item"].includes(entity) || !["active", "inactive"].includes(status)) return { status: "error", message: "Ação indisponível ou dados inválidos." };
    const result = entity === "party"
      ? await client.rpc("operational_set_business_party_status", { p_tenant_id: tenantId, p_party_id: entityId, p_status: status, p_request_id: id })
      : await client.rpc("operational_set_catalog_item_status", { p_tenant_id: tenantId, p_item_id: entityId, p_status: status, p_request_id: id });
    if (result.error || !result.data) return { status: "error", message: "A situação não foi alterada. A autorização empresarial continua obrigatória." };
    revalidatePath("/operacional/cadastros"); return { status: "success", message: status === "active" ? "Cadastro ativado e auditado." : "Cadastro inativado e auditado." };
  } catch { return { status: "error", message: "Não foi possível concluir a operação." }; }
}
