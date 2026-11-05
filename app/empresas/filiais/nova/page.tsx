import { CompaniesWorkspace } from "@/app/components/companies-workspace";

export default function NewBranchPage() {
  return <CompaniesWorkspace view="new-branch" contexts={[]} accessStatus="no_active_membership" operationalEnabled={false} />;
}
