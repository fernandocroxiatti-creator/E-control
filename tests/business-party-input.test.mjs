import assert from "node:assert/strict";
import test from "node:test";
import { businessPartyRpcMessage, prepareBusinessParty } from "../lib/operational/business-party-input.ts";

const valid = { partyType: "customer", legalName: "Cliente de teste", documentNumber: "12.345.678/0001-95", contactEmail: "TESTE@EXEMPLO.COM", contactPhone: "+55 (11) 99999-9999" };

test("prepara um cliente válido sem perder tipo, normalizando documento, e-mail e telefone", () => {
  const result = prepareBusinessParty(valid);
  assert.ok("value" in result);
  assert.deepEqual(result.value, { partyType: "customer", legalName: "Cliente de teste", documentNumber: "12345678000195", contactEmail: "teste@exemplo.com", contactPhone: "+5511999999999" });
});

test("rejeita entrada inválida antes de chamar a RPC", () => {
  assert.match(prepareBusinessParty({ ...valid, documentNumber: "123" }).error, /CPF\/CNPJ/);
  assert.match(prepareBusinessParty({ ...valid, contactEmail: "invalido" }).error, /e-mail/);
  assert.match(prepareBusinessParty({ ...valid, partyType: "admin" }).error, /tipo/);
});

test("classifica autorização, duplicidade, validação e erro inesperado sem vazar detalhes da RPC", () => {
  assert.match(businessPartyRpcMessage({ code: "42501", message: "private" }, "BP-12345678"), /Acesso negado/);
  assert.match(businessPartyRpcMessage({ code: "23505", message: "private" }, "BP-12345678"), /conflita/);
  assert.match(businessPartyRpcMessage({ code: "22023", message: "private" }, "BP-12345678"), /dados/);
  const unexpected = businessPartyRpcMessage({ code: "XX000", message: "private" }, "BP-12345678");
  assert.match(unexpected, /BP-12345678/);
  assert.doesNotMatch(unexpected, /private/);
});
