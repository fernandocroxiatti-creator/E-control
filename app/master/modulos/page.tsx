import { PageHeading } from "@/app/master/master-data-ui";

const productModules = [
  ["ADMIN", "Administração", "Cadastros e controles administrativos"],
  ["PUR", "Compras", "Fornecedores e pedidos de compra"],
  ["INV", "Estoque", "Materiais, saldos e movimentações"],
  ["SAL", "Vendas", "Cotações, pedidos e faturamento"],
  ["FIN", "Financeiro", "Contas, pagamentos e recebimentos"],
  ["ACC", "Contabilidade", "Lançamentos e fechamento contábil"],
  ["TAX", "Fiscal", "Documentos e apuração fiscal"],
  ["SRV", "Serviços", "Ordens de serviço e atendimento"],
  ["RPT", "Relatórios", "Consultas gerenciais"],
  ["BUD", "Orçamentos", "Planejamento e acompanhamento"],
  ["HCM", "Recursos Humanos", "Estrutura e administração de pessoas"],
  ["CFG", "Configurações", "Preferências e parâmetros do ERP"],
] as const;

export default function MasterModulesPage() {
  return <>
    <PageHeading title="Módulos" description="Catálogo de produto organizado para evolução do ERP." meta="Catálogo local · não persistido" />
    <section className="master-notice"><span className="master-notice-icon" aria-hidden="true">◇</span><div><strong>Catálogo não representa licença nem autorização</strong><p>O banco atual não contém um catálogo persistente de módulos por empresa. Todos os itens abaixo estão apenas documentados no pacote e não liberam funcionalidades.</p></div></section>
    <div className="master-module-grid">{productModules.map(([code, name, description]) => <article className="master-module-card" key={code}><span className="master-module-code">{code}</span><div><h2>{name}</h2><p>{description}</p></div><span className="master-badge">Não configurado</span></article>)}</div>
  </>;
}
