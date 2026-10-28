import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { resolve } from "node:path";
import test from "node:test";
import { filterBranches, MASTER_PAGE_SIZE, paginateRows, parseMasterPage } from "../lib/master/listing.ts";

const root = resolve(import.meta.dirname, "..");
const read = (path) => readFileSync(resolve(root, path), "utf8");

test("company and branch pages paginate only validated Master RPC rows", () => {
  assert.equal(MASTER_PAGE_SIZE, 20);
  assert.equal(parseMasterPage("3"), 3);
  assert.equal(parseMasterPage("0"), 1);
  assert.equal(parseMasterPage("-1"), 1);
  assert.equal(parseMasterPage("x"), 1);
  const rows = Array.from({ length: 21 }, (_, index) => ({ id: index }));
  assert.deepEqual(paginateRows(rows, 1).rows.map((row) => row.id), Array.from({ length: 20 }, (_, index) => index));
  assert.equal(paginateRows(rows, 1).hasNext, true);
  assert.deepEqual(paginateRows(rows, 2).rows.map((row) => row.id), [20]);
  assert.equal(paginateRows(rows, 2).hasNext, false);
  const companiesPage = read("app/master/empresas/page.tsx");
  const readModel = read("lib/master/read-model.ts");
  assert.match(companiesPage, /MASTER_PAGE_SIZE \+ 1/);
  assert.match(readModel, /p_offset: offset/);
  assert.match(companiesPage, /PaginationControls/);
});

test("branch filtering remains tenant-local and never changes the database RPC contract", () => {
  const branches = [
    { code: "001", name: "Matriz", cnpj: null, address: "Centro", status: "active" },
    { code: "002", name: "Armazém", cnpj: "123", address: null, status: "inactive" },
  ];
  assert.deepEqual(filterBranches(branches, "matriz", null), [branches[0]]);
  assert.deepEqual(filterBranches(branches, "", "inactive"), [branches[1]]);
  assert.deepEqual(filterBranches(branches, "123", "inactive"), [branches[1]]);
  const page = read("app/master/filiais/page.tsx");
  assert.match(page, /getMasterBranchesV2\(empresa\)/);
  assert.match(page, /filterBranches\(branches\.data/);
  assert.match(page, /empresa.*selectedCompany\.company_id/);
  assert.match(page, /PaginationControls/);
  assert.doesNotMatch(page, /master_create_branch_v2|service_role|localStorage/);
});
