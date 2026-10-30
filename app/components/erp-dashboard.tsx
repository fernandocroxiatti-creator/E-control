"use client";

import { useEffect, useMemo, useRef, useState, useTransition } from "react";
import Image from "next/image";
import { signOutAction } from "@/app/actions/auth";
import { lookupTransactionCode } from "@/app/actions/transaction-lookup";
import type { AuthorizedTransactionContext } from "@/lib/companies/authorized-transaction-context";

type ModuleItem = {
  id: string;
  label: string;
  icon: string;
  status: "overview" | "route" | "development";
  href?: string;
};

const modules: ModuleItem[] = [
  { id: "overview", label: "Visão geral", icon: "home", status: "overview" },
  { id: "companies", label: "Empresas e filiais", icon: "building", status: "route", href: "/empresas" },
  { id: "catalog", label: "Cadastros", icon: "clipboard", status: "route", href: "/operacional/cadastros" },
  { id: "inventory", label: "Estoque", icon: "box", status: "route", href: "/operacional/estoque" },
  { id: "purchases", label: "Compras", icon: "cart", status: "route", href: "/operacional/compras" },
  { id: "sales", label: "Vendas", icon: "receipt", status: "development" },
  { id: "finance", label: "Financeiro", icon: "wallet", status: "development" },
  { id: "accounting", label: "Contabilidade", icon: "book", status: "development" },
  { id: "reports", label: "Relatórios", icon: "chart", status: "development" },
  { id: "budgets", label: "Orçamentos", icon: "clipboard", status: "development" },
  { id: "users", label: "Usuários e permissões", icon: "users", status: "route", href: "/operacional/equipe" },
  { id: "settings", label: "Configurações", icon: "settings", status: "development" },
];

const tiles = [
  { title: "Empresas", icon: "building" },
  { title: "Filiais", icon: "building" },
  { title: "Estoque", icon: "box" },
  { title: "Compras", icon: "cart" },
  { title: "Vendas", icon: "receipt" },
  { title: "Financeiro", icon: "wallet" },
  { title: "Relatórios", icon: "chart" },
];

