export default function MasterLoading() {
  return (
    <section className="master-loading" aria-label="Carregando Admin Master" aria-busy="true">
      <p role="status">Carregando dados administrativos…</p>
      <div className="master-loading-grid" aria-hidden="true">
        {Array.from({ length: 4 }, (_, index) => <div className="master-loading-card" key={index} />)}
      </div>
    </section>
  );
}
