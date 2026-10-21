import Link from "next/link";
import Image from "next/image";
import { requestPasswordResetAction } from "@/app/actions/auth";
import { AuthForm } from "@/app/components/auth-form";

export default function ForgotPasswordPage() {
  return (
    <main className="auth-shell">
      <section className="auth-card" aria-labelledby="forgot-title">
        <div className="brand-lockup"><Image className="brand-mark brand-mark-image" src="/econtroll-logo.png" width={64} height={64} alt="" aria-hidden="true" /><span>eControll</span></div>
        <p className="eyebrow">Recuperação de acesso</p>
        <h1 id="forgot-title">Redefina sua senha</h1>
        <p className="auth-description">Informe seu e-mail e enviaremos instruções caso exista uma conta associada.</p>
        <AuthForm action={requestPasswordResetAction} mode="forgot" />
        <div className="auth-links"><Link href="/login">Voltar ao login</Link></div>
      </section>
      <footer className="page-footer">eControll · Ambiente de acesso</footer>
    </main>
  );
}