export function ErpDashboard({ email, showMasterAdmin = false, passwordUpdated = false, activeSection = "overview", transactionContexts = [], operationalEnabled = false, children }: { email: string; showMasterAdmin?: boolean; passwordUpdated?: boolean; activeSection?: string; transactionContexts?: AuthorizedTransactionContext[]; operationalEnabled?: boolean; children?: React.ReactNode }) {
  const [menuOpen, setMenuOpen] = useState(false);
  const [search, setSearch] = useState("");
  const [transactionCode, setTransactionCode] = useState("");
  const [transactionMessage, setTransactionMessage] = useState("");
  const [selectedTenantId, setSelectedTenantId] = useState(transactionContexts[0]?.tenantId ?? "");
  const [selectedBranchId, setSelectedBranchId] = useState(transactionContexts[0]?.branchId ?? "");
  const [isTransactionPending, startTransactionTransition] = useTransition();
  const searchInput = useRef<HTMLInputElement>(null);
  const filteredModules = useMemo(() => {
    const query = search.trim().toLocaleLowerCase("pt-BR");
    return query ? modules.filter((item) => item.label.toLocaleLowerCase("pt-BR").includes(query)) : modules;
  }, [search]);

  useEffect(() => {
    function focusModuleSearch(event: KeyboardEvent) {
      if ((event.metaKey || event.ctrlKey) && event.key.toLowerCase() === "k") {
        event.preventDefault();
        searchInput.current?.focus();
      }
    }

    window.addEventListener("keydown", focusModuleSearch);
    return () => window.removeEventListener("keydown", focusModuleSearch);
  }, []);

  async function handleTransaction(event: React.FormEvent<HTMLFormElement>) {
    event.preventDefault();
    const code = transactionCode.trim().toUpperCase();
    if (!code) {
      setTransactionMessage("");
      return;
    }

    if (!selectedTenantId || !selectedBranchId) {
      setTransactionMessage("Selecione uma empresa e uma filial autorizadas para consultar a transação.");
      return;
    }
    startTransactionTransition(async () => {
      try {
        const result = await lookupTransactionCode(code, selectedTenantId, selectedBranchId);
        setTransactionMessage(result.status === "authorized"
          ? `${code}: autorização confirmada para o contexto selecionado; a transação ainda não possui uma rotina operacional publicada.`
          : result.status === "denied" ? "Acesso negado para esta transação, empresa ou filial."
            : result.status === "context_required" ? "Selecione uma empresa e uma filial autorizadas."
              : result.status === "unknown" ? "Transação não encontrada."
                : result.status === "invalid" ? "Código de transação inválido."
                  : "Não foi possível verificar a autorização. O acesso permanece negado.");
      } catch {
        setTransactionMessage("Não foi possível verificar a autorização. O acesso permanece negado.");
      }
    });
  }

  const availableCompanies = [...new Map(transactionContexts.map((context) => [context.tenantId, context.companyName])).entries()];
  const availableBranches = transactionContexts.filter((context) => context.tenantId === selectedTenantId);

  return (
    <div className="erp-shell">
      <a className="skip-link" href="#main-content">Pular para o conteúdo</a>
      {menuOpen && <button className="sidebar-scrim" type="button" aria-label="Fechar menu" onClick={() => setMenuOpen(false)} />}

      <aside className={`erp-sidebar${menuOpen ? " is-open" : ""}`} aria-label="Navegação principal">
        <a className="erp-brand" href="/dashboard" aria-label="eControll, visão geral">
          <Image className="brand-mark brand-mark-image" src="/econtroll-logo.png" width={64} height={64} alt="" aria-hidden="true" />
          <span className="brand-wordmark">eControll<small>ERP · Gestão integrada</small></span>
        </a>

        <div className="sidebar-section-label">MENU PRINCIPAL</div>
        <nav className="module-nav" aria-label="Módulos do eControll">
          {filteredModules.map((item) => (
            <div className="nav-item-wrap" key={item.id}>
              {item.status === "overview" ? (
                <a className={`module-link${activeSection === "overview" ? " is-active" : ""}`} href="/dashboard" aria-current={activeSection === "overview" ? "page" : undefined} onClick={() => setMenuOpen(false)}>
                  <Icon name={item.icon} /> <span>{item.label}</span>
                </a>
              ) : item.status === "route" ? (
                <a className={`module-link${activeSection === item.id ? " is-active" : ""}`} href={item.href ?? "/dashboard"} aria-current={activeSection === item.id ? "page" : undefined} onClick={() => setMenuOpen(false)}>
                  <Icon name={item.icon} /> <span>{item.label}</span>
                </a>
              ) : (
                <button className="module-link is-disabled" type="button" disabled aria-label={`${item.label}: em desenvolvimento`}>
                  <Icon name={item.icon} /> <span>{item.label}</span>
                  <span className="nav-development-dot" aria-hidden="true" />
                </button>
              )}
            </div>
          ))}
          {filteredModules.length === 0 && <p className="nav-empty">Nenhum módulo encontrado.</p>}
        </nav>

          <div className="sidebar-bottom">
          <div className="sidebar-environment"><span className="environment-dot" /> {operationalEnabled && transactionContexts.length ? "Ambiente operacional" : transactionContexts.length ? "Acesso empresarial configurado" : "Ambiente de preparação"}</div>
          <form action={signOutAction}>
            <button className="sidebar-logout" type="submit"><Icon name="logout" /><span>Sair da conta</span></button>
          </form>
        </div>
      </aside>

      <div className="erp-main-column">
        <header className="erp-topbar">
          <button className="mobile-menu-button" type="button" aria-label={menuOpen ? "Fechar menu" : "Abrir menu"} aria-expanded={menuOpen} onClick={() => setMenuOpen((open) => !open)}>
            <Icon name={menuOpen ? "close" : "menu"} />
          </button>
          <div className="topbar-brand-mobile"><Image className="brand-mark brand-mark-image" src="/econtroll-logo.png" width={64} height={64} alt="" aria-hidden="true" /><span>eControll</span></div>

          <label className="global-search" htmlFor="module-search">
            <Icon name="search" />
            <input ref={searchInput} id="module-search" type="search" placeholder="Pesquisar módulos" value={search} onChange={(event) => setSearch(event.target.value)} />
            <span className="search-hint" aria-hidden="true">⌘ K</span>
          </label>

          <form className="transaction-search" onSubmit={handleTransaction}>
            <label htmlFor="transaction-code">Acesso rápido</label>
            <div className="transaction-context-selects">
              <select aria-label="Empresa para autorização de transação" value={selectedTenantId} onChange={(event) => {
                const tenantId = event.target.value;
                const firstBranch = transactionContexts.find((context) => context.tenantId === tenantId);
                setSelectedTenantId(tenantId);
                setSelectedBranchId(firstBranch?.branchId ?? "");
              }} disabled={availableCompanies.length === 0}>
                <option value="">Empresa</option>{availableCompanies.map(([tenantId, companyName]) => <option key={tenantId} value={tenantId}>{companyName}</option>)}
              </select>
              <select aria-label="Filial para autorização de transação" value={selectedBranchId} onChange={(event) => setSelectedBranchId(event.target.value)} disabled={availableBranches.length === 0}>
                <option value="">Filial</option>{availableBranches.map((context) => <option key={context.branchId} value={context.branchId}>{context.branchCode} · {context.branchName}</option>)}
              </select>
            </div>
            <div className="transaction-input-wrap">
              <input id="transaction-code" type="text" autoCapitalize="characters" autoComplete="off" spellCheck={false} maxLength={20} placeholder="Código · ex. ME21N" value={transactionCode} onChange={(event) => setTransactionCode(event.target.value)} aria-describedby="transaction-result" />
              <button type="submit" aria-label="Pesquisar código de transação" disabled={isTransactionPending || availableCompanies.length === 0}><Icon name="arrow" /></button>
            </div>
          </form>

          <details className="topbar-account-menu">
            <summary className="topbar-user" aria-label="Menu da conta">
              <span className="user-avatar" aria-hidden="true">{email.charAt(0).toLocaleUpperCase("pt-BR") || "U"}</span>
              <span className="topbar-user-email">{email}</span>
            </summary>
            {showMasterAdmin && <nav className="account-menu-items" aria-label="Opções da conta"><a href="/master">Admin Master</a></nav>}
          </details>
        </header>

        <main id="main-content" className="erp-content">
          {passwordUpdated && <p className="form-message success dashboard-password-message" role="status">Senha atualizada.</p>}
          <div id="transaction-result" className={`transaction-feedback${transactionMessage ? " is-visible" : ""}`} role="status" aria-live="polite">{transactionMessage}</div>
          {children ?? <DashboardOverview transactionContexts={transactionContexts} operationalEnabled={operationalEnabled} />}
        </main>
      </div>
    </div>
  );
}

