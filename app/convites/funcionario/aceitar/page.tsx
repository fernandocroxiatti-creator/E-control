import Image from "next/image";
import { AcceptEmployeeInvitationForm } from "@/app/convites/funcionario/aceitar/accept-employee-invitation-form";
import { getSupabaseEnv } from "@/lib/supabase/env";
import { isAuthorizedSupabaseTarget } from "@/lib/supabase/homologation-env";
import { createClient } from "@/lib/supabase/server";

export const dynamic = "force-dynamic";

export default async function AcceptEmployeeInvitationPage() {
  const env = getSupabaseEnv();
  const enabled = Boolean(env && isAuthorizedSupabaseTarget(env) && env.operationalEnabled);
  const client = await createClient();
  let authenticated = false;
  if (client) {
    const { data, error } = await client.auth.getUser();
    authenticated = !error && Boolean(data.user);
  }
  return <main className="auth-shell">
    <div className="brand-lockup"><Image className="brand-mark brand-mark-image" src="/econtroll-logo.png" width={64} height={64} alt="" aria-hidden="true" /><span>eControll</span></div>
    <AcceptEmployeeInvitationForm authenticated={authenticated} enabled={enabled} />
    <footer className="page-footer">eControll · Convite empresarial seguro</footer>
  </main>;
}
