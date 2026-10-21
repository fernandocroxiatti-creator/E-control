export default function DashboardLoading() {
  return (
    <main className="dashboard-loading" aria-label="Carregando painel">
      <div className="loading-sidebar" />
      <section className="loading-content" aria-hidden="true">
        <div className="loading-topbar" />
        <div className="loading-title" />
        <div className="loading-banner" />
        <div className="loading-grid">{Array.from({ length: 7 }, (_, index) => <div className="loading-tile" key={index} />)}</div>
      </section>
      <p className="visually-hidden" role="status">Carregando o painel do eControl.</p>
    </main>
  );
}
