"use client";

import { useActionState } from "react";
import { createMasterCompanyAction } from "@/app/actions/master-company";
import type { MasterCompanyFormState } from "@/lib/master/company-creation";

const initialState: MasterCompanyFormState = { status: "idle" };

export function CreateCompanyForm({ requestId }: { requestId: string }) {
  const [state, action, pending] = useActionState(createMasterCompanyAction, initialState);
  const completed = state.status === "success";

  return (
    <form action={action} className="master-company-form">
      <input type="hidden" name="request_id" value={requestId} />
      <fieldset disabled={pending || completed}>
        <label htmlFor="master-company-legal-name">Razão social</label>
        <input
          id="master-company-legal-name"
          name="legal_name"
          type="text"
          autoComplete="organization"
          minLength={1}
          maxLength={200}
          required
          aria-describedby="master-company-help"
        />
        <p id="master-company-help">
          A gravação só é aceita por uma sessão Admin Master válida e enquanto o Supabase local estiver configurado.
          O cadastro não cria filiais, usuários ou permissões empresariais.
        </p>
        <button className="master-action master-company-submit" type="submit" aria-disabled={pending || completed}>
          {pending ? "Criando…" : "Criar empresa"}
        </button>
      </fieldset>
      {state.status === "error" && <p className="master-company-feedback is-error" role="alert">{state.message}</p>}
      {state.status === "success" && (
        <div className="master-company-feedback is-success" role="status">
          <p>{state.message}</p>
          <small>Identificador da solicitação concluída: {state.companyId}</small>
          <p>Recarregue esta tela para iniciar uma nova solicitação.</p>
        </div>
      )}
    </form>
  );
}
