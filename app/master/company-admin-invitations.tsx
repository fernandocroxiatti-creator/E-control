"use client";

import { useActionState, useRef } from "react";
import {
  createCompanyAdminInvitationAction,
  expireCompanyAdminInvitationsAction,
  revokeCompanyAdminInvitationAction,
  type InvitationActionState,
} from "@/app/actions/company-admin-invitations";
import type { CompanyAdminInvitation, MasterCompany } from "@/lib/master/read-model";

const idle: InvitationActionState = { status: "idle" };

export function CompanyAdminInvitationForm({ companies, enabled }: { companies: MasterCompany[]; enabled: boolean }) {
  const [state, action, pending] = useActionState(createCompanyAdminInvitationAction, idle);
  const requestId = useRef<HTMLInputElement>(null);
  if (!enabled) return <p className="master-notice" role="note">Convites desativados. A habilitação depende de configuração explícita e de `company_owner` aprovado no catálogo empresarial.</p>;
  if (!companies.length) return <p className="master-panel-empty">Cadastre uma empresa antes de convidar seu primeiro administrador.</p>;
  return <form action={action} className="master-company-form master-v2-form" onSubmit={() => {
    if (requestId.current && !requestId.current.value) requestId.current.value = globalThis.crypto.randomUUID();
  }}>
    <label>Empresa<select name="tenant_id" required defaultValue=""><option value="" disabled>Selecione uma empresa</option>{companies.map((company) => <option key={company.company_id} value={company.company_id}>{company.legal_name}</option>)}</select></label>
    <label>E-mail do administrador<input name="recipient_email" type="email" required maxLength={254} autoComplete="email" /></label>
    <input ref={requestId} type="hidden" name="request_id" defaultValue="" />
    <p className="master-form-help">O convite é de uso único, expira em 7 dias e só pode ser aceito por uma sessão autenticada cujo e-mail confirmado corresponda ao destinatário. O papel fixo é `company_owner`; ele precisa estar aprovado no catálogo para o envio ser aceito.</p>
    <button className="master-action" type="submit" disabled={pending}>{pending ? "Emitindo convite…" : "Gerar convite seguro"}</button>
    {state.message && <p className={`master-company-feedback ${state.status === "success" ? "is-success" : "is-error"}`} role={state.status === "success" ? "status" : "alert"}>{state.message}</p>}
    {state.invitationLink && <div className="master-invitation-link"><label htmlFor="company-admin-invitation-link">Link de uso único (copie agora)</label><input id="company-admin-invitation-link" readOnly value={state.invitationLink} onFocus={(event) => event.currentTarget.select()} /><small>Este link contém um token temporário. Envie somente ao destinatário e não o registre em chamados ou logs.</small><small>Expira em {new Intl.DateTimeFormat("pt-BR", { dateStyle: "medium", timeStyle: "short" }).format(new Date(state.expiresAt ?? ""))}.</small></div>}
  </form>;
}

export function CompanyAdminInvitationTable({ rows, tenantId }: { rows: CompanyAdminInvitation[]; tenantId: string }) {
  if (!rows.length) return <p className="master-panel-empty">Nenhum convite emitido para esta empresa.</p>;
  return <>
    {rows.some((row) => row.status === "expired") && <ExpireInvitations tenantId={tenantId} />}
    <div className="master-table-wrap" role="region" aria-label="Convites de administrador empresarial" tabIndex={0}>
    <table className="master-table"><thead><tr><th>Destinatário</th><th>Papel</th><th>Situação</th><th>Criado em</th><th>Expira em</th><th>Ação</th></tr></thead>
      <tbody>{rows.map((row) => <tr key={row.invitation_id}><td>{row.recipient_email}</td><td>{row.role_key}</td><td>{new Date(row.expires_at) <= new Date() && row.status === "pending" ? "expirado" : row.status}</td><td>{formatDate(row.created_at)}</td><td>{formatDate(row.expires_at)}</td><td>{row.status === "pending" && new Date(row.expires_at) > new Date() ? <RevokeInvitation invitationId={row.invitation_id} /> : "—"}</td></tr>)}</tbody>
    </table>
    </div>
  </>;
}

function ExpireInvitations({ tenantId }: { tenantId: string }) {
  const [state, action, pending] = useActionState(expireCompanyAdminInvitationsAction, idle);
  return <form action={action} className="master-expire-invitations"><input type="hidden" name="tenant_id" value={tenantId} /><button className="master-row-link" type="submit" disabled={pending}>{pending ? "Registrando…" : "Registrar expirações pendentes"}</button>{state.message && <span role={state.status === "success" ? "status" : "alert"}>{state.message}</span>}</form>;
}

function RevokeInvitation({ invitationId }: { invitationId: string }) {
  const [state, action, pending] = useActionState(revokeCompanyAdminInvitationAction, idle);
  return <form action={action}><input type="hidden" name="invitation_id" value={invitationId} /><button className="master-row-link" type="submit" disabled={pending}>{pending ? "Revogando…" : state.status === "success" ? "Revogado" : "Revogar"}</button>{state.message && <span role={state.status === "success" ? "status" : "alert"}>{state.message}</span>}</form>;
}

function formatDate(value: string) {
  return new Intl.DateTimeFormat("pt-BR", { dateStyle: "medium", timeStyle: "short" }).format(new Date(value));
}
