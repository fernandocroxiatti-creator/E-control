import Link from "next/link";
import Image from "next/image";
import { updatePasswordAction } from "@/app/actions/auth";
import { AuthForm } from "@/app/components/auth-form";
import { createClient } from "@/lib/supabase/server";

export const dynamic = "force-dynamic";

export default async function ResetPasswordPage() {
  const supabase = await createClient();
  const { data: { user } } = supabase ? await supabase.auth.getUser() : { data: { user: null } };

  return (
    <main className="auth-shell">
      <section className="auth-card" aria-labelledby="reset-title">
        <div className="brand-lockup"><Image className="brand-mark brand-mark-image" src="/econtroll-logo.png" width={64} height={64} alt="" aria-hidden="true" /><span>eControll</span></div>
        <p className="eyebrow">Recuperação de acesso</p>
        <h1 id="reset-title">Criar nova senha</h1>
        <p className="auth-description">{user ? "Escolha uma nova senha para sua conta." : "Abra o link de recuperação enviado ao seu e-mail para continuar."}</p>
        {user ? <AuthForm action={updatePasswordAction} mode="reset" /> : <div className="auth-links"><Link href="/forgot-password">Solicitar novo link</Link></div>}
      </section>
      <footer className="page-footer">eControll · Ambiente de acesso</footer>
    </main>
  );
}
