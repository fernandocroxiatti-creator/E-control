import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { resolve } from "node:path";
import { fileURLToPath } from "node:url";
import test from "node:test";
import { validateBranchMetadata, validateCompanyMetadata } from "../lib/companies/management-validation.ts";

const root = resolve(fileURLToPath(new URL("..", import.meta.url)));
const read = (path) => readFileSync(resolve(root, path), "utf8");
const sql = read("supabase/migrations/20261026100000_master_company_branch_management.sql");
const actions = read("app/actions/master-company-v2.ts");
const masterDataUi = read("app/master/master-data-ui.tsx");
const managementTables = read("app/master/company-management-tables.tsx");
const styles = read("app/globals.css");

test("company validation requires legal name, accepts optional CNPJ, and normalizes business contact data", () => {
  assert.deepEqual(validateCompanyMetadata({ legalName: "  Empresa Exemplo Ltda ", tradeName: "  Exemplo ", cnpj: "11.222.333/0001-81", contactEmail: " SAC@EXEMPLO.COM ", contactPhone: "+55 (11) 99999-1234 " }), {
    valid: true,
    value: { legalName: "Empresa Exemplo Ltda", tradeName: "Exemplo", cnpj: "11222333000181", contactEmail: "sac@exemplo.com", contactPhone: "5511999991234" },
  });
  assert.equal(validateCompanyMetadata({ legalName: " " }).valid, false);
  assert.deepEqual(validateCompanyMetadata({ legalName: "Empresa sem CNPJ" }), {
    valid: true,
    value: { legalName: "Empresa sem CNPJ", tradeName: null, cnpj: null, contactEmail: null, contactPhone: null },
  });
  assert.equal(validateCompanyMetadata({ legalName: "Empresa", cnpj: "11.111.111/1111-11" }).valid, false);
  assert.equal(validateCompanyMetadata({ legalName: "Empresa", cnpj: "fake 11.222.333/0001-81" }).valid, false);
  assert.equal(validateCompanyMetadata({ legalName: "Empresa", contactEmail: "invalid" }).valid, false);
  assert.equal(validateCompanyMetadata({ legalName: "Empresa", contactPhone: "123" }).valid, false);
});

test("branch validation requires a valid company selector and normalizes constrained metadata", () => {
  assert.deepEqual(validateBranchMetadata({ companyId: "11111111-1111-4111-8111-111111111111", code: " sp-01 ", name: " Unidade Centro ", cnpj: "11.222.333/0001-81", address: " Rua A, 10 ", isHeadquarters: "true" }), {
    valid: true,
    value: { companyId: "11111111-1111-4111-8111-111111111111", code: "SP-01", name: "Unidade Centro", cnpj: "11222333000181", address: "Rua A, 10", isHeadquarters: true },
  });
  assert.equal(validateBranchMetadata({ companyId: "not-a-uuid", code: "01", name: "Filial" }).valid, false);
  assert.equal(validateBranchMetadata({ companyId: "11111111-1111-4111-8111-111111111111", code: "01", name: "Filial", cnpj: "invalid" }).valid, false);
});

test("V2 migration is transaction-wrapped and requires foundation, Master read API, RLS and no direct API writes", () => {
  assert.match(sql, /^-- Admin Master V2[\s\S]*?begin;[\s\S]*?commit;\s*$/i);
  assert.match(sql, /master_admin_list_companies\(text,text,integer,integer\)/);
  assert.match(sql, /master_admin_list_branches\(uuid\)/);
  assert.match(sql, /relrowsecurity and relforcerowsecurity/);
  assert.match(sql, /has_table_privilege\(api_role\.role_name,protected\.table_name,'INSERT'\)/);
  assert.match(sql, /Existing branch codes collide after normalization/);
  assert.match(sql, /companies_cnpj_unique/);
  assert.match(sql, /branches_cnpj_unique/);
  assert.match(sql, /branches_tenant_code_normalized_unique/);
  assert.match(sql, /branches_one_headquarters_per_company/);
});

test("V2 write RPCs derive actor from Auth, recheck persistent Master, serialize retries and audit atomically", () => {
  for (const name of ["master_create_company_v2", "master_update_company_v2", "master_set_company_status_v2", "master_create_branch_v2", "master_update_branch_v2", "master_set_branch_status_v2"]) {
    const start = sql.indexOf(`create function public.${name}`);
    const end = sql.indexOf("$function$;", start);
    assert.ok(start >= 0 && end > start, `${name} must exist`);
    const body = sql.slice(start, end);
    assert.match(body, /security definer[\s\S]*set search_path = ''[\s\S]*set row_security = off/i);
    assert.match(body, /app_private\.assert_current_master\(\)/);
    assert.match(body, /app_private\.assert_current_master\(\)/, `${name} must recheck the authenticated Master in SQL`);
    assert.match(body, /master_management_requests/);
    assert.match(body, /write_provisioning_audit/);
    assert.doesNotMatch(body, /p_actor_user_id|p_actor_id|service_role/i);
  }
  assert.match(sql, /pg_advisory_xact_lock/);
  assert.match(sql, /Request key was already used for different data/);
  assert.match(sql, /actor_id:=auth\.uid\(\)/);
  assert.match(sql, /is_current_user_master\(\) is distinct from true/);
});

