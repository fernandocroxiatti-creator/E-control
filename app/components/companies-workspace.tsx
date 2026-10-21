"use client";

import { useState } from "react";

type WorkspaceView = "companies" | "new-company" | "branches" | "new-branch";

const emptyCompanies: never[] = [];
const emptyBranches: never[] = [];

function digits(value: string) {
  return value.replace(/\D/g, "");
}

function formatCnpj(value: string) {
  return digits(value).slice(0, 14).replace(/^(\d{2})(\d)/, "$1.$2").replace(/^(\d{2})\.(\d{3})(\d)/, "$1.$2.$3").replace(/\.(\d{3})(\d)/, ".$1/$2").replace(/(\d{4})(\d)/, "$1-$2");
}

function isValidCnpj(value: string) {
  const valueDigits = digits(value);
  if (valueDigits.length !== 14 || /^(\d)\1{13}$/.test(valueDigits)) return false;
  const calculate = (base: string, weights: number[]) => {
    const sum = [...base].reduce((total, digit, index) => total + Number(digit) * weights[index], 0);
    const remainder = sum % 11;
    return remainder < 2 ? 0 : 11 - remainder;
  };
  const first = calculate(valueDigits.slice(0, 12), [5, 4, 3, 2, 9, 8, 7, 6, 5, 4, 3, 2]);
  const second = calculate(valueDigits.slice(0, 12) + first, [6, 5, 4, 3, 2, 9, 8, 7, 6, 5, 4, 3, 2]);
  return valueDigits.endsWith(`${first}${second}`);
}

function formatPhone(value: string) {
  const phone = digits(value).slice(0, 11);
  if (phone.length <= 2) return phone ? `(${phone}` : "";
  const area = phone.slice(0, 2);
  const rest = phone.slice(2);
  if (phone.length <= 10) return `(${area}) ${rest.slice(0, 4)}${rest.length > 4 ? `-${rest.slice(4)}` : ""}`;
  return `(${area}) ${rest.slice(0, 5)}${rest.length > 5 ? `-${rest.slice(5)}` : ""}`;
}

function formatCep(value: string) {
  return digits(value).slice(0, 8).replace(/^(\d{5})(\d)/, "$1-$2");
}

