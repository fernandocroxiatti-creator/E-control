import { notFound, redirect } from "next/navigation";
import { FirstMasterBootstrapConfirmationForm } from "./confirmation-form";
import { createClient } from "@/lib/supabase/server";
import { isCurrentSessionApprovedForFirstMaster, isFirstMasterBootstrapInvokerEnabled } from "@/lib/first-master-bootstrap";

export const dynamic = "force-dynamic";
export const revalidate = 0;

export default async function FirstMasterBootstrapPage() {
  if (!isFirstMasterBootstrapInvokerEnabled()) notFound();
  const supabase = await createClient();
  if (!supabase) notFound();
  const authenticated = await supabase.auth.getUser();
  if (authenticated.error || !authenticated.data.user) redirect("/login?next=%2Ffirst-master-bootstrap");
  if (!await isCurrentSessionApprovedForFirstMaster(supabase)) notFound();
  return <FirstMasterBootstrapConfirmationForm />;
}
