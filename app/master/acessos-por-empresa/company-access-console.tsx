"use client";

import { useActionState, useEffect, useMemo, useState } from "react";
import { useRouter } from "next/navigation";
import { setCompanyScopedRolePermissionGrantAction, setCompanyTransactionAvailabilityAction } from "@/app/actions/master-access-governance";
import { masterAccessIdle } from "@/lib/master/action-state";
import type { MasterBranch, MasterCompany, MasterCompanyAccessItem, MasterCompanyScopedPermissionGrant } from "@/lib/master/read-model";

const names: Record<string, string> = {
  BP01: "Clientes e fornecedores", MM01: "Cadastro de produtos", SV01: "Cadastro de serviços",
  MIGO: "Movimentação de estoque", ME21N: "Criar pedido de compra", ME23N: "Consultar pedidos de compra",
  MM02: "Alterar produtos", MM03: "Consultar produtos", MB52: "Saldos por filial", MB51: "Histórico de estoque",
  MI01: "Iniciar inventário", MI04: "Registrar contagem", MI07: "Aplicar inventário", ZTR01: "Transferir entre filiais",
  ZGR01: "Recebimento de compra", ZIV01: "Avaliação inicial de estoque",
  ZOS01: "Criar ordem de serviço", ZOS02: "Alterar ordem de serviço", ZOS03: "Consultar ordem de serviço", ZOS04: "Encerrar ordem de serviço",
};
const modules: Record<string, string> = {
  MDM: "Cadastros", INV: "Estoque", PUR: "Compras", SAL: "Vendas", FIN: "Financeiro",
  SVC: "Serviços", SRV: "Serviços", REP: "Relatórios", ADM: "Administração",
};

function stateLabel(value: string | null) {
  if (value === "approved") return "Aprovada";
  if (value === "retired") return "Desativada";
  if (value === null) return "Indisponível";
  return "Pendente de aprovação";
}
function stateClass(value: string | null) {
  return value === "approved" ? " is-positive" : value === "retired" ? " is-negative" : "";
}
function unavailableReason(item: MasterCompanyAccessItem) {
  if (item.approval_state !== "approved") return "Aprovar a transação na página Papéis e permissões antes de disponibilizá-la para esta empresa.";
  if (item.permission_approval_state !== "approved") return "Aprovar a permissão associada na página Papéis e permissões antes de liberar o uso efetivo.";
  return "Pronta para disponibilização empresarial.";
}

function CompanyScopedGrantManager({ tenantId, branches, items, grants, ready }: {
  tenantId: string; branches: MasterBranch[]; items: MasterCompanyAccessItem[]; grants: MasterCompanyScopedPermissionGrant[]; ready: boolean;
}) {
  const [state, action, pending] = useActionState(setCompanyScopedRolePermissionGrantAction, masterAccessIdle);
  const activeBranches = branches.filter((branch) => branch.status === "active");
  const receiptPermission = items.find((item) => item.transaction_code === "ZGR01"
    && item.permission_key === "transaction.purchasing.receipt.manage"
    && item.approval_state === "approved" && item.permission_approval_state === "approved");
  const [branchId, setBranchId] = useState(activeBranches[0]?.branch_id ?? "");
  const [confirmed, setConfirmed] = useState(false);
  const selectedGrant = grants.find((grant) => grant.branch_id === branchId && grant.role_key === "company_owner" && grant.permission_key === "transaction.purchasing.receipt.manage");
  return <section className="master-company-scoped-grants">
    <header><h3>Permissões por empresa e filial</h3><p>Esta camada é aditiva, limitada à filial escolhida e não cria vínculos nem grants globais. O papel fixo para este piloto é <code>company_owner</code>.</p></header>
    {!ready ? <p className="master-panel-empty">A leitura canônica dos grants empresariais não está disponível. Nenhuma alteração pode ser enviada.</p> : !activeBranches.length || !receiptPermission ? <p className="master-panel-empty">Aprove ZGR01 e sua permissão globalmente e mantenha ao menos uma filial ativa antes de conceder o grant empresarial do piloto.</p> : <form action={action} className="master-company-scoped-grant-form">
      <input type="hidden" name="tenant_id" value={tenantId} />
      <input type="hidden" name="role_key" value="company_owner" />
      <input type="hidden" name="permission_key" value="transaction.purchasing.receipt.manage" />
      <input type="hidden" name="operation" value={selectedGrant ? "revoke" : "grant"} />
      <label>Filial<select name="branch_id" value={branchId} onChange={(event) => { setBranchId(event.target.value); setConfirmed(false); }} disabled={pending}>{activeBranches.map((branch) => <option key={branch.branch_id} value={branch.branch_id}>{branch.code} · {branch.name}</option>)}</select></label>
      <p className="master-form-help">Permissão fixa do piloto: <code>ZGR01 · transaction.purchasing.receipt.manage</code>.</p>
      <label>Justificativa auditável<textarea name="reason" minLength={10} maxLength={1000} required disabled={pending} /></label>
      <label className="master-checkbox-label"><input name="confirmed" type="checkbox" required checked={confirmed} onChange={(event) => setConfirmed(event.target.checked)} disabled={pending} /> Confirmo o escopo exato de empresa, filial, papel e permissão.</label>
      <button className="master-action" type="submit" disabled={!confirmed || pending}>{pending ? "Registrando…" : selectedGrant ? "Revogar grant empresarial" : "Conceder grant empresarial"}</button>
      {selectedGrant && <p className="master-form-help">Grant ativo desde {new Date(selectedGrant.created_at).toLocaleString("pt-BR")}. Justificativa registrada: {selectedGrant.reason}</p>}
      {state.message && <p className={`master-company-feedback ${state.status === "success" ? "is-success" : "is-error"}`} role={state.status === "success" ? "status" : "alert"}>{state.message}</p>}
    </form>}
    {grants.length > 0 && <ul className="master-company-scoped-grant-list">{grants.map((grant) => <li key={`${grant.branch_id}:${grant.role_key}:${grant.permission_key}`}><strong>{grant.branch_code} · {grant.role_key}</strong><span>{grant.permission_key}</span><small>{grant.reason}</small></li>)}</ul>}
  </section>;
}

