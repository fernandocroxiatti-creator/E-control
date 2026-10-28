import { randomUUID } from "node:crypto";
import { BackendUnavailable, DataPanel, PageHeading, PaginationControls } from "@/app/master/master-data-ui";
import { CompanyMetadataForm } from "@/app/master/company-management-ui";
import { CompanyManagementTable } from "@/app/master/company-management-tables";
import { getMasterCompaniesV2, getMasterCompanyCreationEnabled, getMasterCompanyManagementEnabled } from "@/lib/master/read-model";
import { MASTER_PAGE_SIZE, parseMasterPage } from "@/lib/master/listing";

export const dynamic = "force-dynamic";

export default async function MasterCompaniesPage({ searchParams }: { searchParams: Promise<{ q?: string; status?: string; page?: string }> }) {
  const params = await searchParams;
  const search = typeof params.q === "string" ? params.q.trim().slice(0, 100) : "";
  const status = ["active", "suspended", "closed"].includes(params.status ?? "") ? params.status! : null;
  const page = parseMasterPage(params.page);
  const [result, managementEnabled, creationEnabled] = await Promise.all([
    getMasterCompaniesV2(search || null, status, MASTER_PAGE_SIZE + 1, (page - 1) * MASTER_PAGE_SIZE),
    getMasterCompanyManagementEnabled(), getMasterCompanyCreationEnabled(),
  ]);
  const rows = result.status === "ready" ? result.data.slice(0, MASTER_PAGE_SIZE) : [];
  const hasNext = result.status === "ready" && result.data.length > MASTER_PAGE_SIZE;
  const hrefForPage = (targetPage: number) => {
    const next = new URLSearchParams();
    if (search) next.set("q", search);
    if (status) next.set("status", status);
    if (targetPage > 1) next.set("page", String(targetPage));
    const query = next.toString();
    return `/master/empresas${query ? `?${query}` : ""}`;
  };
  return <>
    <PageHeading title="Empresas clientes" description="Cadastro e gestão de metadados SaaS. O acesso operacional das empresas permanece separado e não é concedido pelo Admin Master." meta="Admin Master" />
    <DataPanel title="Nova empresa" description="A razão social é obrigatória; CNPJ e contato são opcionais. Quando informado, o CNPJ deve ser válido e único. A data de criação vem do banco.">
      {creationEnabled ? <CompanyMetadataForm key={randomUUID()} requestId={randomUUID()} /> : <div className="master-notice"><span className="master-notice-icon" aria-hidden="true">◇</span><div><strong>Cadastro desativado neste ambiente</strong><p>O cadastro exige a flag local específica de homologação, sessão Master válida e RPC de prontidão aprovada. Nenhum formulário envia dados enquanto qualquer condição estiver desligada.</p></div></div>}
    </DataPanel>
    <DataPanel title="Empresas" description="Pesquisa, filtros e paginação executados no servidor. Ações de escrita são revalidadas pela sessão e pela RPC no banco.">
      <form className="master-filter-form" method="get"><label>Nome ou nome fantasia<input name="q" type="search" maxLength={100} defaultValue={search} placeholder="Pesquisar empresa" /></label><label>Situação<select name="status" defaultValue={status ?? ""}><option value="">Todas</option><option value="active">Ativa</option><option value="suspended">Suspensa</option><option value="closed">Encerrada</option></select></label><button type="submit">Filtrar</button></form>
      {result.status === "ready" ? <><CompanyManagementTable rows={rows} enabled={managementEnabled} /><PaginationControls page={page} hasNext={hasNext} hrefForPage={hrefForPage} /></> : <BackendUnavailable item="A listagem V2 de empresas" />}
    </DataPanel>
  </>;
}
