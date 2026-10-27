export type CompanyMetadataDraft = {
  legalName: string;
  tradeName: string | null;
  cnpj: string | null;
  contactEmail: string | null;
  contactPhone: string | null;
};

export type BranchMetadataDraft = {
  companyId: string;
  code: string;
  name: string;
  cnpj: string | null;
  address: string | null;
  isHeadquarters: boolean;
};

export type Validation<T> = { valid: true; value: T } | { valid: false; field: string; message: string };

function digits(value: string) { return value.replace(/\D/g, ""); }
function optional(value: unknown) { return typeof value === "string" && value.trim() ? value.trim() : null; }
function isValidCnpj(value: string) {
  const cnpj = digits(value);
  if (cnpj.length !== 14 || /^(\d)\1{13}$/.test(cnpj)) return false;
  const check = (part: string, weights: number[]) => {
    const total = [...part].reduce((sum, digit, index) => sum + Number(digit) * weights[index], 0);
    const remainder = total % 11;
    return remainder < 2 ? 0 : 11 - remainder;
  };
  const first = check(cnpj.slice(0, 12), [5, 4, 3, 2, 9, 8, 7, 6, 5, 4, 3, 2]);
  const second = check(cnpj.slice(0, 12) + first, [6, 5, 4, 3, 2, 9, 8, 7, 6, 5, 4, 3, 2]);
  return cnpj.endsWith(`${first}${second}`);
}

function normalizedCnpj(value: unknown): Validation<string | null> {
  const raw = optional(value);
  if (!raw) return { valid: true, value: null };
  if (!/^[0-9./\-\s]+$/.test(raw)) return { valid: false, field: "cnpj", message: "CNPJ contém caracteres inválidos." };
  if (!isValidCnpj(raw)) return { valid: false, field: "cnpj", message: "Informe um CNPJ válido com dígitos verificadores corretos." };
  return { valid: true, value: digits(raw) };
}

export function validateCompanyMetadata(input: Record<string, unknown>): Validation<CompanyMetadataDraft> {
  const legalName = typeof input.legalName === "string" ? input.legalName.trim() : "";
  const tradeName = optional(input.tradeName);
  const email = optional(input.contactEmail)?.toLowerCase() ?? null;
  const phoneInput = optional(input.contactPhone);
  const cnpj = normalizedCnpj(input.cnpj);
  if (legalName.length < 1 || [...legalName].length > 200) return { valid: false, field: "legalName", message: "Razão social é obrigatória e deve ter até 200 caracteres." };
  if (tradeName && [...tradeName].length > 200) return { valid: false, field: "tradeName", message: "Nome fantasia deve ter até 200 caracteres." };
  if (!cnpj.valid) return cnpj;
  if (email && (email.length > 254 || !/^[^\s@]+@[^\s@]+\.[^\s@]+$/.test(email))) return { valid: false, field: "contactEmail", message: "Informe um e-mail de contato válido." };
  const phone = phoneInput ? digits(phoneInput) : null;
  if (phone && (phone.length < 8 || phone.length > 15)) return { valid: false, field: "contactPhone", message: "Telefone deve conter entre 8 e 15 dígitos." };
  return { valid: true, value: { legalName, tradeName, cnpj: cnpj.value, contactEmail: email, contactPhone: phone } };
}

export function validateBranchMetadata(input: Record<string, unknown>): Validation<BranchMetadataDraft> {
  const companyId = typeof input.companyId === "string" ? input.companyId.toLowerCase() : "";
  const code = typeof input.code === "string" ? input.code.trim().toUpperCase() : "";
  const name = typeof input.name === "string" ? input.name.trim() : "";
  const address = optional(input.address);
  const cnpj = normalizedCnpj(input.cnpj);
  const isHeadquarters = input.isHeadquarters === true || input.isHeadquarters === "true";
  if (!/^[0-9a-f]{8}-[0-9a-f]{4}-[1-8][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/.test(companyId)) return { valid: false, field: "companyId", message: "Selecione uma empresa válida." };
  if (!code || [...code].length > 40 || !/^[A-Z0-9][A-Z0-9._-]*$/.test(code)) return { valid: false, field: "code", message: "Código obrigatório: até 40 caracteres alfanuméricos, ponto, hífen ou sublinhado." };
  if (!name || [...name].length > 160) return { valid: false, field: "name", message: "Nome obrigatório e limitado a 160 caracteres." };
  if (!cnpj.valid) return cnpj;
  if (address && [...address].length > 500) return { valid: false, field: "address", message: "Endereço deve ter até 500 caracteres." };
  return { valid: true, value: { companyId, code, name, cnpj: cnpj.value, address, isHeadquarters } };
}

export function normalizeStatus(value: unknown, allowed: readonly string[]): string | null {
  return typeof value === "string" && allowed.includes(value) ? value : null;
}
