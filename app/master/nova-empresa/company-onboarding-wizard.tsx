"use client";

import Link from "next/link";
import { useActionState, useRef } from "react";
import { createCompanyAdminInvitationAction, type InvitationActionState } from "@/app/actions/company-admin-invitations";
import { createMasterBranchAction, createMasterCompanyAction, type MasterMutationState } from "@/app/actions/master-company-v2";

const idleCompany: MasterMutationState = { status: "idle" };
const idleInvitation: InvitationActionState = { status: "idle" };

/**
 * A guided composition of the existing, auditable RPC workflows.  The wizard
 * never stages business data in the browser: every completed step has already
 * been persisted by its Server Action before the following step is displayed.
 */
export function CompanyOnboardingWizard({ enabled }: { enabled: boolean }) {
  const [companyState, companyAction, companyPending] = useActionState(createMasterCompanyAction, idleCompany);
  const [branchState, branchAction, branchPending] = useActionState(createMasterBranchAction, idleCompany);
  const [ownerState, ownerAction, ownerPending] = useActionState(createCompanyAdminInvitationAction, idleInvitation);
  const companyRequest = useRef<HTMLInputElement>(null);
  const branchRequest = useRef<HTMLInputElement>(null);
  const invitationRequest = useRef<HTMLInputElement>(null);
  const companyId = companyState.status === "success" ? companyState.entityId : undefined;
  const branchId = branchState.status === "success" ? branchState.entityId : undefined;
  const canInvite = Boolean(companyId && branchId);

  if (!enabled) return <p className="master-notice" role="note">O onboarding permanece em modo de preparação neste ambiente. Nenhum dado é enviado enquanto as flags de cadastro, gestão e convites não estiverem habilitadas.</p>;

  return <div className="master-company-onboarding">
    <ol className="master-onboarding-steps" aria-label="Etapas do novo cliente">
      {[["1", "Dados empresariais", Boolean(companyId)], ["2", "Filial principal", Boolean(branchId)], ["3", "Transações contratadas", Boolean(branchId)], ["4", "Proprietário", ownerState.status === "success"], ["5", "Revisão", ownerState.status === "success"]].map(([number, label, complete]) => <li key={String(number)} className={complete ? "is-complete" : ""}><span>{number}</span>{label}</li>)}
    </ol>

    <section className="master-data-panel">
      <header><div><h2>1. Dados empresariais</h2><p>O cadastro é idempotente pelo identificador da solicitação e não cria acessos empresariais.</p></div></header>
      <form action={companyAction} className="master-company-form master-v2-form" onSubmit={() => { if (companyRequest.current && !companyRequest.current.value) companyRequest.current.value = crypto.randomUUID(); }}>
        <input ref={companyRequest} type="hidden" name="request_id" />
        <label>Razão social<input name="legal_name" required maxLength={200} disabled={companyPending || Boolean(companyId)} /></label>
        <label>Nome fantasia<input name="trade_name" maxLength={200} disabled={companyPending || Boolean(companyId)} /></label>
        <label>CNPJ (opcional)<input name="cnpj" maxLength={18} inputMode="numeric" disabled={companyPending || Boolean(companyId)} /></label>
        <label>E-mail de contato<input name="contact_email" type="email" maxLength={254} disabled={companyPending || Boolean(companyId)} /></label>
        <label>Telefone<input name="contact_phone" maxLength={24} disabled={companyPending || Boolean(companyId)} /></label>
        <button className="master-action" disabled={companyPending || Boolean(companyId)}>{companyPending ? "Cadastrando…" : companyId ? "Empresa cadastrada" : "Salvar dados empresariais"}</button>
        <Feedback state={companyState} />
      </form>
    </section>

    {companyId && <section className="master-data-panel">
      <header><div><h2>2. Filial principal</h2><p>O endereço operacional pertence à filial. A empresa selecionada é validada novamente pelo banco.</p></div></header>
      <form action={branchAction} className="master-company-form master-v2-form" onSubmit={() => { if (branchRequest.current && !branchRequest.current.value) branchRequest.current.value = crypto.randomUUID(); }}>
        <input type="hidden" name="company_id" value={companyId} /><input ref={branchRequest} type="hidden" name="request_id" />
        <label>Código<input name="code" required maxLength={40} disabled={branchPending || Boolean(branchId)} /></label>
        <label>Nome da filial<input name="name" required maxLength={160} disabled={branchPending || Boolean(branchId)} /></label>
        <label>CNPJ da filial (opcional)<input name="cnpj" maxLength={18} inputMode="numeric" disabled={branchPending || Boolean(branchId)} /></label>
        <label>Endereço<input name="address" maxLength={500} disabled={branchPending || Boolean(branchId)} /></label>
        <label className="master-checkbox-label"><input name="is_headquarters" type="checkbox" value="true" defaultChecked disabled={branchPending || Boolean(branchId)} /> Filial principal</label>
        <button className="master-action" disabled={branchPending || Boolean(branchId)}>{branchPending ? "Cadastrando…" : branchId ? "Filial cadastrada" : "Salvar filial principal"}</button>
        <Feedback state={branchState} />
      </form>
    </section>}

    {branchId && <section className="master-data-panel">
      <header><div><h2>3. Transações contratadas</h2><p>A disponibilidade empresarial é configurada separadamente e somente para transações já aprovadas globalmente. Ela não concede papéis nem grants a usuários.</p></div></header>
      <Link className="master-action" href={`/master/acessos-por-empresa?empresa=${encodeURIComponent(companyId!)}`}>Configurar módulos e transações da empresa</Link>
    </section>}

    {canInvite && <section className="master-data-panel">
      <header><div><h2>4. Proprietário empresarial</h2><p>O e-mail recebe a ativação pela infraestrutura Auth quando ela estiver configurada. O vínculo só existe após aceite autenticado com e-mail confirmado.</p></div></header>
      <form action={ownerAction} className="master-company-form master-v2-form" onSubmit={() => { if (invitationRequest.current && !invitationRequest.current.value) invitationRequest.current.value = crypto.randomUUID(); }}>
        <input type="hidden" name="tenant_id" value={companyId} /><input ref={invitationRequest} type="hidden" name="request_id" />
        <label>E-mail do proprietário<input name="recipient_email" type="email" maxLength={254} required disabled={ownerPending || ownerState.status === "success"} /></label>
        <button className="master-action" disabled={ownerPending || ownerState.status === "success"}>{ownerPending ? "Emitindo…" : ownerState.status === "success" ? "Convite emitido" : "Emitir convite seguro"}</button>
        <Feedback state={ownerState} />
        {ownerState.invitationLink && <p className="master-form-help">A entrega automática não foi confirmada. O link de uso único foi disponibilizado apenas nesta sessão Master; envie-o somente pelo canal seguro do destinatário.</p>}
      </form>
    </section>}

    {ownerState.status === "success" && <section className="master-data-panel"><header><div><h2>5. Revisão</h2><p>Empresa e filial foram gravadas e auditadas. O proprietário ainda precisa concluir o aceite autenticado; módulos e transações só se tornam disponíveis após a configuração explícita da etapa anterior.</p></div></header><div className="master-quick-links"><Link href={`/master/empresas/${encodeURIComponent(companyId!)}`}>Revisar empresa <span aria-hidden="true">→</span></Link><Link href="/master/administradores">Acompanhar convite <span aria-hidden="true">→</span></Link><Link href="/master/auditoria">Consultar auditoria <span aria-hidden="true">→</span></Link></div></section>}
  </div>;
}

function Feedback({ state }: { state: { status: string; message?: string } }) {
  return state.message ? <p className={`master-company-feedback ${state.status === "success" ? "is-success" : "is-error"}`} role={state.status === "success" ? "status" : "alert"}>{state.message}</p> : null;
}
