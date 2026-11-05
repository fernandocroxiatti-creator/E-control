"use client";

import Link from "next/link";
import { useMemo, useState } from "react";
import type { AuthorizedTransactionContext, OperationalContextStatus } from "@/lib/companies/authorized-transaction-context";
import { operationalContextMessage } from "@/lib/companies/authorized-transaction-context";

type WorkspaceView = "companies" | "new-company" | "branches" | "new-branch";
type CompanyRow = { tenantId: string; companyName: string; branches: AuthorizedTransactionContext[] };

function companyRows(contexts: AuthorizedTransactionContext[]) {
  const rows = new Map<string, CompanyRow>();
  for (const context of contexts) {
    const row = rows.get(context.tenantId) ?? { tenantId: context.tenantId, companyName: context.companyName, branches: [] };
    row.branches.push(context);
    rows.set(context.tenantId, row);
  }
  return [...rows.values()].sort((left, right) => left.companyName.localeCompare(right.companyName, "pt-BR"));
}

function contextHref(path: string, context: AuthorizedTransactionContext) {
  const query = new URLSearchParams({ empresa: context.tenantId, filial: context.branchId });
  return `${path}?${query.toString()}`;
}

export function CompaniesWorkspace({ view, contexts, accessStatus, operationalEnabled, selectedCompanyId }: {
  view: WorkspaceView;
  contexts: AuthorizedTransactionContext[];
  accessStatus: OperationalContextStatus;
  operationalEnabled: boolean;
  selectedCompanyId?: string;
}) {
  const [query, setQuery] = useState("");
  const rows = useMemo(() => companyRows(contexts), [contexts]);
  const filteredRows = rows.filter((row) => row.companyName.toLocaleLowerCase("pt-BR").includes(query.trim().toLocaleLowerCase("pt-BR")));
  const selected = rows.find((row) => row.tenantId === selectedCompanyId) ?? rows[0];
  const operationalLabel = operationalEnabled ? "Ambiente operacional habilitado" : "Ativação operacional pendente";

  if (view === "new-company") return <UnavailableWrite title="Cadastro de empresas" description="A criação de empresas é uma operação global do Admin Master. Nenhuma empresa pode ser criada a partir do painel empresarial." href="/empresas" />;
  if (view === "new-branch") return <UnavailableWrite title="Cadastro de filiais" description="Esta sessão pode consultar as filiais autorizadas. A criação empresarial de filiais aguarda uma RPC específica, com autorização e auditoria, e não será simulada pela interface." href="/empresas/filiais" />;

  const isBranches = view === "branches";
  return <>
    <div className="page-heading-row companies-heading">
      <div><p className="page-kicker">E-CONTROL / EMPRESAS E FILIAIS</p><h1>{isBranches ? "Filiais autorizadas" : "Empresas autorizadas"}</h1><p className="page-subtitle">Empresas e filiais visíveis exclusivamente pelo vínculo empresarial da sua sessão.</p></div>
      <span className="workspace-badge"><span className="environment-dot" /> {operationalLabel}</span>
    </div>
    <div className="companies-subnav" aria-label="Navegação de empresas e filiais"><Link className={!isBranches ? "is-current" : ""} href="/empresas" aria-current={!isBranches ? "page" : undefined}>Empresas</Link><Link className={isBranches ? "is-current" : ""} href="/empresas/filiais" aria-current={isBranches ? "page" : undefined}>Filiais</Link></div>
    {!contexts.length ? <section className="master-notice" role="status"><strong>Contexto empresarial indisponível</strong><p>{operationalContextMessage(accessStatus)}</p><p>Quando o convite for aceito, o vínculo estiver ativo e uma filial for autorizada, a empresa aparecerá aqui automaticamente.</p></section> : <>
      <section className="master-data-panel"><header><div><h2>{isBranches ? "Empresa ativa" : "Empresas disponíveis"}</h2><p>{isBranches ? "Escolha uma empresa autorizada para consultar somente as filiais ativas às quais sua sessão possui acesso." : "A lista não utiliza dados demonstrativos e não expõe empresas de terceiros."}</p></div></header>
        {!isBranches && <label className="companies-search" htmlFor="company-search"><span aria-hidden="true">⌕</span><input id="company-search" type="search" placeholder="Pesquisar empresa autorizada" value={query} onChange={(event) => setQuery(event.target.value)} /></label>}
        {!isBranches ? <div className="master-company-picker">{filteredRows.map((row) => <Link className={`master-company-choice${row.tenantId === selected?.tenantId ? " is-selected" : ""}`} key={row.tenantId} href={`/empresas/filiais?empresa=${encodeURIComponent(row.tenantId)}`}><span><strong>{row.companyName}</strong><small>{row.branches.length} filial(is) autorizada(s)</small></span><span aria-hidden="true">→</span></Link>)}</div> : <CompanySelector rows={rows} selected={selected?.tenantId} />}
        {!filteredRows.length && !isBranches && <p className="master-panel-empty">Nenhuma empresa autorizada corresponde à busca.</p>}
      </section>
      {isBranches && selected && <section className="master-data-panel"><header><div><h2>{selected.companyName}</h2><p>Filiais ativas liberadas para seu vínculo empresarial.</p></div></header><div className="master-table-wrap" tabIndex={0}><table className="master-table"><thead><tr><th>Código</th><th>Filial</th><th>Situação</th><th>Abrir</th></tr></thead><tbody>{selected.branches.map((branch) => <tr key={branch.branchId}><td><code>{branch.branchCode}</code></td><td><strong>{branch.branchName}</strong></td><td><span className="master-badge is-positive">Autorizada</span></td><td><Link className="master-row-link" href={contextHref("/operacional/cadastros", branch)}>Usar contexto</Link></td></tr>)}</tbody></table></div></section>}
      {!operationalEnabled && <section className="master-notice" role="note"><strong>Contexto reconhecido; operações ainda protegidas</strong><p>As empresas e filiais já são exibidas pela autorização persistente. Cadastros, estoque, compras e O.S. só serão gravados após a ativação explícita do ambiente operacional e as permissões efetivas do papel.</p></section>}
    </>}
  </>;
}

function CompanySelector({ rows, selected }: { rows: CompanyRow[]; selected?: string }) {
  return <form className="master-filter-form" method="get"><label>Empresa<select name="empresa" defaultValue={selected ?? ""}>{rows.map((row) => <option key={row.tenantId} value={row.tenantId}>{row.companyName}</option>)}</select></label><button type="submit">Consultar filiais</button></form>;
}

function UnavailableWrite({ title, description, href }: { title: string; description: string; href: string }) {
  return <><div className="page-heading-row companies-heading"><div><p className="page-kicker">E-CONTROL / EMPRESAS E FILIAIS</p><h1>{title}</h1><p className="page-subtitle">{description}</p></div><span className="workspace-badge">Ação não disponível</span></div><section className="master-notice"><strong>Nenhum formulário demonstrativo foi exibido</strong><p>{description}</p><Link className="master-row-link" href={href}>Voltar à consulta autorizada</Link></section></>;
}
