import { PageHeading } from "@/app/master/master-data-ui";
import { normalizeTransactionInput, transactionCatalog } from "@/lib/master/transaction-resolution";

export default async function MasterTransactionsPage({ searchParams }: { searchParams: Promise<{ q?: string }> }) {
  const { q } = await searchParams;
  const normalized = normalizeTransactionInput(q);
  const entry = normalized ? transactionCatalog[normalized as keyof typeof transactionCatalog] : null;
  return <>
    <PageHeading title="Transações" description="Busca controlada por código; nenhuma rota é construída a partir de dados do usuário." meta="Catálogo local · sem rotas executáveis" />
    <section className="master-notice"><span className="master-notice-icon" aria-hidden="true">⇄</span><div><strong>Execução bloqueada por padrão</strong><p>O banco ainda não possui catálogo persistido de transações, entitlements por empresa/filial e rotas autorizadas. A busca operacional valida a sessão e falha fechada até esses contratos existirem.</p></div></section>
    <section className="master-data-panel"><header><div><h2>Pesquisar código</h2><p>Digite um código para consultar o registro técnico preparado.</p></div></header><form className="master-filter-form" method="get"><label>Código<input name="q" type="search" maxLength={20} autoCapitalize="characters" autoComplete="off" spellCheck={false} defaultValue={q ?? ""} placeholder="Ex.: ME21N" /></label><button type="submit">Pesquisar</button></form>{q && <div className="master-transaction-result" role="status">{!normalized ? <><strong>Código inválido</strong><p>Use de 2 a 20 caracteres alfanuméricos, começando por uma letra.</p></> : entry ? <><strong>{normalized} · {entry.label}</strong><p>Módulo {entry.module} · permissão necessária <code>{entry.permissionKey}</code> · estado: preparado, desabilitado. Não existe rota executável nem autorização persistente correspondente.</p></> : <><strong>Transação não encontrada</strong><p>O código não consta no catálogo técnico local.</p></>}</div>}</section>
    <div className="master-metric-grid"><article className="master-metric"><span>Catálogo persistido</span><strong className="master-metric-text">Indisponível</strong><small>Não há migration de catálogo instalada</small></article><article className="master-metric"><span>Rotas executáveis</span><strong>0</strong><small>Nenhum destino arbitrário é aceito</small></article><article className="master-metric"><span>Permissões verificadas</span><strong className="master-metric-text">Pendente</strong><small>Sem entitlement por transação</small></article></div>
  </>;
}
