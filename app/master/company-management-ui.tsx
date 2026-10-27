"use client";

import { useActionState, useState } from "react";
import {
  createMasterBranchAction, createMasterCompanyAction, setMasterBranchStatusAction,
  setMasterCompanyStatusAction, updateMasterBranchAction, updateMasterCompanyAction,
  type MasterMutationState,
} from "@/app/actions/master-company-v2";
import type { MasterBranchV2, MasterCompanyV2 } from "@/lib/master/read-model";

const idle: MasterMutationState = { status: "idle" };

export function CompanyMetadataForm({ requestId, company }: { requestId: string; company?: MasterCompanyV2 }) {
  const [state, action, pending] = useActionState(company ? updateMasterCompanyAction : createMasterCompanyAction, idle);
  const completed = state.status === "success";
  return <form action={action} className="master-company-form master-v2-form">
    <input type="hidden" name="request_id" value={requestId} />
    {company && <input type="hidden" name="company_id" value={company.company_id} />}
    <label>Razão social<input name="legal_name" required maxLength={200} defaultValue={company?.legal_name ?? ""} autoComplete="organization" disabled={pending || completed} /></label>
    <label>Nome fantasia<input name="trade_name" maxLength={200} defaultValue={company?.trade_name ?? ""} disabled={pending || completed} /></label>
    <label>CNPJ (opcional)<input name="cnpj" inputMode="numeric" autoComplete="off" maxLength={18} defaultValue={company?.cnpj ?? ""} placeholder="00.000.000/0000-00" disabled={pending || completed} /></label>
    <label>E-mail de contato<input name="contact_email" type="email" maxLength={254} defaultValue={company?.contact_email ?? ""} autoComplete="email" disabled={pending || completed} /></label>
    <label>Telefone<input name="contact_phone" type="tel" maxLength={24} defaultValue={company?.contact_phone ?? ""} autoComplete="tel" disabled={pending || completed} /></label>
    <p className="master-form-help">A data de criação é gerada pelo banco. Nenhum usuário, membership ou permissão empresarial é criado automaticamente.</p>
    <button className="master-action" type="submit" disabled={pending || completed}>{pending ? "Salvando…" : completed ? "Salvo" : company ? "Salvar alterações" : "Cadastrar empresa"}</button>
    <MutationFeedback state={state} />
  </form>;
}

export function BranchMetadataForm({ requestId, companyId, branch }: { requestId: string; companyId: string; branch?: MasterBranchV2 }) {
  const [state, action, pending] = useActionState(branch ? updateMasterBranchAction : createMasterBranchAction, idle);
  const completed = state.status === "success";
  return <form action={action} className="master-company-form master-v2-form">
    <input type="hidden" name="request_id" value={requestId} />
    <input type="hidden" name="company_id" value={companyId} />
    {branch && <input type="hidden" name="branch_id" value={branch.branch_id} />}
    <label>Código interno<input name="code" required minLength={1} maxLength={40} defaultValue={branch?.code ?? ""} autoComplete="off" disabled={pending || completed} /></label>
    <label>Nome da filial<input name="name" required minLength={1} maxLength={160} defaultValue={branch?.name ?? ""} disabled={pending || completed} /></label>
    <label>CNPJ da filial (opcional)<input name="cnpj" inputMode="numeric" maxLength={18} defaultValue={branch?.cnpj ?? ""} placeholder="00.000.000/0000-00" disabled={pending || completed} /></label>
    <label>Endereço (opcional)<input name="address" maxLength={500} defaultValue={branch?.address ?? ""} autoComplete="street-address" disabled={pending || completed} /></label>
    <label className="master-checkbox-label"><input name="is_headquarters" type="checkbox" value="true" defaultChecked={branch?.is_headquarters ?? false} disabled={pending || completed} /> Identificar como matriz</label>
    <p className="master-form-help">A empresa é determinada no servidor pelo identificador associado a esta operação e revalidada pelo banco; isso não concede acesso operacional ao Master.</p>
    <button className="master-action" type="submit" disabled={pending || completed}>{pending ? "Salvando…" : completed ? "Salvo" : branch ? "Salvar filial" : "Cadastrar filial"}</button>
    <MutationFeedback state={state} />
  </form>;
}

export function CompanyStatusForm({ company, requestId }: { company: MasterCompanyV2; requestId: string }) {
  const [state, action, pending] = useActionState(setMasterCompanyStatusAction, idle);
  const next = company.status === "active" ? "suspended" : company.status === "suspended" ? "active" : null;
  if (!next) return <span className="master-muted">Encerrada</span>;
  return <form action={action} onSubmit={(event) => { if (!window.confirm(next === "suspended" ? "Suspender esta empresa? O cadastro e os acessos empresariais existentes não serão apagados." : "Ativar esta empresa?")) event.preventDefault(); }} className="master-inline-action">
    <input type="hidden" name="request_id" value={requestId} /><input type="hidden" name="company_id" value={company.company_id} /><input type="hidden" name="status" value={next} />
    <button type="submit" disabled={pending}>{pending ? "Atualizando…" : next === "suspended" ? "Suspender" : "Ativar"}</button><MutationFeedback state={state} compact />
  </form>;
}

export function BranchStatusForm({ companyId, branch, requestId }: { companyId: string; branch: MasterBranchV2; requestId: string }) {
  const [state, action, pending] = useActionState(setMasterBranchStatusAction, idle);
  const next = branch.status === "active" ? "inactive" : "active";
  return <form action={action} onSubmit={(event) => { if (!window.confirm(next === "inactive" ? "Suspender esta filial?" : "Ativar esta filial?")) event.preventDefault(); }} className="master-inline-action">
    <input type="hidden" name="request_id" value={requestId} /><input type="hidden" name="company_id" value={companyId} /><input type="hidden" name="branch_id" value={branch.branch_id} /><input type="hidden" name="status" value={next} />
    <button type="submit" disabled={pending}>{pending ? "Atualizando…" : next === "inactive" ? "Suspender" : "Ativar"}</button><MutationFeedback state={state} compact />
  </form>;
}

function MutationFeedback({ state, compact = false }: { state: MasterMutationState; compact?: boolean }) {
  const [hidden, setHidden] = useState(false);
  if (state.status === "idle" || hidden) return null;
  const success = state.status === "success";
  return <div className={`master-company-feedback ${success ? "is-success" : "is-error"}${compact ? " is-compact" : ""}`} role={success ? "status" : "alert"}>
    <span>{state.message}</span>{state.entityId && !compact && <small>Identificador: {state.entityId}</small>}
    <button type="button" className="master-feedback-dismiss" onClick={() => setHidden(true)} aria-label="Fechar mensagem">×</button>
  </div>;
}
