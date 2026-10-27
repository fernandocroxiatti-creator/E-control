import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { resolve } from "node:path";
import { fileURLToPath } from "node:url";
import test from "node:test";
import { isValidCnpj, validateBranchDraft } from "../lib/companies/branch-validation.ts";

const projectRoot = resolve(fileURLToPath(new URL("..", import.meta.url)));

test("trims valid branch names and codes within the database bounds", () => {
  assert.deepEqual(validateBranchDraft({ name: "  Unidade Centro ", code: "  SP-01  " }), {
    valid: true,
    value: { name: "Unidade Centro", code: "SP-01" },
  });
});

test("rejects missing or out-of-range branch names and codes", () => {
  assert.equal(validateBranchDraft({ name: " ", code: "A" }).valid, false);
  assert.equal(validateBranchDraft({ name: "x".repeat(161), code: "A" }).valid, false);
  assert.equal(validateBranchDraft({ name: "Filial", code: " " }).valid, false);
  assert.equal(validateBranchDraft({ name: "Filial", code: "x".repeat(41) }).valid, false);
});

test("validates an optional CNPJ locally without network access", () => {
  assert.equal(isValidCnpj("11.222.333/0001-81"), true);
  assert.equal(isValidCnpj("11.111.111/1111-11"), false);
  assert.equal(validateBranchDraft({ name: "Filial", code: "01", cnpj: "inválido" }).valid, false);
});

test("branch creation remains disabled and the preparation form has no write action", () => {
  const component = readFileSync(resolve(projectRoot, "app/components/companies-workspace.tsx"), "utf8");
  assert.match(component, /A gravação permanece bloqueada até existir autorização empresarial persistente/);
  assert.match(component, /type=\{isBranchForm \? "button" : "submit"\} disabled=\{isBranchForm\}/);
  assert.doesNotMatch(component, /provision_branch|master_create_branch|service_role/);
});
