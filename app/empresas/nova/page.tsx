import { CompaniesWorkspace } from "@/app/components/companies-workspace";

export default function NewCompanyPage() {
  return <CompaniesWorkspace view="new-company" contexts={[]} accessStatus="no_active_membership" operationalEnabled={false} />;
}
