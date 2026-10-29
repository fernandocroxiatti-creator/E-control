import Link from "next/link";
import { CompanyAdminInvitationForm, CompanyAdminInvitationTable } from "@/app/master/company-admin-invitations";
import { getCompanyAdminInvitations, getMasterCompanies, getMasterCompanyInvitationsEnabled, getMasterMemberships } from "@/lib/master/read-model";
import { BackendUnavailable, DataPanel, MembershipTable, PageHeading } from "@/app/master/master-data-ui";

export const dynamic = "force-dynamic";

export default async function MasterUsersPage({ searchParams }: { searchParams: Promise<{ empresa?: string; busca?: string }> }) {
  const { empresa, busca } = await searchParams;
  const [companies, memberships] = await Promise.all([
    getMasterCompanies(null, null), empresa ? getMasterMemberships(empresa) : Promise.resolve(null),
  ]);
  const invitationsEnabled = await getMasterCompanyInvitationsEnabled();
  const invitations = empresa ? await getCompanyAdminInvitations(empresa) : null;
  const selectedCompany = companies.status === "ready" ? companies.data.find((item) => item.company_id === empresa) : undefined;
  const normalizedSearch = busca?.trim().toLocaleLowerCase("pt-BR") ?? "";
  const filteredMemberships = memberships?.status === "ready" && normalizedSearch
    ? memberships.data.filter((membership) => `${membership.display_name ?? ""} ${membership.status} ${membership.branch_access_mode}`.toLocaleLowerCase("pt-BR").includes(normalizedSearch))
    : memberships?.status === "ready" ? memberships.data : null;
  return <>
    <PageHeading title="Usuários e vínculos" description="Convites individuais e consulta de vínculos; credenciais e tokens não são persistidos em claro." meta="Convites empresariais" />
    <DataPanel title="Empresa" description="Escolha a empresa para consultar os vínculos existentes.">
      {companies.status === "ready" ? companies.data.length ? <div className="master-company-picker">{companies.data.map((company) => <Link className={`master-company-choice${empresa === company.company_id ? " is-selected" : ""}`} key={company.company_id} href={`/master/administradores?empresa=${encodeURIComponent(company.company_id)}`}><span><strong>{company.legal_name}</strong><small>{company.active_membership_count} vínculos ativos</small></span><span aria-hidden="true">→</span></Link>)}</div> : <div className="master-panel-empty">Nenhuma empresa cadastrada.</div> : <BackendUnavailable item="A lista de empresas" />}
    </DataPanel>
    <DataPanel title="Convidar primeiro administrador" description="O destinatário precisa ter uma conta autenticada com e-mail confirmado correspondente ao convite.">
      <CompanyAdminInvitationForm companies={companies.status === "ready" ? companies.data : []} enabled={invitationsEnabled} />
    </DataPanel>
    {empresa && selectedCompany && <>
      <DataPanel title={`Convites · ${selectedCompany.legal_name}`} description="Os tokens nunca são exibidos nesta lista. Convites expirados são rejeitados e registrados quando processados.">
        {invitations?.status === "ready" ? <CompanyAdminInvitationTable rows={invitations.data} tenantId={empresa} enabled={invitationsEnabled} /> : <BackendUnavailable item="Os convites desta empresa" />}
      </DataPanel>
      <DataPanel title={`Vínculos · ${selectedCompany.legal_name}`} description="Identidades vinculadas com status e escopo; dados de Auth não são consultados.">
        <form className="master-filter-form" method="get"><input type="hidden" name="empresa" value={empresa} /><label>Buscar nos vínculos visíveis<input name="busca" type="search" maxLength={80} defaultValue={busca ?? ""} placeholder="Nome, situação ou escopo" /></label><button type="submit">Filtrar</button></form>
        {memberships?.status === "ready" ? <MembershipTable rows={filteredMemberships ?? []} query={normalizedSearch} /> : <BackendUnavailable item="Os vínculos desta empresa" />}
      </DataPanel>
    </>}
    <section className="master-notice"><span className="master-notice-icon" aria-hidden="true">◇</span><div><strong>Papel empresarial sujeito a aprovação</strong><p>O convite usa exclusivamente o papel company_owner. A emissão e a aceitação permanecem bloqueadas até esse papel estar aprovado no catálogo. O convite nunca concede Admin Master, não cria a conta Auth e não atribui permissões além das aprovadas para esse papel.</p></div></section>
    <section className="master-notice"><span className="master-notice-icon" aria-hidden="true">◇</span><div><strong>Operações de vínculo protegidas</strong><p>A revogação de vínculo, a lista de papéis por pessoa, as permissões efetivas e o detalhamento de filiais dependem de uma API de leitura/escrita empresarial que ainda não faz parte do contrato publicado. Nenhum botão de alteração é exibido até existir esse contrato seguro.</p></div></section>
  </>;
}
