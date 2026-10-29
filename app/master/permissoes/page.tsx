import { getMasterAccessCatalog } from "@/lib/master/read-model";
import { BackendUnavailable, CatalogTable, DataPanel, PageHeading } from "@/app/master/master-data-ui";

export const dynamic = "force-dynamic";

export default async function MasterPermissionsPage({ searchParams }: { searchParams: Promise<{ q?: string; tipo?: string; situacao?: string }> }) {
  const { q, tipo, situacao } = await searchParams;
  const result = await getMasterAccessCatalog();
  const roles = result.status === "ready" ? result.data.filter((item) => item.item_type === "role") : [];
  const permissions = result.status === "ready" ? result.data.filter((item) => item.item_type === "permission") : [];
  const pending = result.status === "ready" ? result.data.filter((item) => item.approval_state === "pending_approval").length : 0;
  const normalizedQuery = q?.trim().toLocaleLowerCase("pt-BR") ?? "";
  const normalizedType = tipo === "role" || tipo === "permission" || tipo === "role_permission" ? tipo : "";
  const normalizedApproval = situacao === "pending_approval" || situacao === "approved" ? situacao : "";
  const filteredCatalog = result.status === "ready" ? result.data.filter((item) => {
    const matchesQuery = !normalizedQuery || `${item.item_key} ${item.display_name} ${item.scope ?? ""}`.toLocaleLowerCase("pt-BR").includes(normalizedQuery);
    return matchesQuery && (!normalizedType || item.item_type === normalizedType) && (!normalizedApproval || item.approval_state === normalizedApproval);
  }) : [];
  return <>
    <PageHeading title="Papéis e permissões" description="Consulta das definições existentes, retornadas pela API autorizada. Nenhuma alteração de papel ou concessão é permitida nesta versão." meta="Alterações bloqueadas" />
    <section className="master-notice"><span className="master-notice-icon" aria-hidden="true">◇</span><div><strong>Negação por padrão</strong><p>Definições com estado pendente não autorizam operações. A lista não promove permissões e a interface não oferece concessões.</p></div></section>
    {result.status === "ready" && <div className="master-metric-grid"><article className="master-metric"><span>Papéis empresariais</span><strong>{roles.length}</strong><small>Company owner, gerente, supervisor e operador quando presentes</small></article><article className="master-metric"><span>Permissões cadastradas</span><strong>{permissions.length}</strong><small>Somente consulta; nenhum grant é emitido</small></article><article className="master-metric"><span>Itens pendentes</span><strong>{pending}</strong><small>Não produzem autorização enquanto não houver aprovação explícita</small></article></div>}
    <DataPanel title="Catálogo persistido" description="Valores retornados pelo backend autorizado, não valores de demonstração.">{result.status === "ready" ? <>
      <form className="master-filter-form" method="get"><label>Buscar no catálogo<input name="q" type="search" maxLength={120} defaultValue={q ?? ""} placeholder="Código, nome ou escopo" /></label><label>Tipo<select name="tipo" defaultValue={normalizedType}><option value="">Todos</option><option value="role">Papéis</option><option value="permission">Permissões</option><option value="role_permission">Vínculos de permissão</option></select></label><label>Situação<select name="situacao" defaultValue={normalizedApproval}><option value="">Todas</option><option value="pending_approval">Pendente de aprovação</option><option value="approved">Aprovada</option></select></label><button type="submit">Filtrar</button></form>
      <CatalogTable rows={filteredCatalog} query={normalizedQuery || normalizedType || normalizedApproval} />
    </> : <BackendUnavailable item="O catálogo de papéis e permissões" />}</DataPanel>
    <section className="master-notice"><span className="master-notice-icon" aria-hidden="true">◇</span><div><strong>Permissões por usuário e por filial</strong><p>O catálogo confirma o que existe e seu estado de aprovação. A visualização de permissões efetivas por pessoa, concessão, revogação e escopo detalhado por filial exigem uma projeção de leitura e comandos empresariais específicos, que não são expostos por esta API Master.</p></div></section>
  </>;
}
