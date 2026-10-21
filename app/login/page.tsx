import Link from "next/link";
import { signInAction } from "@/app/actions/auth";
import { AuthForm } from "@/app/components/auth-form";
import { safeInternalPath } from "@/lib/supabase/env";
import { createClient } from "@/lib/supabase/server";
import { redirect } from "next/navigation";

export default async function LoginPage({ searchParams }: { searchParams: Promise<{ next?: string; auth?: string }> }) {
  const { next, auth } = await searchParams;
  const supabase = await createClient();
  if (supabase) {
    const { data: { user } } = await supabase.auth.getUser();
    if (user) redirect(safeInternalPath(next));
  }
  return (
    <main className="auth-shell">
      <section className="auth-card" aria-labelledby="login-title">
        <Brand />
        <p className="eyebrow">Gestão integrada</p>
        <h1 id="login-title">Acesse sua conta</h1>
        <p className="auth-description">Entre no eControll para continuar.</p>
        {auth === "callback-error" && <p className="form-message error" role="alert">O link de acesso expirou ou não é válido. Solicite uma nova recuperação de senha.</p>}
        <AuthForm action={signInAction} mode="login" next={safeInternalPath(next)} />
        <div className="auth-links"><Link href="/forgot-password">Esqueci minha senha</Link></div>
        <p className="auth-note">O acesso é disponibilizado pela administração do sistema.</p>
      </section>
      <footer className="page-footer">eControll · Ambiente de acesso</footer>
    </main>
  );
}

function Brand() { return <div className="brand-lockup"><span className="brand-mark" aria-hidden="true">e</span><span>eControll</span></div>; }
