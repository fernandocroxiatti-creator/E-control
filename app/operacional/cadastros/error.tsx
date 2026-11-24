"use client";

export default function OperationalCatalogError({ reset }: { error: Error & { digest?: string }; reset: () => void }) {
  return <main className="master-page"><section className="master-data-panel"><h1>Não foi possível carregar os cadastros</h1><p>Se o envio falhou, os dados não foram confirmados como gravados. Revise o formulário e tente novamente; se o problema persistir, informe o código de diagnóstico exibido pela operação.</p><button className="master-action" onClick={reset}>Tentar novamente</button></section></main>;
}