export function CompaniesWorkspace({ view }: { view: WorkspaceView }) {
  const [query, setQuery] = useState("");
  const [message, setMessage] = useState("");
  const [formError, setFormError] = useState("");
  const [cnpj, setCnpj] = useState("");
  const [phone, setPhone] = useState("");
  const [cep, setCep] = useState("");

  const isCompanyForm = view === "new-company";
  const isBranchForm = view === "new-branch";
  const heading = view === "companies" ? "Empresas" : view === "branches" ? "Filiais" : isCompanyForm ? "Nova empresa" : "Nova filial";
  const kicker = view === "branches" || isBranchForm ? "EMPRESAS / FILIAIS" : "EMPRESAS E FILIAIS";

  function submitPreparationForm(event: React.FormEvent<HTMLFormElement>) {
    event.preventDefault();
    setMessage("");
    setFormError("");
    const form = event.currentTarget;
    if (!form.reportValidity()) return;
    if (cnpj && !isValidCnpj(cnpj)) {
      setFormError("Confira o CNPJ informado. A validação realizada é apenas local.");
      return;
    }
    setMessage("Os campos foram conferidos localmente. A gravação estará disponível após a ativação segura do módulo.");
  }

  return (
    <>
      <div className="page-heading-row companies-heading">
        <div><p className="page-kicker">E-CONTROL / {kicker}</p><h1>{heading}</h1><p className="page-subtitle">Gerenciamento em preparação, sem acesso a dados empresariais nesta etapa.</p></div>
        <span className="workspace-badge"><span className="environment-dot" /> Em preparação</span>
      </div>

      {view === "companies" && <>
        <div className="companies-toolbar">
          <label className="companies-search" htmlFor="company-search"><span aria-hidden="true">⌕</span><input id="company-search" type="search" placeholder="Pesquisar por nome ou CNPJ" value={query} onChange={(event) => setQuery(event.target.value)} /></label>
          <select aria-label="Filtrar situação" defaultValue="all"><option value="all">Todas as situações</option><option value="active">Ativa</option><option value="suspended">Suspensa</option><option value="inactive">Inativa</option></select>
          <a className="primary-button companies-action" href="/empresas/nova">Nova empresa</a>
        </div>
        <div className="companies-subnav" aria-label="Navegação de empresas e filiais"><a className="is-current" href="/empresas" aria-current="page">Empresas</a><a href="/empresas/filiais">Filiais</a></div>
        <StatusLegend />
        {emptyCompanies.length === 0 ? <EmptyState title={query ? "Nenhuma empresa encontrada" : "Nenhuma empresa disponível"} detail={query ? "A pesquisa é somente visual. Registros reais aparecerão quando a integração autorizada estiver ativa." : "Empresas reais serão exibidas após a ativação segura do módulo e a autorização do escopo empresarial."} actionLabel="Preparar cadastro" actionHref="/empresas/nova" /> : <CompanyRows />}
        <PendingActions labels={["Visualizar", "Editar", "Gerenciar filiais"]} />
        <WorkspaceFootnote />
      </>}

      {view === "branches" && <>
        <div className="companies-toolbar">
          <label className="companies-search" htmlFor="branch-search"><span aria-hidden="true">⌕</span><input id="branch-search" type="search" placeholder="Pesquisar filiais" value={query} onChange={(event) => setQuery(event.target.value)} /></label>
          <select aria-label="Filtrar situação" defaultValue="all"><option value="all">Todas as situações</option><option value="active">Ativa</option><option value="suspended">Suspensa</option><option value="inactive">Inativa</option></select>
          <a className="primary-button companies-action" href="/empresas/filiais/nova">Nova filial</a>
        </div>
        <div className="companies-subnav" aria-label="Navegação de empresas e filiais"><a href="/empresas">Empresas</a><a className="is-current" href="/empresas/filiais" aria-current="page">Filiais</a></div>
        <StatusLegend />
        <div className="selected-company-note"><strong>Empresa selecionada:</strong> nenhuma. A lista depende de uma empresa real e de acesso autorizado.</div>
        {emptyBranches.length === 0 ? <EmptyState title={query ? "Nenhuma filial encontrada" : "Selecione uma empresa autorizada"} detail={query ? "Nenhum registro é consultado nesta etapa." : "Filiais e identificação de matriz serão apresentadas após a seleção de uma empresa real autorizada."} actionLabel="Preparar cadastro de filial" actionHref="/empresas/filiais/nova" /> : <BranchRows />}
        <PendingActions labels={["Detalhes", "Editar"]} />
        <WorkspaceFootnote />
      </>}

      {(isCompanyForm || isBranchForm) && <>
        <div className="form-back-link"><a href={isCompanyForm ? "/empresas" : "/empresas/filiais"}>← Voltar para {isCompanyForm ? "empresas" : "filiais"}</a></div>
        <div className="form-preparation-callout" role="note"><strong>Formulário em preparação</strong><span>Preenchimento e validação local apenas. Nenhum dado será enviado ou gravado.</span></div>
        <form className="business-form" onSubmit={submitPreparationForm}>
          {isBranchForm && <fieldset className="form-section"><legend>Vínculo empresarial</legend><div className="form-grid"><label className="field-label form-field form-field-wide">Empresa vinculada<input disabled value="Selecione uma empresa real e autorizada quando a integração estiver disponível" aria-label="Empresa vinculada" /></label><p className="field-hint form-field-wide">Não há empresas carregadas; não é possível selecionar ou vincular uma empresa nesta etapa.</p></div></fieldset>}
          <fieldset className="form-section"><legend>{isCompanyForm ? "Dados da empresa" : "Identificação da filial"}</legend><div className="form-grid">
            {isCompanyForm && <><Field label="Razão social" required autoComplete="organization" /><Field label="Nome fantasia" autoComplete="organization" /></>}
            {isBranchForm && <><Field label="Nome da filial" required /><Field label="Código interno" required /></>}
            <label className="field-label form-field">CNPJ{isBranchForm && <span className="optional-label">quando aplicável</span>}<input inputMode="numeric" autoComplete="off" placeholder="00.000.000/0000-00" value={cnpj} onChange={(event) => setCnpj(formatCnpj(event.target.value))} aria-describedby="cnpj-hint" /></label>
            <Field label="Inscrição estadual" />
            {isCompanyForm && <><Field label="E-mail" type="email" autoComplete="email" /><PhoneField phone={phone} setPhone={setPhone} /></>}
            {isBranchForm && <><Field label="E-mail" type="email" autoComplete="email" /><PhoneField phone={phone} setPhone={setPhone} /></>}
            <label className="field-label form-field">CEP<input inputMode="numeric" autoComplete="postal-code" placeholder="00000-000" value={cep} onChange={(event) => setCep(formatCep(event.target.value))} /></label>
            <Field label="Endereço" autoComplete="address-line1" className="form-field-wide" />
            <Field label="Número" />
            <Field label="Complemento" autoComplete="address-line2" />
            <Field label="Bairro" />
            <Field label="Cidade" autoComplete="address-level2" />
            <label className="field-label form-field">Estado<select defaultValue=""><option value="" disabled>Selecione</option>{["AC","AL","AP","AM","BA","CE","DF","ES","GO","MA","MT","MS","MG","PA","PB","PR","PE","PI","RJ","RN","RS","RO","RR","SC","SP","SE","TO"].map((state) => <option key={state}>{state}</option>)}</select></label>
            {isBranchForm && <label className="field-label form-field">Tipo de unidade<select defaultValue="branch"><option value="headquarters">Matriz</option><option value="branch">Filial</option></select></label>}
            <label className="field-label form-field">Situação cadastral<input disabled value="Não consultada nesta etapa" /></label>
          </div></fieldset>
          {formError && <p className="form-message error" role="alert">{formError}</p>}
          {message && <p className="form-message success" role="status">{message}</p>}
          <div className="form-actions"><a className="secondary-button" href={isCompanyForm ? "/empresas" : "/empresas/filiais"}>Cancelar</a><button className="primary-button" type="submit">{isCompanyForm ? "Salvar empresa" : "Salvar filial"}</button></div>
        </form>
        <WorkspaceFootnote />
      </>}
    </>
  );
}

