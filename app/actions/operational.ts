"use server";

import { revalidatePath } from "next/cache";
import { getSupabaseEnv } from "@/lib/supabase/env";
import { isAuthorizedSupabaseTarget } from "@/lib/supabase/homologation-env";
import { createClient } from "@/lib/supabase/server";

type ActionState = { status: "idle" | "success" | "error"; message?: string };
export const operationalIdle: ActionState = { status: "idle" };
const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[1-8][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i;

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
