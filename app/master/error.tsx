"use client";

export default function MasterError({ reset }: { error: Error & { digest?: string }; reset: () => void }) {
  return (
    <main className="master-error" role="alert">
      <h1>Não foi possível carregar o painel</h1>
      <p>Ocorreu uma falha ao consultar os dados administrativos. Tente novamente.</p>
      <button type="button" onClick={() => reset()}>Tentar novamente</button>
    </main>
  );
}
