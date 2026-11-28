"use server";
import { revalidatePath } from "next/cache";
import { parseOfx, MAX_OFX_BYTES } from "@/lib/treasury/ofx";
import { uuid } from "@/lib/erp-completion/input";
import { createClient } from "@/lib/supabase/server";
import { getSupabaseEnv } from "@/lib/supabase/env";
import { isAuthorizedSupabaseTarget } from "@/lib/supabase/homologation-env";
export type OfxState = { status: "idle" | "success" | "error"; message?: string };
async function clientForImport() {
  const env = getSupabaseEnv(); if (!env || !env.operationalEnabled || !isAuthorizedSupabaseTarget(env)) return null;
  const client = await createClient(); if (!client) return null;
  const { data: { user }, error } = await client.auth.getUser(); return user && !error ? client : null;
}
const field = (form: FormData, key: string) => typeof form.get(key) === "string" ? String(form.get(key)).trim() : "";
export async function importOfxAction(_: OfxState, form: FormData): Promise<OfxState> {
  try {
    const tenant = field(form, "tenant_id"), account = field(form, "account_id"), file = form.get("file");
    if (!uuid(tenant) || !uuid(account) || !(file instanceof File) || !/\.ofx$/i.test(file.name) || file.size > MAX_OFX_BYTES) return { status: "error", message: "Selecione a conta e um arquivo .ofx de até 2 MB." };
    const client = await clientForImport(); if (!client) return { status: "error", message: "Sessão ou ambiente sem autorização operacional." };
    let statement; try { statement = parseOfx(new Uint8Array(await file.arrayBuffer())); } catch (error) { return { status: "error", message: error instanceof Error ? error.message : "Arquivo OFX inválido." }; }
    const { data, error } = await client.rpc("operational_import_ofx_statement", { p_tenant_id: tenant, p_account_id: account, p_file_sha256: statement.fileHash, p_bank_code: statement.bankId, p_branch_code: statement.branchId, p_external_account_id: statement.accountId, p_currency: statement.currency, p_from: statement.from, p_to: statement.to, p_lines: statement.transactions });
    if (error) return { status: "error", message: error.code === "23505" ? "O extrato reutiliza um identificador com dados diferentes. Confira o arquivo original do banco." : error.code === "23514" ? "O banco, a agência ou a conta do arquivo não correspondem ao vínculo configurado." : error.code === "42501" ? "Importação exige ZTR04 e ZTR06 liberadas para a filial e assinatura regular." : "Importação não concluída. Confira o vínculo bancário, os dados e as permissões." };
    revalidatePath("/operacional/bancos"); return { status: "success", message: `${data.inserted_count} movimentos importados; ${data.duplicate_count} já conhecidos. Nenhum movimento foi conciliado automaticamente.` };
  } catch { return { status: "error", message: "Não foi possível confirmar a importação. Reenvie o mesmo arquivo; duplicatas serão detectadas." }; }
}
export async function bindOfxAction(_: OfxState, form: FormData): Promise<OfxState> {
  try {
    const tenant = field(form, "tenant_id"), account = field(form, "account_id"), bank = field(form, "bank_code"), branch = field(form, "branch_code"), external = field(form, "external_account_id");
    if (!uuid(tenant) || !uuid(account) || !bank || bank.length > 32 || branch.length > 32 || !external || external.length > 128) return { status: "error", message: "Informe a identificação bancária exatamente como aparece no extrato." };
    const client = await clientForImport(); if (!client) return { status: "error", message: "Sessão sem autorização operacional." };
    const { error } = await client.rpc("operational_bind_ofx_bank_account", { p_tenant_id: tenant, p_account_id: account, p_bank_code: bank, p_branch_code: branch, p_external_account_id: external });
    if (error) return { status: "error", message: "Vínculo não salvo. Verifique ZTR02 e a identificação; contas com extratos importados não podem trocar o vínculo." };
    revalidatePath("/operacional/bancos"); return { status: "success", message: "Identificação bancária vinculada e auditada." };
  } catch { return { status: "error", message: "Não foi possível salvar o vínculo. Tente novamente." }; }
}
export async function confirmOfxAction(_: OfxState, form: FormData): Promise<OfxState> {
  try {
    const tenant = field(form, "tenant_id"), line = field(form, "line_id"), movement = field(form, "movement_id");
    if (![tenant, line, movement].every(uuid)) return { status: "error", message: "Selecione um movimento para conciliar." };
    const client = await clientForImport(); if (!client) return { status: "error", message: "Sessão sem autorização operacional." };
    const { error } = await client.rpc("operational_confirm_ofx_reconciliation", { p_tenant_id: tenant, p_line_id: line, p_movement_id: movement, p_allow_date_difference: field(form, "allow_date_difference") === "on" });
    if (error) return { status: "error", message: "Conciliação não confirmada. Verifique conta, valor, datas e se outro usuário já conciliou os registros. Datas diferentes exigem confirmação explícita." };
    revalidatePath("/operacional/bancos"); return { status: "success", message: "Conciliação confirmada e auditada." };
  } catch { return { status: "error", message: "Não foi possível confirmar a conciliação. Atualize antes de tentar novamente." }; }
}
