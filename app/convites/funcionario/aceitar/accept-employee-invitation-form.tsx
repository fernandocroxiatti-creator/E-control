"use client";

import Link from "next/link";
import { useRouter } from "next/navigation";
import { useActionState, useRef, useState } from "react";
import { acceptEmployeeInvitationAction, type EmployeeInvitationAcceptState } from "@/app/actions/operational";

const idle: EmployeeInvitationAcceptState = { status: "idle" };
const tokenPattern = /^[0-9a-f]{64}$/;

export function AcceptEmployeeInvitationForm({ authenticated, enabled }: { authenticated: boolean; enabled: boolean }) {
  const router = useRouter();
  const [state, action, pending] = useActionState(acceptEmployeeInvitationAction, idle);
  const tokenInput = useRef<HTMLInputElement>(null);
  const [missingToken, setMissingToken] = useState(false);

  function prepareToken(event: React.FormEvent<HTMLFormElement>) {
    const token = new URLSearchParams(window.location.hash.slice(1)).get("token") ?? "";
    if (!tokenPattern.test(token) || !tokenInput.current) {
      event.preventDefault(); setMissingToken(true); return;
    }
    tokenInput.current.value = token;
    window.history.replaceState(null, "", window.location.pathname + window.location.search);
    setMissingToken(false);
  }

  return <section className="auth-card invitation-accept-card">
    <p className="eyebrow">Equipe empresarial</p>
    <h1>Aceitar convite de funcionário</h1>
    {!enabled && <div className="form-message error" role="status"><p>O ambiente operacional ainda não está habilitado. Nenhum vínculo será criado até a ativação explícita e as permissões empresariais necessárias.</p></div>}
    {missingToken && <p className="auth-description" role="alert">O link não contém um convite válido. Abra novamente o link recebido pelo canal seguro.</p>}
    {enabled && !authenticated && <div className="form-message error" role="status"><p>Entre primeiro com a conta que recebeu o convite. O endereço do convite continua nesta aba.</p><Link href="/login?next=%2Fconvites%2Ffuncionario%2Faceitar" target="_blank" rel="noreferrer">Abrir login em outra aba</Link><button className="secondary-button" type="button" onClick={() => router.refresh()}>Já entrei; verificar sessão</button></div>}
    {enabled && authenticated && state.status !== "accepted" && <form action={action} className="auth-form" onSubmit={prepareToken}>
      <p>Ao confirmar, o sistema confere o e-mail confirmado da sessão e cria somente um vínculo pendente para as filiais definidas no convite.</p>
      <input ref={tokenInput} type="hidden" name="invitation_token" defaultValue="" />
      <button className="primary-button" type="submit" disabled={pending}>{pending ? "Validando…" : "Confirmar e aceitar convite"}</button>
    </form>}
    {state.message && <p className={`form-message ${state.status === "accepted" ? "success" : "error"}`} role={state.status === "accepted" ? "status" : "alert"}>{state.message}</p>}
    {enabled && state.status === "accepted" && <Link className="primary-button" href="/dashboard">Ir ao painel</Link>}
  </section>;
}
