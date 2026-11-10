import Link from "next/link";
import { redirect } from "next/navigation";
import { resolveTransactionForSession } from "@/lib/master/transaction-resolution";
import { getSupabaseEnv } from "@/lib/supabase/env";
import { createClient } from "@/lib/supabase/server";

export const dynamic = "force-dynamic";

type Search = { codigo?: string; empresa?: string; filial?: string };

const messageFor = (status: string) => ({
  unauthenticated: "Entre na sua conta antes de consultar uma transação.",
  context_required: "Selecione uma empresa e uma filial autorizadas antes de consultar a transação.",
  invalid: "Código de transação inválido.",
  unknown: "Transação não encontrada.",
  denied: "Acesso negado para esta transação, empresa ou filial.",
  unavailable: "Não foi possível validar a autorização agora. Nenhuma rota operacional foi aberta; atualize a página e tente novamente.",
} as Record<string, string>)[status] ?? "A transação não pôde ser validada.";

/** Server-only SAP-code gateway. Every navigation repeats the database policy. */
export default async function OperationalTransactionGateway({ searchParams }: { searchParams: Promise<Search> }) {
  const search = await searchParams;
  const client = await createClient();
  if (!client) return <p className="master-notice">Integração indisponível. Nenhuma rota operacional foi aberta.</p>;

  const result = await resolveTransactionForSession(client, search.codigo, search.empresa, search.filial);
  if (result.status === "authorized" && getSupabaseEnv()?.operationalEnabled) {
    const context = new URLSearchParams({ empresa: search.empresa!, filial: search.filial! });
    redirect(`${result.route}${result.route.includes("?") ? "&" : "?"}${context.toString()}`);
  }

  const message = result.status === "authorized"
    ? "A transação foi autorizada, mas o ambiente operacional ainda não foi habilitado."
    : messageFor(result.status);
  return <main className="master-page"><div className="page-heading-row"><div><p className="page-kicker">E-CONTROL / TRANSAÇÕES</p><h1>Transação não aberta</h1><p className="page-subtitle">A autorização é validada no servidor para a empresa e a filial selecionadas.</p></div></div><p className="master-notice" role="alert">{message}</p><Link className="master-action" href="/dashboard">Voltar ao painel</Link></main>;
}
