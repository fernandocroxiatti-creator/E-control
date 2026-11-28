export type BusinessPartyDraft = {
  partyType: string;
  legalName: string;
  documentNumber: string;
  contactEmail: string;
  contactPhone: string;
  tradeName?: string;
  address?: Record<string, string>;
  /** Only skips the preliminary checksum for an unchanged legacy value.
   * The database compares OLD/NEW and remains authoritative, even if forged. */
  originalDocumentNumber?: string;
};

export type PreparedBusinessParty = {
  partyType: "customer" | "supplier" | "both";
  legalName: string;
  documentNumber: string | null;
  contactEmail: string | null;
  contactPhone: string | null;
  tradeName?: string | null;
  address?: Record<string, string>;
};

type RpcError = { code?: unknown };

const EMAIL = /^[^\s@]+@[^\s@]+\.[^\s@]+$/;

export function validPartyDocument(d: string) {
  if (!/^(?:[0-9]{11}|[0-9]{14})$/.test(d) || new Set(d).size === 1) return false;
  for (let j = d.length - 1; j <= d.length; j++) {
    let total = 0;
    for (let i = 1; i < j; i++) total += Number(d[i - 1]) * (d.length === 11 ? j + 1 - i : ((j - 1 - i) % 8) + 2);
    const digit = total % 11 < 2 ? 0 : 11 - total % 11;
    if (digit !== Number(d[j - 1])) return false;
  }
  return true;
}

function compactDocument(value: string) {
  return value.replace(/\D/g, "");
}

function compactPhone(value: string) {
  const trimmed = value.trim();
  const normalized = trimmed.replace(/[^\d+]/g, "");
  return normalized.startsWith("+") ? `+${normalized.slice(1).replace(/\+/g, "")}` : normalized.replace(/\+/g, "");
}

/** Prepares only browser-entered fields. The database remains authoritative for
 * company authorization, idempotency, duplicate constraints and auditing. */
export function prepareBusinessParty(draft: BusinessPartyDraft): { value: PreparedBusinessParty } | { error: string } {
  const partyType = draft.partyType.trim();
  const legalName = draft.legalName.trim();
  const documentNumber = compactDocument(draft.documentNumber);
  const contactEmail = draft.contactEmail.trim().toLowerCase();
  const contactPhone = compactPhone(draft.contactPhone);

  if (!(["customer", "supplier", "both"] as string[]).includes(partyType)) return { error: "Selecione um tipo de cadastro válido." };
  if (legalName.length < 1 || legalName.length > 200) return { error: "Informe nome ou razão social com até 200 caracteres." };
  if (/[^0-9./\s-]/.test(draft.documentNumber) || (documentNumber && (!/^(?:\d{11}|\d{14})$/.test(documentNumber) || (documentNumber !== draft.originalDocumentNumber && !validPartyDocument(documentNumber))))) return { error: "Informe CPF/CNPJ válido, com 11 ou 14 dígitos e verificadores corretos." };
  if (contactEmail && !EMAIL.test(contactEmail)) return { error: "Informe um e-mail válido." };
  if (contactPhone.length > 40) return { error: "Telefone inválido." };

  if (draft.tradeName && draft.tradeName.trim().length > 200) return { error: "Nome fantasia deve ter até 200 caracteres." };
  if (draft.address && Object.values(draft.address).some((v) => typeof v !== "string" || v.length > 200)) return { error: "Revise os campos do endereço (até 200 caracteres cada)." };

  return {
    value: {
      partyType: partyType as PreparedBusinessParty["partyType"],
      legalName,
      documentNumber: documentNumber || null,
      contactEmail: contactEmail || null,
      contactPhone: contactPhone || null,
      ...(draft.tradeName !== undefined ? { tradeName: draft.tradeName.trim() || null } : {}),
      ...(draft.address !== undefined ? { address: draft.address } : {}),
    },
  };
}

function safeCode(error: unknown) {
  const value = typeof error === "object" && error !== null ? (error as RpcError).code : undefined;
  return typeof value === "string" && /^[A-Z0-9]{3,16}$/i.test(value) ? value.toUpperCase() : null;
}

/** Never returns database text: Supabase errors may contain user-entered data. */
export function businessPartyRpcMessage(error: unknown, diagnosticId: string) {
  switch (safeCode(error)) {
    case "42501": return "Acesso negado para cadastrar nesta empresa. Verifique BP01, o módulo MDM, a filial e o grant do seu papel.";
    case "23505": return "Já existe um cadastro que conflita com este CPF/CNPJ nesta empresa.";
    case "22023":
    case "23514": return "Os dados do cadastro não foram aceitos. Revise os campos informados.";
    default: return `Não foi possível concluir o cadastro. Tente novamente. Código de diagnóstico: ${diagnosticId}.`;
  }
}

export function businessPartyDiagnosticCode() {
  return `BP-${crypto.randomUUID().slice(0, 8)}`;
}
