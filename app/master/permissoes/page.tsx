import { AccessGovernance } from "@/app/master/access-governance";
import { getMasterAccessControlMatrix, getMasterAccessGovernanceEnabled, getMasterAudit } from "@/lib/master/read-model";
import { BackendUnavailable, DataPanel, PageHeading } from "@/app/master/master-data-ui";

export const dynamic = "force-dynamic";

export default async function MasterPermissionsPage() {
  const [matrix, audit, governanceEnabled] = await Promise.all([
    getMasterAccessControlMatrix(), getMasterAudit(50), getMasterAccessGovernanceEnabled(),
  ]);
  return <>
    <PageHeading title="Papéis e permissões" description="Administre aprovações e concessões com confirmações explícitas, auditoria e validação no servidor." meta={governanceEnabled ? "Governança habilitada" : "Modo de consulta"} />
    <section className="master-notice"><span className="master-notice-icon" aria-hidden="true">◇</span><div><strong>Controle em duas etapas</strong><p>Primeiro aprove o catálogo. Depois conceda uma permissão aprovada a um papel aprovado. Nenhuma ação cria usuários, vínculos empresariais ou acesso operacional automático.</p></div></section>
    <DataPanel title="Governança de acesso" description="O catálogo e o histórico vêm das RPCs autorizadas. Cada alteração exige confirmação explícita e é auditada.">
      {matrix.status === "ready" ? <>
        {audit.status !== "ready" && <section className="master-data-state" role="alert"><span className="master-state-symbol" aria-hidden="true">!</span><div><strong>Não foi possível carregar o histórico administrativo</strong><p>As aprovações e concessões não foram ocultadas nem simuladas. Atualize a página antes de realizar uma nova alteração.</p></div></section>}
        <AccessGovernance entries={matrix.data} auditEvents={audit.status === "ready" ? audit.data : []} enabled={governanceEnabled} />
      </> : <BackendUnavailable item="A matriz de aprovação e concessões" />}
    </DataPanel>
    <section className="master-notice compact-notice"><span className="master-notice-icon" aria-hidden="true">◇</span><div><strong>Escopo empresarial preservado</strong><p>Concessões definem capacidades de um papel; a autorização efetiva continua dependendo de vínculo ativo, empresa, filial e validação da transação no banco. Admin Master não recebe acesso operacional automaticamente.</p></div></section>
  </>;
}
