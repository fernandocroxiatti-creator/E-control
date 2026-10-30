import Link from "next/link";
import Image from "next/image";
import { signOutAction } from "@/app/actions/auth";
import { getMasterOverview } from "@/lib/master/read-model";
import { BackendUnavailable, DataPanel, MetricCards } from "@/app/master/master-data-ui";

const masterNavigation = [
  { href: "/master", label: "Visão geral", icon: "⌂" },
  { href: "/master/empresas", label: "Empresas", icon: "▦" },
  { href: "/master/filiais", label: "Filiais", icon: "⌑" },
  { href: "/master/administradores", label: "Usuários", icon: "♙" },
  { href: "/master/modulos", label: "Módulos", icon: "▤" },
  { href: "/master/transacoes", label: "Transações", icon: "⇄" },
  { href: "/master/permissoes", label: "Permissões", icon: "◇" },
  { href: "/master/acessos-por-empresa", label: "Acessos por empresa", icon: "▤" },
  { href: "/master/auditoria", label: "Auditoria", icon: "≋" },
  { href: "/master/planos", label: "Planos e assinaturas", icon: "◇" },
  { href: "/master/solicitacoes", label: "Solicitações", icon: "⌁" },
  { href: "/master/suporte", label: "Suporte", icon: "?" },
  { href: "/master/configuracoes", label: "Configurações", icon: "⚙" },
];

export function MasterShell({ email, children }: { email: string; children: React.ReactNode }) {
  return (
    <div className="master-shell">
      <a className="master-skip-link" href="#master-main">Pular para o conteúdo</a>
      <aside className="master-sidebar" aria-label="Navegação Admin Master">
        <Brand />
        <p className="master-nav-label">ADMINISTRAÇÃO SAAS</p>
        <nav className="master-nav">{masterNavigation.map((item) => <Link className="master-nav-link" href={item.href} key={item.href}><span aria-hidden="true" className="master-nav-icon">{item.icon}</span><span>{item.label}</span></Link>)}</nav>
        <div className="master-sidebar-footer"><span className="master-environment"><span className="master-dot" /> Área administrativa</span><Link className="master-back-operational" href="/dashboard">Voltar ao painel operacional</Link><form action={signOutAction}><button className="master-logout" type="submit">Sair da conta</button></form></div>
      </aside>
      <div className="master-main-column">
        <header className="master-topbar"><Brand compact /><details className="master-mobile-menu"><summary>Admin Master</summary><nav aria-label="Navegação Admin Master móvel" className="master-mobile-links"><Link href="/dashboard">Painel operacional</Link>{masterNavigation.map((item) => <Link href={item.href} key={item.href}>{item.label}</Link>)}</nav></details><div className="master-user" title={email}><span className="master-user-avatar" aria-hidden="true">{email.charAt(0).toLocaleUpperCase("pt-BR") || "A"}</span><span><strong>Admin Master</strong><small>{email}</small></span></div></header>
        <main id="master-main" className="master-content">{children}</main>
        <footer className="master-footer"><span>eControll · Administração SaaS</span><span>Gestão cadastral separada do acesso operacional</span></footer>
      </div>
    </div>
  );
}

function Brand({ compact = false }: { compact?: boolean }) {
  return <Link className={`master-brand${compact ? " is-compact" : ""}`} href="/master" aria-label="eControll Admin Master, início"><Image className="master-brand-mark" src="/econtroll-logo.png" width={64} height={64} alt="" aria-hidden="true" /><span className="master-brand-name">eControll<small>ADMIN MASTER</small></span></Link>;
}

export async function MasterDashboard() {
  const result = await getMasterOverview();
  return <>
    <div className="master-heading-row"><div><p className="master-eyebrow">ADMINISTRAÇÃO SAAS</p><h1>Painel Admin Master</h1><p className="master-subtitle">Visão de controle do SaaS. O acesso operacional das empresas permanece isolado.</p></div><span className="master-status"><span className="master-dot" /> Sessão Master autorizada</span></div>
    {result.status === "ready" ? <><MetricCards data={result.data} /><div className="master-dashboard-columns"><DataPanel title="Eventos recentes do Admin Master" description="Somente tipo e data; detalhes sensíveis não são retornados.">{result.data.master_events_recent.length ? <ul className="master-event-list">{result.data.master_events_recent.map((event, index) => <li key={`${event.event_key}:${event.created_at}:${index}`}><code>{event.event_key}</code><time dateTime={event.created_at}>{new Date(event.created_at).toLocaleString("pt-BR")}</time></li>)}</ul> : <p className="master-panel-empty">Nenhum evento Master registrado.</p>}</DataPanel><DataPanel title="Provisionamento recente" description="Eventos resumidos sem detalhes de tenant ou identidade.">{result.data.provisioning_events_recent.length ? <ul className="master-event-list">{result.data.provisioning_events_recent.map((event, index) => <li key={`${event.event_key}:${event.created_at}:${index}`}><code>{event.event_key}</code><time dateTime={event.created_at}>{new Date(event.created_at).toLocaleString("pt-BR")}</time></li>)}</ul> : <p className="master-panel-empty">Nenhum evento de provisionamento disponível.</p>}</DataPanel></div></> : <BackendUnavailable item="As métricas e a auditoria resumida" />}
    <DataPanel title="Acesso rápido" description="Atalhos para consultas administrativas disponíveis."><div className="master-quick-links"><Link href="/master/empresas">Consultar empresas <span aria-hidden="true">→</span></Link><Link href="/master/filiais">Consultar filiais <span aria-hidden="true">→</span></Link><Link href="/master/permissoes">Ver catálogo de permissões <span aria-hidden="true">→</span></Link><Link href="/master/auditoria">Consultar auditoria <span aria-hidden="true">→</span></Link></div></DataPanel>
  </>;
}
