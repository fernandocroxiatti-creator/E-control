import { normalizeTransactionInput, transactionCatalog } from "@/lib/master/transaction-resolution";
import { DataPanel } from "@/app/master/master-data-ui";

export const dynamic = "force-dynamic";

export default async function MasterTransactionsPage({ searchParams }: { searchParams: Promise<{ q?: string }> }) {
  const { q } = await searchParams;
  const normalized = normalizeTransactionInput(q);
  const entry = normalized ? transactionCatalog[normalized as keyof typeof transactionCatalog] : null;
  return <DataPanel title="Pesquisar código" description="Esta referência técnica lista somente códigos implementados. O estado real de aprovação e a disponibilidade por empresa são administrados em Papéis e permissões.">
    <form className="master-filter-form" method="get"><label>Código<input name="q" type="search" maxLength={20} autoCapitalize="characters" autoComplete="off" spellCheck={false} defaultValue={q ?? ""} placeholder="Ex.: ME21N" /></label><button type="submit">Pesquisar</button></form>
    {q && <div className="master-transaction-result" role="status">{!normalized ? <><strong>Código inválido</strong><p>Use de 2 a 20 caracteres alfanuméricos, começando por uma letra.</p></> : entry ? <><strong>{normalized} · {entry.name}</strong><p>Módulo {entry.moduleName} · permissão associada <code>{entry.permissionKey}</code> · rota operacional {entry.route}.</p><p>Use Papéis e permissões para consultar ou alterar a aprovação global. Esta busca não autoriza nem abre transações.</p></> : <><strong>Transação não encontrada</strong><p>O código não consta no catálogo funcional atual.</p></>}</div>}
  </DataPanel>;
}
