import Link from "next/link";
import type { ReactNode } from "react";
import type { MasterAuditItem, MasterBranch, MasterCatalogItem, MasterCompany, MasterCompanyAccessItem, MasterMembership, MasterOverview } from "@/lib/master/read-model";

export function PageHeading({ title, description, meta }: { title: string; description: string; meta?: string }) {
  return <div className="master-heading-row"><div><p className="master-eyebrow">ADMINISTRAÇÃO SAAS</p><h1>{title}</h1><p className="master-subtitle">{description}</p></div>{meta && <span className="master-status">{meta}</span>}</div>;
}

export function BackendUnavailable({ item = "esta consulta" }: { item?: string }) {
  return <section className="master-data-state" role="alert"><span className="master-state-symbol" aria-hidden="true">!</span><div><strong>Não foi possível carregar os dados</strong><p>{item} está temporariamente indisponível. Nenhum dado demonstrativo foi exibido. Atualize a página e tente novamente; se o problema persistir, verifique a sessão e a disponibilidade do serviço.</p></div></section>;
}

export function MetricCards({ data }: { data: MasterOverview }) {
  const metrics = [
    ["Empresas", data.companies_total, `${data.companies_active} ativas`],
    ["Filiais", data.branches_total, "Metadados cadastrados"],
    ["Vínculos ativos", data.memberships_active, "Sem acesso a dados operacionais"],
    ["Empresas suspensas", data.companies_suspended, `${data.companies_closed} encerradas`],
  ] as const;
  return <div className="master-metric-grid">{metrics.map(([label, value, hint]) => <article className="master-metric" key={label}><span>{label}</span><strong>{value.toLocaleString("pt-BR")}</strong><small>{hint}</small></article>)}</div>;
}

export function CompanyTable({ rows }: { rows: MasterCompany[] }) {
  if (!rows.length) return <EmptyRows title="Nenhuma empresa encontrada" description="Não há empresas que correspondam aos filtros informados." />;
  return <div className="master-table-wrap" role="region" aria-label="Tabela de empresas" tabIndex={0}><table className="master-table master-table--companies"><thead><tr><th>Empresa</th><th>Status</th><th>Filiais</th><th>Vínculos ativos</th><th>Criada em</th><th><span className="sr-only">Ações</span></th></tr></thead><tbody>{rows.map((row) => <tr key={row.company_id}><td><strong>{row.legal_name}</strong></td><td><StatusBadge value={row.status} /></td><td>{row.branch_count}</td><td>{row.active_membership_count}</td><td>{formatDate(row.created_at)}</td><td><Link className="master-row-link" href={`/master/empresas/${encodeURIComponent(row.company_id)}`}>Detalhes</Link></td></tr>)}</tbody></table></div>;
}

export function BranchTable({ rows }: { rows: MasterBranch[] }) {
  if (!rows.length) return <EmptyRows title="Nenhuma filial cadastrada" description="Esta empresa não possui metadados de filiais." />;
  return <div className="master-table-wrap" role="region" aria-label="Tabela de filiais" tabIndex={0}><table className="master-table master-table--branches"><thead><tr><th>Código</th><th>Filial</th><th>Status</th><th>Criada em</th></tr></thead><tbody>{rows.map((row) => <tr key={row.branch_id}><td><code>{row.code}</code></td><td><strong>{row.name}</strong></td><td><StatusBadge value={row.status} /></td><td>{formatDate(row.created_at)}</td></tr>)}</tbody></table></div>;
}

export function MembershipTable({ rows, query = "" }: { rows: MasterMembership[]; query?: string }) {
  if (!rows.length) return <EmptyRows title={query ? "Nenhum vínculo corresponde à busca" : "Nenhum vínculo empresarial"} description={query ? "Altere ou limpe o filtro para consultar os demais vínculos visíveis." : "Nenhuma membership foi encontrada para esta empresa."} />;
  return <div className="master-table-wrap" role="region" aria-label="Tabela de vínculos empresariais" tabIndex={0}><table className="master-table master-table--memberships"><thead><tr><th>Usuário</th><th>Vínculo</th><th>Escopo de filiais</th><th>Papéis e permissões</th><th>Desde</th></tr></thead><tbody>{rows.map((row, index) => <tr key={`${row.display_name ?? "anonymous"}:${row.created_at}:${index}`}><td><strong>{row.display_name?.trim() || "Identidade vinculada"}</strong><small className="master-table-subline">Conta Auth vinculada; e-mail não consultado</small></td><td><StatusBadge value={row.status} /></td><td>{row.branch_access_mode === "all_branches" ? "Todas as filiais" : "Somente filiais atribuídas"}</td><td><span className="master-muted">Não expostos pela API segura atual</span></td><td>{formatDate(row.created_at)}</td></tr>)}</tbody></table></div>;
}

export function CompanyActivationSummary({ company, access }: { company: MasterCompany; access: MasterCompanyAccessItem[] | null }) {
  const operational = access?.filter((item) => ["BP01", "MM01", "SV01", "MIGO", "ME21N", "ME23N"].includes(item.transaction_code)) ?? [];
  const enabled = operational.filter((item) => item.enabled).map((item) => item.transaction_code);
  const globallyReady = operational.filter((item) => item.approval_state === "approved" && item.permission_approval_state === "approved").map((item) => item.transaction_code);
  return <div className="master-activation-summary">
    <p><strong>Empresa:</strong> {company.status === "active" ? "ativa" : "indisponível"} · <strong>Filiais:</strong> {company.branch_count} · <strong>Vínculos ativos:</strong> {company.active_membership_count}</p>
    <p><strong>Transações globalmente prontas:</strong> {globallyReady.length ? globallyReady.join(", ") : "nenhuma"}.</p>
    <p><strong>Disponíveis para esta empresa:</strong> {enabled.length ? enabled.join(", ") : "nenhuma"}.</p>
    {!company.active_membership_count && <p className="master-muted">Próxima pendência: emitir um convite para o proprietário empresarial, com aceite autenticado. A emissão permanece desativada enquanto a flag de convites estiver desligada.</p>}
    {access === null && <p className="master-muted">A disponibilidade empresarial não pôde ser consultada; nenhuma alteração foi liberada.</p>}
  </div>;
}