test("branch RPC binds company to the selected parent and never changes tenant_id", () => {
  const createStart = sql.indexOf("create function public.master_create_branch_v2");
  const updateStart = sql.indexOf("create function public.master_update_branch_v2");
  const createBody = sql.slice(createStart, sql.indexOf("$function$;", createStart));
  const updateBody = sql.slice(updateStart, sql.indexOf("$function$;", updateStart));
  assert.match(createBody, /from public\.companies where id=p_company_id and status='active' for share/);
  assert.match(createBody, /insert into public\.branches\(tenant_id,code,name/);
  assert.match(createBody, /code_value !~ '\^\[A-Z0-9\]\[A-Z0-9\._-\]\*\$'/);
  assert.match(updateBody, /from public\.branches where id=p_branch_id for update/);
  assert.match(updateBody, /code_value !~ '\^\[A-Z0-9\]\[A-Z0-9\._-\]\*\$'/);
  assert.doesNotMatch(updateBody.slice(updateBody.indexOf("update public.branches")), /set[^;]*tenant_id\s*=/i);
  assert.match(sql, /Closed company status is terminal/);
  assert.match(sql, /Cannot activate a branch of a non-active company/);
  assert.match(sql, /from public\.companies c where c\.id=tenant_id and c\.status='active' for share/);
});

test("RPC ACLs expose only approved calls to authenticated and preserve direct-table isolation", () => {
  assert.match(sql, /revoke all on function public\.master_create_company_v2[\s\S]*from public,anon,authenticated,service_role/);
  assert.match(sql, /grant execute on function public\.master_create_company_v2[\s\S]*to authenticated/);
  assert.match(sql, /has_function_privilege\('anon',function_oid,'EXECUTE'\)/);
  assert.match(sql, /has_function_privilege\('service_role',function_oid,'EXECUTE'\)/);
  assert.match(sql, /aclexplode\(coalesce\(p\.proacl,pg_catalog\.acldefault\('f',p\.proowner\)\)\)/);
  assert.match(sql, /V2 altered direct table access or weakened forced RLS/);
  assert.doesNotMatch(sql, /grant\s+(insert|update|delete|all)\s+on\s+table\s+public\.(companies|branches)/i);
  assert.doesNotMatch(sql, /insert into public\.(company_memberships|branch_access|membership_role_assignments|role_permission_grants)/i);
});

test("Server Actions require the real Master SSR guard, exact configured target, explicit flags and DB readiness", () => {
  assert.match(actions, /requireMasterUser\(\)/);
  assert.match(actions, /isAuthorizedSupabaseTarget\(env\)/);
  assert.match(actions, /env\.companyManagementEnabled/);
  assert.match(actions, /env\.companyCreationEnabled/);
  assert.match(actions, /requiresCompanyCreation/);
  assert.match(actions, /master_create_company_v2[\s\S]*?\}, true\)/);
  assert.match(actions, /master_admin_management_ready/);
  assert.doesNotMatch(actions, /service_role|SUPABASE_SERVICE_ROLE_KEY|p_actor_user_id|actor_user_id/);
  assert.match(actions, /validateCompanyMetadata/);
  assert.match(actions, /validateBranchMetadata/);
});

test("V2 UI exposes HML management only behind explicit local flags and per-action database readiness", () => {
  const companiesPage = read("app/master/empresas/page.tsx");
  const branchesPage = read("app/master/filiais/page.tsx");
  const env = read(".env.homologation.local");
  assert.match(companiesPage, /getMasterCompanyManagementEnabled/);
  assert.match(companiesPage, /getMasterCompanyCreationEnabled/);
  assert.match(branchesPage, /getMasterCompanyManagementEnabled/);
  assert.match(env, /^ECONTROLL_HML_COMPANY_CREATION_ENABLED=false$/m);
  assert.doesNotMatch(env, /^ECONTROLL_HML_COMPANY_MANAGEMENT_ENABLED=true$/m);
  assert.match(actions, /master_admin_management_ready/);
  assert.match(actions, /requireMasterUser\(\)/);
  assert.match(actions, /!env\.companyManagementEnabled/);
  assert.match(actions, /requiresCompanyCreation && !env\.companyCreationEnabled/);
});

test("company, branch, and audit tables retain readable spacing and keyboard-accessible horizontal scrolling", () => {
  for (const label of ["Tabela de empresas", "Tabela de filiais", "Tabela de auditoria"]) {
    assert.match(masterDataUi, new RegExp(`role="region" aria-label="${label}" tabIndex=\\{0\\}`));
  }
  assert.match(managementTables, /role="region" aria-label="Tabela de empresas" tabIndex=\{0\}/);
  assert.match(managementTables, /role="region" aria-label="Tabela de filiais" tabIndex=\{0\}/);
  assert.match(styles, /\.master-table-wrap\{[^}]*overflow-x:auto[^}]*-webkit-overflow-scrolling:touch/s);
  assert.match(styles, /\.master-table\{[^}]*min-width:100%[^}]*white-space:normal/s);
  assert.match(styles, /\.master-table--companies\{min-width:58rem\}/);
  assert.match(styles, /\.master-table--branches\{min-width:46rem\}/);
  assert.match(styles, /\.master-table--audit\{min-width:35rem\}/);
  assert.match(styles, /\.master-table th\{[^}]*padding:\.72rem \.9rem/s);
  assert.match(styles, /\.master-table td\{[^}]*padding:\.82rem \.9rem[^}]*vertical-align:top/s);
});
