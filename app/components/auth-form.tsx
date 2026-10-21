"use client";

import { useActionState, useState } from "react";
import type { AuthState } from "@/app/actions/auth";

type AuthAction = (state: AuthState, formData: FormData) => Promise<AuthState>;

export function AuthForm({ action, mode, next }: { action: AuthAction; mode: "login" | "forgot" | "reset"; next?: string }) {
  const [state, formAction, pending] = useActionState(action, null);
  const [showPassword, setShowPassword] = useState(false);
  const isLogin = mode === "login";
  const isReset = mode === "reset";

  return (
    <form action={formAction} className="auth-form">
      {isLogin && <input type="hidden" name="next" value={next ?? "/dashboard"} />}
      {!isReset && (
        <label className="field-label" htmlFor="email">
          E-mail
          <input autoComplete="email" autoFocus type="email" id="email" name="email" required maxLength={254} placeholder="voce@empresa.com.br" />
        </label>
      )}
      {(isLogin || isReset) && (
        <>
          <label className="field-label" htmlFor="password">
            {isReset ? "Nova senha" : "Senha"}
            <span className="password-wrap">
              <input autoComplete={isReset ? "new-password" : "current-password"} type={showPassword ? "text" : "password"} id="password" name="password" required minLength={isReset ? 10 : 1} />
              <button className="password-toggle" type="button" onClick={() => setShowPassword((value) => !value)} aria-label={showPassword ? "Ocultar senha" : "Mostrar senha"}>
                {showPassword ? "Ocultar" : "Mostrar"}
              </button>
            </span>
          </label>
          {!isLogin && <label className="field-label" htmlFor="confirmation">Confirmar senha<input autoComplete="new-password" type={showPassword ? "text" : "password"} id="confirmation" name="confirmation" required minLength={10} /></label>}
        </>
      )}
      {state?.error && <p className="form-message error" role="alert">{state.error}</p>}
      {state?.success && <p className="form-message success" role="status">{state.success}</p>}
      <button className="primary-button" type="submit" disabled={pending}>
        {pending ? <><span className="spinner" aria-hidden="true" /> Aguarde…</> : isLogin ? "Entrar" : isReset ? "Salvar nova senha" : "Enviar instruções"}
      </button>
    </form>
  );
}