export function CatalogTable({ rows, query = "" }: { rows: MasterCatalogItem[]; query?: string }) {
  if (!rows.length) return <EmptyRows title={query ? "Nenhum item corresponde à busca" : "Catálogo sem registros"} description={query ? "Altere ou limpe o filtro para consultar os demais itens visíveis." : "A base atual não contém definições de papéis ou permissões."} />;
  return <div className="master-table-wrap" role="region" aria-label="Tabela de permissões" tabIndex={0}><table className="master-table master-table--catalog"><thead><tr><th>Tipo</th><th>Código</th><th>Descrição</th><th>Escopo</th><th>Aprovação</th><th>Vínculos</th></tr></thead><tbody>{rows.map((row) => <tr key={`${row.item_type}:${row.item_key}`}><td>{row.item_type === "role" ? "Papel" : row.item_type === "role_permission" ? "Vínculo de permissão" : "Permissão"}</td><td><code>{row.item_key}</code></td><td>{friendlyCatalogName(row)}</td><td>{scopeLabel(row.scope)}</td><td><StatusBadge value={row.approval_state} /></td><td>{row.related_permission_count}</td></tr>)}</tbody></table></div>;
}

export function AuditTable({ rows }: { rows: MasterAuditItem[] }) {
  if (!rows.length) return <EmptyRows title="Nenhum evento encontrado" description="A trilha não contém eventos disponíveis para exibição." />;
  return <div className="master-table-wrap" role="region" aria-label="Tabela de auditoria" tabIndex={0}><table className="master-table master-table--audit"><thead><tr><th>Origem</th><th>Evento</th><th>Data</th></tr></thead><tbody>{rows.map((row, index) => <tr key={`${row.event_source}:${row.event_key}:${row.created_at}:${index}`}><td>{row.event_source === "master" ? "Admin Master" : "Provisionamento"}</td><td><code>{row.event_key}</code></td><td>{formatDate(row.created_at)}</td></tr>)}</tbody></table></div>;
}

export function PaginationControls({ page, hasNext, hrefForPage }: { page: number; hasNext: boolean; hrefForPage: (targetPage: number) => string }) {
  if (page === 1 && !hasNext) return null;
  return <nav className="master-pagination" aria-label="Paginação">
    {page > 1 ? <Link className="master-row-link" href={hrefForPage(page - 1)}>← Anterior</Link> : <span aria-hidden="true" />}
    <span>Página {page}</span>
    {hasNext ? <Link className="master-row-link" href={hrefForPage(page + 1)}>Próxima →</Link> : <span aria-hidden="true" />}
  </nav>;
}

export function DataPanel({ title, description, children }: { title: string; description?: string; children: ReactNode }) {
  return <section className="master-data-panel"><header><div><h2>{title}</h2>{description && <p>{description}</p>}</div></header>{children}</section>;
}

export function PreparedCapability({ title, description, reason }: { title: string; description: string; reason: string }) {
  return <><PageHeading title={title} description={description} meta="Indisponível nesta versão" /><section className="master-notice"><span className="master-notice-icon" aria-hidden="true">◇</span><div><strong>Contrato de backend ainda não existe</strong><p>{reason}</p></div></section><section className="master-empty-state"><span className="master-empty-icon" aria-hidden="true">⌕</span><h2>Sem dados ou ações simulados</h2><p>{description}</p></section></>;
}

export function EmptyRows({ title, description }: { title: string; description: string }) {
  return <div className="master-empty-state compact"><span className="master-empty-icon" aria-hidden="true">⌕</span><h2>{title}</h2><p>{description}</p></div>;
}

export function StatusBadge({ value }: { value: string }) {
  const positive = ["active", "approved"].includes(value);
  const negative = ["suspended", "closed", "revoked", "retired"].includes(value);
  return <span className={`master-badge${positive ? " is-positive" : negative ? " is-negative" : ""}`}>{statusLabel(value)}</span>;
}

function statusLabel(value: string) {
  const labels: Record<string, string> = { active: "Ativo", approved: "Aprovado", pending: "Pendente", pending_approval: "Pendente de aprovação", accepted: "Aceito", expired: "Expirado", inactive: "Inativo", suspended: "Suspenso", closed: "Encerrado", revoked: "Revogado", retired: "Desativado" };
  return labels[value] ?? value;
}

function scopeLabel(value: string | null) {
  return value === "company" ? "Empresa" : value === "branch" ? "Filial" : value ?? "—";
}

function friendlyCatalogName(row: MasterCatalogItem) {
  const labels: Record<string, string> = {
    company_owner: "Administrador principal da empresa",
    company_manager: "Gerente empresarial",
    branch_supervisor: "Supervisor de filial",
    branch_operator: "Operador de filial",
  };
  return labels[row.item_key] ?? row.display_name;
}

function formatDate(value: string) {
  const date = new Date(value);
  return Number.isNaN(date.valueOf()) ? "—" : new Intl.DateTimeFormat("pt-BR", { dateStyle: "medium" }).format(date);
}
