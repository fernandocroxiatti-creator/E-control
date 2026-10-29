import { DataPanel, PageHeading } from "@/app/master/master-data-ui";
import { normalizeTransactionInput, transactionCatalog } from "@/lib/master/transaction-resolution";

export default async function MasterTransactionsPage({ searchParams }: { searchParams: Promise<{ q?: string }> }) {
  const { q } = await searchParams;
  const normalized = normalizeTransactionInput(q);
  const entry = normalized ? transactionCatalog[normalized as keyof typeof transactionCatalog] : null;
  return <>
    <PageHeading title="Transações" description="Pesquisa de código protegida; nenhuma rota é construída a partir de dados do usuário." meta="Execução bloqueada" />
    <section className="master-notice"><span className="master-notice-icon" aria-hidden="true">⇄</span><div><strong>Catálogo instalado, consulta Master pendente</strong><p>O catálogo persistido e a verificação por empresa e filial já existem no banco. Ainda não há uma RPC de leitura Master para listar seus registros; por isso esta página não anuncia transações como disponíveis e não consulta tabelas privadas diretamente.</p></div></section>
    <DataPanel title="Pesquisar código" description="A consulta valida apenas o formato e o registro técnico local já protegido; não concede acesso e não abre rotas."><form className="master-filter-form" method="get"><label>Código<input name="q" type="search" maxLength={20} autoCapitalize="characters" autoComplete="off" spellCheck={false} defaultValue={q ?? ""} placeholder="Ex.: ME21N" /></label><button type="submit">Pesquisar</button></form>{q && <div className="master-transaction-result" role="status">{!normalized ? <><strong>Código inválido</strong><p>Use de 2 a 20 caracteres alfanuméricos, começando por uma letra.</p></> : entry ? <><strong>{normalized} · {entry.label}</strong><p>Módulo {entry.module} · permissão necessária <code>{entry.permissionKey}</code> · estado: pendente de aprovação e sem rota executável.</p></> : <><strong>Transação não encontrada</strong><p>O código não consta na referência técnica local.</p></>}</div>}</DataPanel>
    <div className="master-metric-grid"><article className="master-metric"><span>Catálogo persistido</span><strong className="master-metric-text">Protegido</strong><small>Sem leitura direta para o navegador</small></article><article className="master-metric"><span>Rotas executáveis</span><strong>0</strong><small>Nenhum destino arbitrário é aceito</small></article><article className="master-metric"><span>Autorizações</span><strong className="master-metric-text">Pendente</strong><small>Não há grants operacionais ativos</small></article></div>
  </>;
}
