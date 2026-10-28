"use client";

import { useActionState } from "react";
import { submitFirstMasterBootstrap, type FirstMasterBootstrapActionState } from "./actions";

const initialState: FirstMasterBootstrapActionState = {};

export function FirstMasterBootstrapConfirmationForm() {
  const [state, action, pending] = useActionState(submitFirstMasterBootstrap, initialState);
  if (state.completed) return <main><h1>Solicitação concluída</h1><p>Confirme a auditoria antes de seguir para o painel.</p></main>;
  return <form action={action}>
    <h1>Ativação do primeiro Admin Master</h1>
    <p>Esta ação é única e exige confirmação explícita.</p>
    <label><input required type="checkbox" name="confirm-first-master" value="confirm" /> Confirmo a ativação.</label>
    {state.error ? <p role="alert">{state.error}</p> : null}
    <button type="submit" disabled={pending}>{pending ? "Processando" : "Conceder Admin Master"}</button>
  </form>;
}
