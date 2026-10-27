import { randomUUID } from "node:crypto";
import Link from "next/link";
import { notFound } from "next/navigation";
import { BranchManagementTable } from "@/app/master/company-management-tables";
import { BranchMetadataForm, CompanyMetadataForm, CompanyStatusForm } from "@/app/master/company-management-ui";
import { BackendUnavailable, DataPanel, MembershipTable, PageHeading } from "@/app/master/master-data-ui";
import { getMasterBranchesV2, getMasterCompanyManagementEnabled, getMasterCompanyV2, getMasterMemberships } from "@/lib/master/read-model";

const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[1-8][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i;
export const dynamic = "force-dynamic";

export default async function MasterCompanyDetailPage({ params }: { params: Promise<{ companyId: string }> }) {
  const { companyId } = await params;
  if (!UUID.test(companyId)) notFound();
  const [companyResult, branchesResult, membershipsResult, managementEnabled] = await Promise.all([
    getMasterCompanyV2(companyId), getMasterBranchesV2(companyId), getMasterMemberships(companyId), getMasterCompanyManagementEnabled(),
  ]);
  if (companyResult.status === "ready" && !companyResult.data) notFound();
  const company = companyResult.status === "ready" ? companyResult.data : null;
  return <>
    <Link href="/master/empresas" className="master-breadcrumb">← Empresas</Link>
    <PageHeading title={company?.legal_name ?? "Detalhes da empresa"} description="Metadados cadastrais, situação, filiais e vínculos; nenhum dado operacional é carregado." meta={company?.status ?? "Backend pendente"} />
    {company ? <>
      <section className="master-metric-grid"><article className="master-metric"><span>Situação</span><strong className="master-metric-text">{company.status}</strong><small>Criada em {new Intl.DateTimeFormat("pt-BR", { dateStyle: "medium" }).format(new Date(company.created_at))}</small></article><article className="master-metric"><span>Filiais</span><strong>{company.branch_count}</strong><small>Metadados vinculados</small></article><article className="master-metric"><span>Vínculos ativos</span><strong>{company.active_membership_count}</strong><small>Sem acesso Master a dados operacionais</small></article></section>
      {managementEnabled && <section className="master-data-panel"><header><div><h2>Situação da empresa</h2><p>Ativar ou suspender não cria nem revoga memberships automaticamente.</p></div></header><CompanyStatusForm key={randomUUID()} company={company} requestId={randomUUID()} /></section>}
      <DataPanel title="Dados cadastrais" description="A data de criação é controlada pelo banco. Alterações são registradas na auditoria administrativa.">
        {managementEnabled ? <CompanyMetadataForm key={randomUUID()} requestId={randomUUID()} company={company} /> : <div className="master-notice"><span className="master-notice-icon" aria-hidden="true">◇</span><div><strong>Edição desativada neste ambiente</strong><p>Esta ação exige a flag local de gestão, sessão Master válida e RPC de prontidão aprovada. Nenhuma alteração é enviada enquanto qualquer condição estiver desligada.</p></div></div>}
      </DataPanel>
      <DataPanel title="Filiais" description="Cada filial permanece associada a esta empresa; não é possível alterar o vínculo no formulário de edição.">
        {branchesResult.status === "ready" ? <BranchManagementTable rows={branchesResult.data} companyId={companyId} enabled={managementEnabled} /> : <BackendUnavailable item="As filiais da empresa" />}
        {managementEnabled && <details className="master-row-editor"><summary>Cadastrar filial nesta empresa</summary><BranchMetadataForm key={randomUUID()} requestId={randomUUID()} companyId={companyId} /></details>}
      </DataPanel>
      <DataPanel title="Usuários vinculados" description="Consulta apenas memberships já existentes; não mostra e-mail nem concede acesso.">{membershipsResult.status === "ready" ? <MembershipTable rows={membershipsResult.data} /> : <BackendUnavailable item="Os vínculos empresariais" />}</DataPanel>
    </> : <BackendUnavailable item="Os detalhes cadastrais da empresa" />}
  </>;
}
