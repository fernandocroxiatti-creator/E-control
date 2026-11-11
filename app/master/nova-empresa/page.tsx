import { CompanyOnboardingWizard } from "@/app/master/nova-empresa/company-onboarding-wizard";
import { DataPanel, PageHeading } from "@/app/master/master-data-ui";
import { getMasterCompanyCreationEnabled, getMasterCompanyManagementEnabled, getMasterCompanyInvitationsEnabled } from "@/lib/master/read-model";

export const dynamic = "force-dynamic";

export default async function NewCompanyOnboardingPage() {
  const [creationEnabled, managementEnabled, invitationsEnabled] = await Promise.all([
    getMasterCompanyCreationEnabled(), getMasterCompanyManagementEnabled(), getMasterCompanyInvitationsEnabled(),
  ]);
  const enabled = creationEnabled && managementEnabled && invitationsEnabled;
  return <><PageHeading title="Nova empresa" description="Crie um cliente, sua filial principal, o catálogo contratado e o convite do proprietário em etapas auditáveis." meta={enabled ? "Onboarding disponível" : "Aguardando configuração"} />
    <DataPanel title="Onboarding empresarial" description="Cada etapa usa uma RPC ou Server Action autorizada. Nenhuma permissão operacional, vínculo ou transação é criada automaticamente."><CompanyOnboardingWizard enabled={enabled} /></DataPanel>
  </>;
}
