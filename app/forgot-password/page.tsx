import Link from "next/link";
import { requestPasswordResetAction } from "@/app/actions/auth";
import { AuthForm } from "@/app/components/auth-form";

export default function ForgotPasswordPage() {
  return (
    <main className="auth-shell">
      <section className="auth-card" aria-labelledby="forgot-title">
        <div className="brand-lockup"><span className="brand-mark" aria-hidden="true">e</span><span>eControl</span></div>
        <p className="eyebrow">Recuperação de acesso</p>
        <h1 id="forgot-title">Redefina sua senha</h1>
        <p className="auth-description">Informe seu e-mail e enviaremos instruções caso exista uma conta associada.</p>
        <AuthForm action={requestPasswordResetAction} mode="forgot" />
        <div className="auth-links"><Link href="/login">Voltar ao login</Link></div>
      </section>
      <footer className="page-footer">eControl · Ambiente de acesso</footer>
    </main>
  );
}
