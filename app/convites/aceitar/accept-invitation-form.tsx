"use client";

import Link from "next/link";
import { useRouter } from "next/navigation";
import { useActionState, useRef, useState } from "react";
import { acceptCompanyAdminInvitationAction, type InvitationAcceptState } from "@/app/actions/company-admin-invitations";

const idle: InvitationAcceptState = { status: "idle" };
const tokenPattern = /^[0-9a-f]{64}$/;

export function AcceptCompanyAdminInvitationForm({ authenticated, enabled }: { authenticated: boolean; enabled: boolean }) {
  const router = useRouter();
  const [state, action, pending] = useActionState(acceptCompanyAdminInvitationAction, idle);
  const tokenInput = useRef<HTMLInputElement>(null);
  const [missingToken, setMissingToken] = useState(false);

  function prepareToken(event: React.FormEvent<HTMLFormElement>) {
    const candidate = new URLSearchParams(window.location.hash.slice(1)).get("token") ?? "";
    if (!tokenPattern.test(candidate) || !tokenInput.current) {
      event.preventDefault();
      setMissingToken(true);
      return;
    }
    tokenInput.current.value = candidate;
    // Fragments are never sent to the server. Remove the bearer token from history on submit.
    window.history.replaceState(null, "", window.location.pathname + window.location.search);
    setMissingToken(false);
  }

  return <section className="auth-card invitation-accept-card">
    <p className="eyebrow">Vínculo empresarial</p>
    <h1>Aceitar convite</h1>
    {!enabled && <div className="form-message error" role="status"><p>Os convites empresariais estão desativados neste ambiente. Nenhum vínculo será criado até a habilitação explícita e segura desta funcionalidade.</p></div>}
    {missingToken && <p className="auth-description" role="alert">O link não contém um convite válido. Abra novamente o link recebido pelo canal de convite.</p>}
    {enabled && !authenticated && <div className="form-message error" role="status"><p>Entre primeiro com a conta que recebeu o convite. O endereço do convite continua nesta aba.</p><Link href="/login?next=%2Fconvites%2Faceitar" target="_blank" rel="noreferrer">Abrir login em outra aba</Link><button className="secondary-button" type="button" onClick={() => router.refresh()}>Já entrei; verificar sessão</button></div>}
    {enabled && authenticated && state.status !== "accepted" && <form action={action} className="auth-form" onSubmit={prepareToken}>
      <p>Ao confirmar, o sistema valida o e-mail confirmado da sessão e vincula somente o papel empresarial autorizado no convite.</p>
      <input ref={tokenInput} type="hidden" name="invitation_token" defaultValue="" />
      <button className="primary-button" type="submit" disabled={pending}>{pending ? "Validando…" : "Confirmar e aceitar convite"}</button>
    </form>}
    {state.message && <p className={`form-message ${state.status === "accepted" ? "success" : "error"}`} role={state.status === "accepted" ? "status" : "alert"}>{state.message}</p>}
    {enabled && state.status === "accepted" && <Link className="primary-button" href="/dashboard">Ir ao painel operacional</Link>}
  </section>;
}
