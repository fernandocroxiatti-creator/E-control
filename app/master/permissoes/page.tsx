import { getMasterAccessCatalog } from "@/lib/master/read-model";
import { BackendUnavailable, CatalogTable, DataPanel, PageHeading } from "@/app/master/master-data-ui";

export const dynamic = "force-dynamic";

export default async function MasterPermissionsPage() {
  const result = await getMasterAccessCatalog();
  return <>
    <PageHeading title="Papéis e permissões" description="Consulta das definições existentes. Nenhuma alteração de papel ou concessão é permitida nesta versão." meta="Alterações bloqueadas" />
    <section className="master-notice"><span className="master-notice-icon" aria-hidden="true">◇</span><div><strong>Negação por padrão</strong><p>Definições com estado pendente não autorizam operações. A lista não promove permissões e a interface não oferece concessões.</p></div></section>
    <DataPanel title="Catálogo persistido" description="Valores retornados pelo backend autorizado, não valores de demonstração.">{result.status === "ready" ? <CatalogTable rows={result.data} /> : <BackendUnavailable item="O catálogo de papéis e permissões" />}</DataPanel>
  </>;
}
