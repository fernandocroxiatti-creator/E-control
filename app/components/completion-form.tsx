"use client";
import { useActionState, useRef } from "react";
import { executeCompletionAction, type CompletionState } from "@/app/actions/erp-completion";
import { commands, type Command, type CommandSpec } from "@/lib/erp-completion/input";
export function CompletionForm({ command, tenantId, branchId, options = {} }: { command: Command; tenantId?: string; branchId?: string; options?: Record<string, { id: string; name: string }[]> }) {
  const [state, action, pending] = useActionState(executeCompletionAction, { status: "idle" } as CompletionState);
  const request = useRef<HTMLInputElement>(null); const lastSuccess = useRef<string | undefined>(undefined);
  const spec: CommandSpec = commands[command];
  return <form className="master-v2-form" action={action} onSubmit={() => {
    if (request.current && (!request.current.value || (state.status === "success" && lastSuccess.current !== state.resultId))) { request.current.value = crypto.randomUUID(); lastSuccess.current = state.resultId; }
  }}><h3>{spec.label}</h3><input type="hidden" name="command" value={command} />
    {tenantId ? <input type="hidden" name="tenant_id" value={tenantId} /> : command === "subscription" ? <label>Empresa<select name="tenant_id" required><option value="">Selecione</option>{options.tenant_id?.map(o => <option value={o.id} key={o.id}>{o.name}</option>)}</select></label> : null}
    {branchId ? <input type="hidden" name="branch_id" value={branchId} /> : null}<input ref={request} type="hidden" name="request_id" />
    {spec.fields.map(field => <label key={field.name}>{field.label}{options[field.name] || field.type === "select" ? <select name={field.name} required={!field.optional}><option value="">Selecione</option>{(options[field.name] ?? field.options?.map(v => ({ id: v, name: v })) ?? []).map(o => <option key={o.id} value={o.id}>{o.name}</option>)}</select> : <input name={field.name} type={field.type === "date" ? "date" : "text"} inputMode={field.type === "decimal" ? "decimal" : field.type === "integer" ? "numeric" : undefined} maxLength={field.max ?? 1000} required={!field.optional} />}</label>)}
    <button disabled={pending}>{pending ? "Registrando…" : spec.label}</button>{state.message ? <p role="status" className="master-notice">{state.message}{state.status === "success" ? ` ID: ${state.resultId}` : ""}</p> : null}
  </form>;
}