function DashboardOverview({ transactionContexts, operationalEnabled }: { transactionContexts: AuthorizedTransactionContext[]; operationalEnabled: boolean }) {
  const activeContext = transactionContexts[0];
  const operationalReady = operationalEnabled && Boolean(activeContext);
  return (
    <>
      <div className="page-heading-row">
        <div><p className="page-kicker">E-CONTROL / VISÃO GERAL</p><h1>Visão geral</h1><p className="page-subtitle">Seu espaço de trabalho para a gestão integrada.</p></div>
        <span className="workspace-badge"><span className="environment-dot" /> {operationalReady ? "Ambiente operacional" : activeContext ? "Empresa autorizada" : "Ambiente de preparação"}</span>
      </div>
      <section className="readiness-banner" aria-labelledby="readiness-title">
        <span className="readiness-icon"><Icon name="shield" /></span>
        {operationalReady ? <div><h2 id="readiness-title">Acesso empresarial ativo</h2><p>{activeContext.companyName} · {activeContext.branchCode} — {activeContext.branchName}. Cadastros e estoque são liberados conforme as transações autorizadas.</p></div>
          : activeContext ? <div><h2 id="readiness-title">Empresa autorizada</h2><p>{activeContext.companyName} · {activeContext.branchCode} — {activeContext.branchName}. As operações aguardam a habilitação explícita do ambiente.</p></div>
            : <div><h2 id="readiness-title">Ambiente em preparação</h2><p>Os módulos empresariais serão disponibilizados após a configuração e validação dos controles de acesso e isolamento.</p></div>}
        <span className="readiness-status">{operationalReady ? "Operações disponíveis" : activeContext ? "Operações aguardando habilitação" : "Acesso operacional bloqueado"}</span>
      </section>
      <section className="module-overview" aria-labelledby="modules-title">
        <div className="section-heading"><div><h2 id="modules-title">Áreas de gestão</h2><p>Visão dos módulos planejados para o eControll.</p></div><span className="section-count">{tiles.length} áreas</span></div>
        <div className="overview-grid">
          {tiles.map((tile) => (
            <article className="overview-tile" key={tile.title}>
              <div className="tile-icon"><Icon name={tile.icon} /></div>
              <h3>{tile.title}</h3>
              <p>{operationalReady && (tile.title === "Estoque" || tile.title === "Empresas" || tile.title === "Filiais") ? "Disponível conforme suas permissões." : "Disponível após configuração da empresa."}</p>
              <span className="tile-status"><span className="status-dot" /> {operationalReady && (tile.title === "Estoque" || tile.title === "Empresas" || tile.title === "Filiais") ? "Disponível" : "Em desenvolvimento"}</span>
            </article>
          ))}
        </div>
      </section>
      <footer className="erp-footer"><span>eControll ERP</span><span>{operationalReady ? "Contexto empresarial autorizado" : "Área de preparação · Nenhum dado operacional carregado"}</span></footer>
    </>
  );
}

