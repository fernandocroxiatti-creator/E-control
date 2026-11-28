import Link from "next/link";
import { createClient } from "@/lib/supabase/server";
import { subscriptionStatus, type CompanySubscription } from "@/lib/saas/input";
export const dynamic="force-dynamic";
export default async function CompanySubscriptionPage({searchParams}:{searchParams:Promise<{empresa?:string}>}){
 const search=await searchParams;const client=await createClient();if(!client)return <p>Consulta de assinatura indisponível.</p>;
 const {data:{user},error}=await client.auth.getUser();if(error||!user)return <p>Sessão indisponível.</p>;
 const {data:memberships,error:membershipError}=await client.from("company_memberships").select("tenant_id").eq("user_id",user.id).eq("status","active");
 if(membershipError||!memberships?.length)return <p>Não há vínculo empresarial ativo para consultar a assinatura.</p>;
 const ids=[...new Set(memberships.map(m=>String(m.tenant_id)))];
 const {data:companies,error:companyError}=await client.from("companies").select("id,legal_name").in("id",ids);
 if(companyError||!companies?.length)return <p>Não foi possível consultar as empresas autorizadas.</p>;
 const selected=search.empresa?companies.find(c=>c.id===search.empresa):companies[0];
 const result=selected?await client.rpc("company_get_saas_subscription",{p_tenant_id:selected.id}):null;
 const data=result&&!result.error?result.data as CompanySubscription:null;
 return <><h1>Minha assinatura</h1><form className="master-filter-form"><label>Empresa<select name="empresa" defaultValue={selected?.id??""}>{companies.map(c=><option key={c.id} value={c.id}>{c.legal_name}</option>)}</select></label><button>Consultar</button></form>{data?<section className="master-data-panel"><h2>{selected?.legal_name}</h2><dl><dt>Plano contratado</dt><dd>{data.plan??"Sem assinatura cadastrada"}</dd><dt>Situação</dt><dd>{data.status?subscriptionStatus[data.status]??data.status:"Não contratado"}</dd><dt>Vencimento</dt><dd>{data.due_on??"Não definido"}</dd><dt>Tolerância</dt><dd>{data.grace_days} dias</dd><dt>Filiais ativas</dt><dd>{data.branches_used} / {data.max_branches??"Sem limite contratado"}</dd><dt>Usuários ativos e pendentes</dt><dd>{data.users_used} / {data.max_users??"Sem limite contratado"}</dd><dt>Acesso comercial</dt><dd>{data.operational_allowed?"Sem bloqueio comercial; sujeito às permissões empresariais":"Operações bloqueadas. Solicite regularização ao Admin Master."}</dd></dl><p>A assinatura não concede permissões. Alterações de plano, vencimento e reativação são realizadas pelo Admin Master. Esta consulta permanece disponível durante o bloqueio comercial.</p><Link href="/empresas">Voltar às empresas</Link></section>:<p className="master-notice">Não foi possível consultar a assinatura desta empresa.</p>}</>;
}
