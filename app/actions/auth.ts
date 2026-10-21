"use server";

import { redirect } from "next/navigation";
import { createClient } from "@/lib/supabase/server";
import { getSiteUrl, safeInternalPath } from "@/lib/supabase/env";

export type AuthState = { error?: string; success?: string } | null;

export async function signInAction(_state: AuthState, formData: FormData): Promise<AuthState> {
  const email = String(formData.get("email") ?? "").trim();
  const password = String(formData.get("password") ?? "");
  const next = safeInternalPath(String(formData.get("next") ?? ""));

  if (!email || !/^\S+@\S+\.\S+$/.test(email) || !password) {
    return { error: "Informe um e-mail válido e sua senha." };
  }

  const supabase = await createClient();
  if (!supabase) return { error: "A integração ainda não está configurada. Verifique as variáveis públicas do Supabase." };

  const { error } = await supabase.auth.signInWithPassword({ email, password });
  if (error) return { error: "Não foi possível entrar. Confira os dados ou tente novamente." };

  redirect(next);
}

export async function requestPasswordResetAction(_state: AuthState, formData: FormData): Promise<AuthState> {
  const email = String(formData.get("email") ?? "").trim();
  if (!email || !/^\S+@\S+\.\S+$/.test(email)) return { error: "Informe um e-mail válido." };

  const supabase = await createClient();
  if (!supabase) return { error: "A integração ainda não está configurada. Verifique as variáveis públicas do Supabase." };

  const redirectTo = new URL("/auth/callback?next=%2Freset-password", getSiteUrl()).toString();
  await supabase.auth.resetPasswordForEmail(email, { redirectTo });

  // Same response regardless of whether the address belongs to an account.
  return { success: "Se houver uma conta para esse e-mail, você receberá instruções para redefinir a senha." };
}

export async function updatePasswordAction(_state: AuthState, formData: FormData): Promise<AuthState> {
  const password = String(formData.get("password") ?? "");
  const confirmation = String(formData.get("confirmation") ?? "");
  if (password.length < 10) return { error: "A senha deve ter pelo menos 10 caracteres." };
  if (password !== confirmation) return { error: "As senhas não coincidem." };

  const supabase = await createClient();
  if (!supabase) return { error: "A integração ainda não está configurada." };
  const { data: { user }, error: userError } = await supabase.auth.getUser();
  if (userError || !user) return { error: "Sessão de recuperação inválida. Solicite um novo link." };

  const { error } = await supabase.auth.updateUser({ password });
  if (error) return { error: "Não foi possível atualizar a senha. Solicite um novo link e tente novamente." };
  redirect("/dashboard?password=updated");
}

export async function signOutAction() {
  const supabase = await createClient();
  if (supabase) await supabase.auth.signOut();
  redirect("/login");
}
