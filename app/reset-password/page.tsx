import Link from "next/link";
import Image from "next/image";
import { updatePasswordAction } from "@/app/actions/auth";
import { AuthForm } from "@/app/components/auth-form";
import { safeInternalPath } from "@/lib/supabase/env";
import { createClient } from "@/lib/supabase/server";

export const dynamic = "force-dynamic";

export default async function ResetPasswordPage({ searchParams }: { searchParams: Promise<{ next?: string; setup?: string }> }) {
  const { next, setup } = await searchParams;
  const supabase = await createClient();
  const { data: { user } } = supabase ? await supabase.auth.getUser() : { data: { user: null } };

  return (
    <main className="auth-shell">
      <section className="auth-card" aria-labelledby="reset-title">
        <div className="brand-lockup"><Image className="brand-mark brand-mark-image" src="/econtroll-logo.png" width={64} height={64} alt="" aria-hidden="true" /><span>eControll</span></div>
        <p className="eyebrow">{setup === "invite" ? "Ativação de conta" : "Recuperação de acesso"}</p>
        <h1 id="reset-title">{setup === "invite" ? "Defina sua primeira senha" : "Criar nova senha"}</h1>
        <p className="auth-description">{user
          ? setup === "invite" ? "Defina uma senha para ativar sua conta e continuar com o convite." : "Escolha uma nova senha para sua conta."
          : "Abra o link de recuperação ou ativação enviado ao seu e-mail para continuar."}</p>
        {user ? <AuthForm action={updatePasswordAction} mode="reset" next={safeInternalPath(next, "/dashboard")} /> : <div className="auth-links"><Link href="/forgot-password">Solicitar novo link</Link></div>}
      </section>
      <footer className="page-footer">eControll · Ambiente de acesso</footer>
    </main>
  );
}
