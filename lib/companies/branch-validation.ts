export type BranchDraft = {
  name: string;
  code: string;
  cnpj?: string;
};

export type BranchDraftValidation =
  | { valid: true; value: { name: string; code: string } }
  | { valid: false; field: "name" | "code" | "cnpj"; message: string };

function digits(value: string) {
  return value.replace(/\D/g, "");
}

export function isValidCnpj(value: string) {
  const valueDigits = digits(value);
  if (valueDigits.length !== 14 || /^(\d)\1{13}$/.test(valueDigits)) return false;
  const calculate = (base: string, weights: number[]) => {
    const sum = [...base].reduce((total, digit, index) => total + Number(digit) * weights[index], 0);
    const remainder = sum % 11;
    return remainder < 2 ? 0 : 11 - remainder;
  };
  const first = calculate(valueDigits.slice(0, 12), [5, 4, 3, 2, 9, 8, 7, 6, 5, 4, 3, 2]);
  const second = calculate(valueDigits.slice(0, 12) + first, [6, 5, 4, 3, 2, 9, 8, 7, 6, 5, 4, 3, 2]);
  return valueDigits.endsWith(`${first}${second}`);
}

/** Checks only local form constraints; it does not authorize or persist a branch. */
export function validateBranchDraft(draft: BranchDraft): BranchDraftValidation {
  const name = draft.name.trim();
  const code = draft.code.trim();
  const nameLength = [...name].length;
  const codeLength = [...code].length;

  if (nameLength < 1 || nameLength > 160) {
    return { valid: false, field: "name", message: "Informe um nome de filial entre 1 e 160 caracteres." };
  }
  if (codeLength < 1 || codeLength > 40) {
    return { valid: false, field: "code", message: "Informe um código interno entre 1 e 40 caracteres." };
  }
  if (draft.cnpj?.trim() && !isValidCnpj(draft.cnpj)) {
    return { valid: false, field: "cnpj", message: "Confira o CNPJ. A validação é local e não consulta serviços externos." };
  }

  return { valid: true, value: { name, code } };
}
