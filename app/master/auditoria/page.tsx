import { getMasterAudit } from "@/lib/master/read-model";
import { AuditTable, BackendUnavailable, DataPanel, PageHeading } from "@/app/master/master-data-ui";

export const dynamic = "force-dynamic";

export default async function MasterAuditPage() {
  const result = await getMasterAudit(50);
  return <>
    <PageHeading title="Auditoria administrativa" description="Índice de eventos sem detalhes privados, conteúdo de Auth ou payloads de auditoria." meta="Somente leitura" />
    <section className="master-notice"><span className="master-notice-icon" aria-hidden="true">≋</span><div><strong>Trilha imutável</strong><p>Esta interface não oferece edição ou exclusão. A RPC retorna apenas origem, tipo e data do evento.</p></div></section>
    <DataPanel title="Eventos recentes">{result.status === "ready" ? <AuditTable rows={result.data} /> : <BackendUnavailable item="A trilha de auditoria" />}</DataPanel>
  </>;
}