function CompanyAccessWorkspace({ companies, selected, items, branches, scopedGrants, ready }: {
  companies: MasterCompany[]; selected: string; items: MasterCompanyAccessItem[]; branches: MasterBranch[]; scopedGrants: MasterCompanyScopedPermissionGrant[]; ready: boolean;
}) {
  const router = useRouter();
  const [query, setQuery] = useState("");
  const initiallyEnabled = useMemo(() => new Set(items.filter((item) => item.enabled).map((item) => item.transaction_code)), [items]);
  const [chosen, setChosen] = useState(() => new Set(initiallyEnabled));
  const [confirming, setConfirming] = useState(false);
  const [state, action, pending] = useActionState(setCompanyTransactionAvailabilityAction, masterAccessIdle);
  const filtered = companies.filter((company) => company.legal_name.toLowerCase().includes(query.toLowerCase()));
  const grouped = useMemo(() => items.reduce<Record<string, MasterCompanyAccessItem[]>>((groups, item) => {
    (groups[item.module_code] ??= []).push(item); return groups;
  }, {}), [items]);
  const company = companies.find((entry) => entry.company_id === selected);
  const changedCodes = items.filter((item) => initiallyEnabled.has(item.transaction_code) !== chosen.has(item.transaction_code)).map((item) => item.transaction_code);
  const hasChanges = changedCodes.length > 0;

  useEffect(() => {
    if (state.status === "success") router.refresh();
  }, [router, state.status]);

  return <div className="master-company-access">
    <label className="master-governance-search">Buscar empresa
      <input value={query} onChange={(event) => setQuery(event.target.value)} placeholder="Nome da empresa" />
    </label>
    <div className="master-company-picker">{filtered.map((entry) => <a className={`master-company-choice${entry.company_id === selected ? " is-selected" : ""}`} href={`/master/acessos-por-empresa?empresa=${encodeURIComponent(entry.company_id)}`} key={entry.company_id}>
      <span><strong>{entry.legal_name}</strong><small>{entry.status === "active" ? "Ativa" : "Indisponível"} · {entry.branch_count} filiais</small></span>
    </a>)}</div>
    {company && <>
      <section className="master-governance-guidance"><h3>{company.legal_name}</h3><p>Fluxo: aprove a permissão, aprove a transação, disponibilize-a para esta empresa e, por fim, conceda-a a um papel e usuário autorizados.</p></section>
      {ready ? <form action={action} className="master-company-access-form">
        <input type="hidden" name="tenant_id" value={selected} />
        {Object.entries(grouped).map(([moduleCode, rows]) => <section className="master-catalog-module" key={moduleCode}>
          <header><h5>{modules[moduleCode] ?? moduleCode}</h5><span>{rows.length} transações</span></header>
          <div className="master-company-transaction-list">{rows.map((row) => {
            const savedForCompany = initiallyEnabled.has(row.transaction_code);
            const selectedForCompany = chosen.has(row.transaction_code);
            const pendingChange = savedForCompany !== selectedForCompany;
            const eligible = row.approval_state === "approved" && row.permission_approval_state === "approved";
            const canChange = eligible || selectedForCompany;
            return <label className="master-company-transaction" key={row.transaction_code}>
              <input type="checkbox" name="transaction_code" value={row.transaction_code} checked={selectedForCompany} disabled={!canChange || pending} onChange={(event) => setChosen((current) => {
                const next = new Set(current); if (event.target.checked) next.add(row.transaction_code); else next.delete(row.transaction_code); return next;
              })} />
              <span className="master-company-transaction-copy"><strong>{row.transaction_code} · {names[row.transaction_code] ?? "Transação cadastrada"}</strong><small>{unavailableReason(row)}</small></span>
              <span className="master-company-transaction-statuses">
                <span>Transação global <b className={`master-badge${stateClass(row.approval_state)}`}>{stateLabel(row.approval_state)}</b></span>
                <span>Permissão associada <b className={`master-badge${stateClass(row.permission_approval_state)}`}>{stateLabel(row.permission_approval_state)}</b></span>
                <span>Disponibilidade salva <b className={`master-badge${savedForCompany ? " is-positive" : ""}`}>{savedForCompany ? "Habilitada" : "Não habilitada"}</b></span>
                {pendingChange && <span>Alteração pendente <b className="master-badge">{selectedForCompany ? "Será habilitada" : "Será revogada"}</b></span>}
              </span>
            </label>;
          })}</div>
        </section>)}
        <section className={`master-company-change-summary${hasChanges ? " is-pending" : ""}`} aria-live="polite"><strong>{hasChanges ? "Alterações ainda não salvas" : "Nenhuma alteração pendente"}</strong><p>{hasChanges ? `A confirmação salvará a disponibilidade de: ${changedCodes.join(", ")}.` : "Selecione ou desmarque transações elegíveis para preparar uma alteração."}</p></section>
        <p className="master-form-help">Disponibilidade empresarial não aprova papéis, não cria vínculos e não concede permissões individuais.</p>
        <label className="master-form-help">Justificativa auditável<textarea name="reason" minLength={10} maxLength={1000} required disabled={!hasChanges || pending} /></label>
        <label className="master-checkbox-label"><input name="confirmed" required type="checkbox" checked={confirming} onChange={(event) => setConfirming(event.target.checked)} disabled={!hasChanges || pending} /> Confirmo a empresa e as transações selecionadas.</label>
        <button className="master-action" type="submit" disabled={!hasChanges || !confirming || pending}>{pending ? "Salvando…" : "Salvar permissões da empresa"}</button>
        {state.message && <p className={`master-company-feedback ${state.status === "success" ? "is-success" : "is-error"}`} role={state.status === "success" ? "status" : "alert"}>{state.message}</p>}
      </form> : <section className="master-notice"><div><strong>Configuração aguardando ativação</strong><p>A estrutura de disponibilidade por empresa não está acessível neste ambiente. Nada pode ser salvo antes dela.</p></div></section>}
      <CompanyScopedGrantManager tenantId={selected} branches={branches} items={items} grants={scopedGrants} ready={ready} />
    </>}
  </div>;
}

export function CompanyAccessConsole(props: { companies: MasterCompany[]; selected: string; items: MasterCompanyAccessItem[]; branches: MasterBranch[]; scopedGrants: MasterCompanyScopedPermissionGrant[]; ready: boolean }) {
  const savedState = `${props.items.map((item) => `${item.transaction_code}:${item.enabled ? "1" : "0"}`).join("|")}:${props.scopedGrants.map((grant) => `${grant.branch_id}:${grant.role_key}:${grant.permission_key}`).join("|")}`;
  return <CompanyAccessWorkspace key={`${props.selected}:${savedState}`} {...props} />;
}
