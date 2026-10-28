import { randomUUID } from "node:crypto";
import Link from "next/link";
import { BranchMetadataForm } from "@/app/master/company-management-ui";
import { BranchManagementTable } from "@/app/master/company-management-tables";
import { BackendUnavailable, DataPanel, PageHeading, PaginationControls } from "@/app/master/master-data-ui";
import { getMasterBranchesV2, getMasterCompaniesV2, getMasterCompanyManagementEnabled } from "@/lib/master/read-model";
import { filterBranches, paginateRows, parseMasterPage } from "@/lib/master/listing";

export const dynamic = "force-dynamic";

export default async function MasterBranchesPage({ searchParams }: { searchParams: Promise<{ empresa?: string; q?: string; status?: string; page?: string }> }) {
  const { empresa, q, status: rawStatus, page: rawPage } = await searchParams;
  const search = typeof q === "string" ? q.trim().slice(0, 100) : "";
  const status = ["active", "inactive"].includes(rawStatus ?? "") ? rawStatus! : null;
  const page = parseMasterPage(rawPage);
  const [companies, managementEnabled, branches] = await Promise.all([
    getMasterCompaniesV2(null, null), getMasterCompanyManagementEnabled(),
    empresa ? getMasterBranchesV2(empresa) : Promise.resolve(null),
  ]);
  const selectedCompany = companies.status === "ready" ? companies.data.find((item) => item.company_id === empresa) : undefined;
  const filtered = branches?.status === "ready" ? filterBranches(branches.data, search || null, status) : [];
  const paged = paginateRows(filtered, page);
  const hrefForPage = (targetPage: number) => {
    const next = new URLSearchParams({ empresa: selectedCompany?.company_id ?? "" });
    if (search) next.set("q", search);
    if (status) next.set("status", status);
    if (targetPage > 1) next.set("page", String(targetPage));
    return `/master/filiais?${next.toString()}`;
  };
  return <>
    <PageHeading title="Filiais" description="Metadados de filiais sob uma empresa existente. Nenhum dado operacional é consultado ou concedido pelo Master." meta="Escopo por empresa" />
    <DataPanel title="Empresas" description="Selecione uma empresa para consultar ou administrar suas filiais.">
      {companies.status === "ready" ? companies.data.length ? <div className="master-company-picker">{companies.data.map((company) => <Link className={`master-company-choice${empresa === company.company_id ? " is-selected" : ""}`} key={company.company_id} href={`/master/filiais?empresa=${encodeURIComponent(company.company_id)}`}><span><strong>{company.legal_name}</strong><small>{company.branch_count} filiais · {company.status}</small></span><span aria-hidden="true">→</span></Link>)}</div> : <div className="master-panel-empty">Nenhuma empresa cadastrada.</div> : <BackendUnavailable item="A seleção de empresa" />}
    </DataPanel>
    {selectedCompany && <>
      <DataPanel title={`Cadastrar filial · ${selectedCompany.legal_name}`} description="A filial sempre pertence à empresa selecionada; o banco revalida a referência e a autorização Master.">
        {managementEnabled ? <BranchMetadataForm key={randomUUID()} requestId={randomUUID()} companyId={selectedCompany.company_id} /> : <div className="master-notice"><span className="master-notice-icon" aria-hidden="true">◇</span><div><strong>Cadastro desativado neste ambiente</strong><p>Esta ação exige a flag local de gestão, sessão Master válida e RPC de prontidão aprovada. Nenhuma alteração é enviada enquanto qualquer condição estiver desligada.</p></div></div>}
      </DataPanel>
      <DataPanel title={`Filiais · ${selectedCompany.legal_name}`} description="Códigos são normalizados em maiúsculas e únicos dentro da empresa; a indicação de matriz é exclusiva por empresa.">
        <form className="master-filter-form" method="get"><input type="hidden" name="empresa" value={selectedCompany.company_id} /><label>Pesquisar filial<input name="q" type="search" maxLength={100} defaultValue={search} placeholder="Código, nome, CNPJ ou endereço" /></label><label>Situação<select name="status" defaultValue={status ?? ""}><option value="">Todas</option><option value="active">Ativa</option><option value="inactive">Inativa</option></select></label><button type="submit">Filtrar</button></form>
        {branches?.status === "ready" ? <><BranchManagementTable rows={paged.rows} companyId={selectedCompany.company_id} enabled={managementEnabled} /><PaginationControls page={page} hasNext={paged.hasNext} hrefForPage={hrefForPage} /></> : <BackendUnavailable item="A listagem V2 das filiais" />}
      </DataPanel>
    </>}
  </>;
}
