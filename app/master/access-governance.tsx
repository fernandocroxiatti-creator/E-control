"use client";

import { useActionState } from "react";
import {
  masterAccessIdle,
  setAccessCatalogApprovalAction,
  setRolePermissionGrantAction,
} from "@/app/actions/master-access-governance";
import type { MasterAccessControlEntry } from "@/lib/master/read-model";

const label: Record<string, string> = {
  role: "Papel", permission: "Permissão", transaction: "Transação", role_permission: "Concessão",
  pending_approval: "Pendente de aprovação", approved: "Aprovado", retired: "Desativado",
};

export function AccessGovernance({ entries, enabled }: { entries: MasterAccessControlEntry[]; enabled: boolean }) {
  const manageable = entries.filter((entry) => entry.entry_type !== "role_permission");
  const grants = entries.filter((entry) => entry.entry_type === "role_permission");
  const roles = entries.filter((entry) => entry.entry_type === "role" && entry.approval_state === "approved");
  const permissions = entries.filter((entry) => entry.entry_type === "permission" && entry.approval_state === "approved");
  return <>
    {!enabled && <p className="master-notice" role="note">Nenhuma alteração de papel ou concessão é permitida enquanto a habilitação explícita não for autorizada. Esta tela mostra o catálogo real em modo somente leitura.</p>}
    <div className="master-table-wrap" role="region" aria-label="Aprovações do catálogo" tabIndex={0}>
      <table className="master-table"><thead><tr><th>Tipo</th><th>Identificador</th><th>Descrição</th><th>Escopo</th><th>Situação</th><th>Ação</th></tr></thead>
        <tbody>{manageable.map((entry) => <tr key={`${entry.entry_type}:${entry.role_key ?? entry.permission_key ?? entry.transaction_code}`}>
          <td>{label[entry.entry_type]}</td>
          <td><code>{entry.role_key ?? entry.permission_key ?? entry.transaction_code}</code></td>
          <td>{entry.display_name}</td><td>{entry.scope ?? "—"}</td>
          <td><span className={`master-badge${entry.approval_state === "approved" ? " is-positive" : entry.approval_state === "retired" ? " is-negative" : ""}`}>{label[entry.approval_state] ?? entry.approval_state}</span></td>
          <td><CatalogApproval entry={entry} enabled={enabled} /></td>
        </tr>)}</tbody>
      </table>
    </div>
    <section className="master-subsection"><h3>Concessões por papel</h3><p>Uma concessão só é permitida depois da aprovação independente do papel e da permissão. A revogação remove a autorização imediatamente.</p>
      <RoleGrantForm roles={roles} permissions={permissions} enabled={enabled} />
      {grants.length ? <div className="master-table-wrap" role="region" aria-label="Concessões existentes" tabIndex={0}><table className="master-table"><thead><tr><th>Papel</th><th>Permissão</th><th>Escopo</th><th>Situação</th><th>Ação</th></tr></thead><tbody>{grants.map((entry) => <tr key={`${entry.role_key}:${entry.permission_key}`}><td><code>{entry.role_key}</code></td><td><code>{entry.permission_key}</code></td><td>{entry.scope ?? "—"}</td><td>{entry.approval_state}</td><td><GrantRevoke roleKey={entry.role_key!} permissionKey={entry.permission_key!} enabled={enabled} /></td></tr>)}</tbody></table></div> : <p className="master-panel-empty">Nenhuma concessão efetiva foi registrada.</p>}
    </section>
  </>;
}

function CatalogApproval({ entry, enabled }: { entry: MasterAccessControlEntry; enabled: boolean }) {
  const [state, action, pending] = useActionState(setAccessCatalogApprovalAction, masterAccessIdle);
  const key = entry.role_key ?? entry.permission_key ?? entry.transaction_code ?? "";
  const target = entry.approval_state === "approved" ? "pending_approval" : "approved";
  return <form action={action} className="master-inline-action"><input type="hidden" name="item_type" value={entry.entry_type} /><input type="hidden" name="item_key" value={key} /><input type="hidden" name="approval_state" value={target} />
    <input aria-label={`Confirmar alteração de ${key}`} name="confirmed" required type="checkbox" disabled={!enabled || pending} />
    <button className="master-row-link" type="submit" disabled={!enabled || pending}>{target === "approved" ? "Aprovar" : "Voltar a pendente"}</button>
    {state.message && <span role={state.status === "success" ? "status" : "alert"}>{state.message}</span>}
  </form>;
}

function RoleGrantForm({ roles, permissions, enabled }: { roles: MasterAccessControlEntry[]; permissions: MasterAccessControlEntry[]; enabled: boolean }) {
  const [state, action, pending] = useActionState(setRolePermissionGrantAction, masterAccessIdle);
  if (!roles.length || !permissions.length) return <p className="master-panel-empty">A aprovação de um papel e uma permissão é necessária antes de criar grants.</p>;
  return <form action={action} className="master-filter-form"><label>Papel<select name="role_key" required defaultValue=""><option value="" disabled>Selecione</option>{roles.map((role) => <option key={role.role_key} value={role.role_key!}>{role.role_key}</option>)}</select></label><label>Permissão<select name="permission_key" required defaultValue=""><option value="" disabled>Selecione</option>{permissions.map((permission) => <option key={permission.permission_key} value={permission.permission_key!}>{permission.permission_key}</option>)}</select></label><input type="hidden" name="operation" value="grant" /><label className="master-confirmation"><input name="confirmed" required type="checkbox" disabled={!enabled || pending} /> Confirmo a concessão</label><button type="submit" disabled={!enabled || pending}>{pending ? "Registrando…" : "Conceder permissão"}</button>{state.message && <span role={state.status === "success" ? "status" : "alert"}>{state.message}</span>}</form>;
}

function GrantRevoke({ roleKey, permissionKey, enabled }: { roleKey: string; permissionKey: string; enabled: boolean }) {
  const [state, action, pending] = useActionState(setRolePermissionGrantAction, masterAccessIdle);
  return <form action={action} className="master-inline-action"><input type="hidden" name="role_key" value={roleKey} /><input type="hidden" name="permission_key" value={permissionKey} /><input type="hidden" name="operation" value="revoke" /><input aria-label={`Confirmar revogação de ${permissionKey}`} name="confirmed" required type="checkbox" disabled={!enabled || pending} /><button className="master-row-link" type="submit" disabled={!enabled || pending}>{pending ? "Revogando…" : "Revogar"}</button>{state.message && <span role={state.status === "success" ? "status" : "alert"}>{state.message}</span>}</form>;
}
