import Link from "next/link";
import { signOutAction } from "@/app/actions/auth";

const masterNavigation = [
  { href: "/master", label: "Visão geral", icon: "⌂" },
  { href: "/master/empresas", label: "Empresas clientes", icon: "▦" },
  { href: "/master/planos", label: "Planos e assinaturas", icon: "◇" },
  { href: "/master/modulos", label: "Catálogo de módulos", icon: "▤" },
  { href: "/master/transacoes", label: "Catálogo de transações", icon: "⇄" },
  { href: "/master/administradores", label: "Administradores", icon: "♙" },
  { href: "/master/solicitacoes", label: "Solicitações", icon: "◷" },
  { href: "/master/suporte", label: "Suporte autorizado", icon: "◉" },
  { href: "/master/auditoria", label: "Auditoria", icon: "≋" },
  { href: "/master/configuracoes", label: "Configurações SaaS", icon: "⚙" },
];

export function MasterShell({ email, children }: { email: string; children: React.ReactNode }) {
  return (
    <div className="master-shell">
      <a className="master-skip-link" href="#master-main">Pular para o conteúdo</a>
      <aside className="master-sidebar" aria-label="Navegação Admin Master">
        <Brand />
        <p className="master-nav-label">ADMINISTRAÇÃO SAAS</p>
        <nav className="master-nav">
          {masterNavigation.map((item) => (
            <Link className="master-nav-link" href={item.href} key={item.href}>
              <span aria-hidden="true" className="master-nav-icon">{item.icon}</span>
              <span>{item.label}</span>
            </Link>
          ))}
        </nav>
        <div className="master-sidebar-footer">
          <span className="master-environment"><span className="master-dot" /> Área administrativa</span>
          <form action={signOutAction}>
            <button className="master-logout" type="submit">Sair da conta</button>
          </form>
        </div>
      </aside>

      <div className="master-main-column">
        <header className="master-topbar">
          <Brand compact />
          <details className="master-mobile-menu">
            <summary>Menu Master</summary>
            <nav aria-label="Navegação Admin Master móvel" className="master-mobile-links">
              {masterNavigation.map((item) => <Link href={item.href} key={item.href}>{item.label}</Link>)}
            </nav>
          </details>
          <div className="master-user" title={email}>
            <span className="master-user-avatar" aria-hidden="true">{email.charAt(0).toLocaleUpperCase("pt-BR") || "A"}</span>
            <span><strong>Admin Master</strong><small>{email}</small></span>
          </div>
        </header>
        <main id="master-main" className="master-content">{children}</main>
        <footer className="master-footer"><span>eControl · Administração SaaS</span><span>Operações administrativas indisponíveis nesta etapa</span></footer>
      </div>
    </div>
  );
}

function Brand({ compact = false }: { compact?: boolean }) {
  return (
    <Link className={`master-brand${compact ? " is-compact" : ""}`} href="/master" aria-label="eControl Admin Master, início">
      <span className="master-brand-mark" aria-hidden="true">e</span>
      <span className="master-brand-name">eControl<small>ADMIN MASTER</small></span>
    </Link>
  );
}

export function MasterSection({ title, description, actionLabel }: { title: string; description: string; actionLabel?: string }) {
  return (
    <>
      <div className="master-heading-row">
        <div><p className="master-eyebrow">ADMINISTRAÇÃO SAAS</p><h1>{title}</h1><p className="master-subtitle">{description}</p></div>
        {actionLabel && <button className="master-action" type="button" disabled aria-disabled="true">{actionLabel}<span aria-hidden="true">＋</span></button>}
      </div>
      <section className="master-notice" aria-label="Estado da área administrativa">
        <span className="master-notice-icon" aria-hidden="true">◇</span>
        <div><strong>Área visual em preparação</strong><p>As operações administrativas serão habilitadas somente após autorização e validação dos controles correspondentes.</p></div>
        <span className="master-status">Sem dados carregados</span>
      </section>
      <section className="master-empty-state" aria-live="polite">
        <span className="master-empty-icon" aria-hidden="true">⌕</span>
        <h2>Nenhum registro carregado</h2>
        <p>Esta tela ainda não consulta nem altera dados. Nenhuma informação de empresas, valores ou eventos foi simulada.</p>
      </section>
    </>
  );
}

export function MasterDashboard() {
  const areas = ["Empresas clientes", "Planos e assinaturas", "Módulos", "Transações", "Administradores", "Solicitações", "Suporte", "Auditoria"];
  return (
    <>
      <div className="master-heading-row">
        <div><p className="master-eyebrow">ADMINISTRAÇÃO SAAS</p><h1>Painel Admin Master</h1><p className="master-subtitle">Visão administrativa do eControl.</p></div>
        <span className="master-status"><span className="master-dot" /> Interface sem operações</span>
      </div>
      <section className="master-notice" aria-labelledby="master-ready-title">
        <span className="master-notice-icon" aria-hidden="true">◇</span>
        <div><strong id="master-ready-title">Painel visual em preparação</strong><p>Os recursos administrativos permanecem desabilitados até a implementação e validação dos controles de autorização.</p></div>
      </section>
      <section className="master-area-section" aria-labelledby="master-areas-title">
        <div className="master-section-heading"><div><h2 id="master-areas-title">Áreas administrativas</h2><p>Atalhos para as telas preparadas.</p></div><span>Sem métricas operacionais</span></div>
        <div className="master-area-grid">
          {areas.map((area, index) => <article className="master-area-card" key={area}><span className="master-area-number">{String(index + 1).padStart(2, "0")}</span><h3>{area}</h3><p>Disponível após validação administrativa.</p></article>)}
        </div>
      </section>
    </>
  );
}