function Field({ label, required = false, type = "text", autoComplete, className = "" }: { label: string; required?: boolean; type?: string; autoComplete?: string; className?: string }) {
  return <label className={`field-label form-field ${className}`}>{label}<input type={type} required={required} autoComplete={autoComplete} /></label>;
}

function PhoneField({ phone, setPhone }: { phone: string; setPhone: (value: string) => void }) {
  return <label className="field-label form-field">Telefone<input type="tel" autoComplete="tel" inputMode="tel" placeholder="(00) 00000-0000" value={phone} onChange={(event) => setPhone(formatPhone(event.target.value))} /></label>;
}

function EmptyState({ title, detail, actionLabel, actionHref }: { title: string; detail: string; actionLabel: string; actionHref: string }) {
  return <section className="companies-empty" aria-live="polite"><div className="empty-icon" aria-hidden="true">⌂</div><h2>{title}</h2><p>{detail}</p><a className="secondary-button" href={actionHref}>{actionLabel}</a></section>;
}

function StatusLegend() {
  return <div className="status-legend" aria-label="Legenda de situação cadastral"><span>Legenda de situação</span><b className="status-pill is-active">Ativa</b><b className="status-pill is-suspended">Suspensa</b><b className="status-pill is-inactive">Inativa</b></div>;
}
function PendingActions({ labels }: { labels: string[] }) {
  return <div className="pending-actions" aria-label="Ações disponíveis após integração"><span>Ações para registros reais:</span>{labels.map((label) => <button type="button" disabled key={label}>{label}</button>)}</div>;
}
function CompanyRows() {
  return <div className="companies-table-wrap"><table className="companies-table"><caption className="visually-hidden">Empresas cadastradas</caption><thead><tr><th>Empresa</th><th>CNPJ</th><th>Situação</th><th>Ações</th></tr></thead><tbody><tr><td colSpan={4}>A lista de empresas reais será conectada após a ativação segura do módulo.</td></tr></tbody></table></div>;
}
function BranchRows() {
  return <div className="companies-table-wrap"><table className="companies-table"><caption className="visually-hidden">Filiais cadastradas</caption><thead><tr><th>Unidade</th><th>Código</th><th>Tipo</th><th>Situação</th><th>Ações</th></tr></thead><tbody><tr><td colSpan={5}>A lista de filiais reais será conectada após a seleção de uma empresa autorizada.</td></tr></tbody></table></div>;
}
function WorkspaceFootnote() { return <footer className="erp-footer"><span>eControll ERP</span><span>Área de preparação · Sem consulta ou gravação de dados empresariais</span></footer>; }