function Icon({ name }: { name: string }) {
  const common = { fill: "none", stroke: "currentColor", strokeWidth: 1.8, strokeLinecap: "round" as const, strokeLinejoin: "round" as const, "aria-hidden": true as const };
  const paths: Record<string, React.ReactNode> = {
    home: <><path d="m3 10 9-7 9 7" /><path d="M5 9v11h14V9M9 20v-6h6v6" /></>,
    building: <><rect x="4" y="3" width="16" height="18" rx="2" /><path d="M9 7h2m2 0h2M9 11h2m2 0h2M9 15h2m2 0h2M10 21v-3h4v3" /></>,
    box: <><path d="m12 3 9 5-9 5-9-5 9-5Z" /><path d="m3 8 9 5 9-5M3 8v9l9 5 9-5V8M12 13v9" /></>,
    cart: <><path d="M3 4h2l2.2 11.2a2 2 0 0 0 2 1.6h7.9a2 2 0 0 0 1.9-1.4L21 9H6" /><circle cx="10" cy="20" r="1" /><circle cx="18" cy="20" r="1" /></>,
    receipt: <><path d="M5 3h14v18l-3-2-4 2-4-2-3 2V3Z" /><path d="M8 8h8M8 12h8M8 16h4" /></>,
    wallet: <><rect x="3" y="5" width="18" height="15" rx="2" /><path d="M3 8h15a2 2 0 0 1 2 2v2h-5a2 2 0 0 0 0 4h5" /><path d="M16 14h.01" /></>,
    book: <><path d="M4 4.5A2.5 2.5 0 0 1 6.5 2H20v17H6.5A2.5 2.5 0 0 0 4 21.5v-17Z" /><path d="M4 17a2.5 2.5 0 0 1 2.5-2.5H20M8 6h7" /></>,
    chart: <><path d="M4 19V5M4 19h17" /><path d="m7 15 4-4 3 2 6-7" /><path d="M16 6h4v4" /></>,
    clipboard: <><rect x="5" y="4" width="14" height="17" rx="2" /><path d="M9 4.5V3h6v1.5M8 10h8M8 14h8M8 18h5" /></>,
    users: <><circle cx="9" cy="8" r="3" /><path d="M3 20v-1a6 6 0 0 1 12 0v1M16 5a3 3 0 0 1 0 6m2 3a5 5 0 0 1 3 5v1" /></>,
    settings: <><circle cx="12" cy="12" r="3" /><path d="m19.4 15 .1.1 1.3 1-1.5 2.6-1.6-.6a7.5 7.5 0 0 1-1.6.9l-.3 1.7h-3l-.3-1.7a7.5 7.5 0 0 1-1.6-.9l-1.6.6-1.5-2.6 1.3-1a7.3 7.3 0 0 1 0-1.9l-1.3-1 1.5-2.6 1.6.6a7.5 7.5 0 0 1 1.6-.9l.3-1.7h3l.3 1.7a7.5 7.5 0 0 1 1.6.9l1.6-.6 1.5 2.6-1.3 1a7.3 7.3 0 0 1 0 1.9Z" /></>,
    search: <><circle cx="10.8" cy="10.8" r="6.3" /><path d="m16 16 4.5 4.5" /></>,
    arrow: <><path d="M4 12h15M13 6l6 6-6 6" /></>,
    shield: <><path d="M12 3 20 6v5c0 5-3.4 8.5-8 10-4.6-1.5-8-5-8-10V6l8-3Z" /><path d="m9 12 2 2 4-4" /></>,
    logout: <><path d="M10 17l5-5-5-5M15 12H3" /><path d="M12 3h7a2 2 0 0 1 2 2v14a2 2 0 0 1-2 2h-7" /></>,
    menu: <><path d="M4 6h16M4 12h16M4 18h16" /></>,
    close: <><path d="m6 6 12 12M18 6 6 18" /></>,
  };

  return <svg {...common} className="ui-icon" viewBox="0 0 24 24" width="20" height="20">{paths[name] ?? paths.home}</svg>;
}
