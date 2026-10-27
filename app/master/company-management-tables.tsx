import { randomUUID } from "node:crypto";
import Link from "next/link";
import type { MasterBranchV2, MasterCompanyV2 } from "@/lib/master/read-model";
import { BranchMetadataForm, BranchStatusForm, CompanyStatusForm } from "@/app/master/company-management-ui";

export function CompanyManagementTable({ rows, enabled }: { rows: MasterCompanyV2[]; enabled: boolean }) {
  if (!rows.length) return <div className="master-empty-state compact"><h2>Nenhuma empresa encontrada</h2><p>Não há empresas que correspondam aos filtros informados.</p></div>;
  return <div className="master-table-wrap" role="region" aria-label="Tabela de empresas" tabIndex={0}><table className="master-table master-table--companies"><thead><tr><th>Empresa</th><th>CNPJ</th><th>Situação</th><th>Filiais</th><th>Criada em</th><th>Ações</th></tr></thead><tbody>{rows.map((company) => <tr key={company.company_id}>
    <td><strong>{company.legal_name}</strong>{company.trade_name && <small>{company.trade_name}</small>}</td><td>{company.cnpj ?? "—"}</td><td>{company.status}</td><td>{company.branch_count}</td><td>{new Intl.DateTimeFormat("pt-BR", { dateStyle: "medium" }).format(new Date(company.created_at))}</td>
    <td className="master-row-actions"><Link className="master-row-link" href={`/master/empresas/${company.company_id}`}>Detalhes / editar</Link>{enabled && <CompanyStatusForm key={randomUUID()} company={company} requestId={randomUUID()} />}</td>
  </tr>)}</tbody></table></div>;
}

export function BranchManagementTable({ rows, companyId, enabled }: { rows: MasterBranchV2[]; companyId: string; enabled: boolean }) {
  if (!rows.length) return <div className="master-empty-state compact"><h2>Nenhuma filial cadastrada</h2><p>Esta empresa ainda não possui filiais.</p></div>;
  return <div className="master-table-wrap" role="region" aria-label="Tabela de filiais" tabIndex={0}><table className="master-table master-table--branches master-table--branch-management"><thead><tr><th>Código</th><th>Filial</th><th>CNPJ / endereço</th><th>Matriz</th><th>Situação</th><th>Gerenciar</th></tr></thead><tbody>{rows.map((branch) => <tr key={branch.branch_id}>
    <td><code>{branch.code}</code></td><td><strong>{branch.name}</strong><small>Criada em {new Intl.DateTimeFormat("pt-BR", { dateStyle: "medium" }).format(new Date(branch.created_at))}</small></td>
    <td>{branch.cnpj ?? "—"}<small>{branch.address ?? "Endereço não informado"}</small></td><td>{branch.is_headquarters ? "Matriz" : "Filial"}</td><td>{branch.status}</td>
    <td>{enabled ? <details className="master-row-editor"><summary>Editar</summary><BranchMetadataForm key={randomUUID()} requestId={randomUUID()} companyId={companyId} branch={branch} /><BranchStatusForm key={randomUUID()} companyId={companyId} branch={branch} requestId={randomUUID()} /></details> : <span className="master-muted">Bloqueado</span>}</td>
  </tr>)}</tbody></table></div>;
}
