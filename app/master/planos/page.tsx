import Link from "next/link";
import { requireMasterUser } from "@/lib/master/authorization";
import { createClient } from "@/lib/supabase/server";
import type { SaasData } from "@/lib/erp-completion/read-model";
import { CompletionForm } from "@/app/components/completion-form";
export const dynamic = "force-dynamic";
export default async function SaasPage() {
  await requireMasterUser(); const client = await createClient();
  const result = client ? await client.rpc("master_get_saas_control_plane") : null;
  const data = result && !result.error ? result.data as SaasData : null;
  return <><h1>Planos e assinaturas</h1><p>Gestão comercial manual. Ativar uma assinatura não ativa empresas, não concede permissões e não substitui a homologação pelo Admin Master. Limites são conferidos na ativação; cobrança e bloqueio por inadimplência não são automáticos.</p>
    {!data ? <p className="master-notice">Controle SaaS indisponível. Verifique a implantação autorizada.</p> : <><CompletionForm command="plan" /><CompletionForm command="subscription" options={{ tenant_id: data.companies.map(c => ({ id: c.id, name: c.name })), plan_id: data.plans.map(p => ({ id: p.id, name: `${p.code} · ${p.name} (${p.status})` })) }} />
      <h2>Planos</h2><table className="master-table"><thead><tr><th>Código</th><th>Nome</th><th>Situação</th><th>Filiais</th><th>Usuários</th></tr></thead><tbody>{data.plans.map(p => <tr key={p.id}><td>{p.code}</td><td>{p.name}</td><td>{p.status}</td><td>{p.max_branches ?? "Ilimitado"}</td><td>{p.max_users ?? "Ilimitado"}</td></tr>)}</tbody></table>
      <h2>Assinaturas</h2><table className="master-table"><thead><tr><th>Empresa</th><th>Plano</th><th>Situação</th><th>Início</th><th>Encerramento</th></tr></thead><tbody>{data.subscriptions.map(s => <tr key={s.id}><td>{data.companies.find(c => c.id === s.tenant_id)?.name}</td><td>{data.plans.find(p => p.id === s.plan_id)?.name}</td><td>{s.status}</td><td>{s.starts_at ?? "Pendente"}</td><td>{s.ends_at ?? "—"}</td></tr>)}</tbody></table>
      <h2>Onboarding empresarial</h2><p><Link href="/master/nova-empresa">Cadastrar empresa e preparar convite do administrador</Link></p><table className="master-table"><thead><tr><th>Empresa</th><th>Situação</th><th>Filiais ativas</th><th>Vínculos ativos</th><th>Revisão</th></tr></thead><tbody>{data.companies.map(c => <tr key={c.id}><td>{c.name}</td><td>{c.status}</td><td>{c.branches}</td><td>{c.members}</td><td><Link href={`/master/empresas/${c.id}`}>Revisar acesso empresarial</Link></td></tr>)}</tbody></table>
      <h2>Últimos 100 eventos comerciais</h2><table className="master-table"><thead><tr><th>Quando</th><th>Empresa</th><th>Evento</th><th>Justificativa</th></tr></thead><tbody>{data.events.map(e => <tr key={e.id}><td>{e.created_at}</td><td>{data.companies.find(c => c.id === e.tenant_id)?.name}</td><td>{e.event_key}</td><td>{e.reason}</td></tr>)}</tbody></table></>}
  </>;
}
