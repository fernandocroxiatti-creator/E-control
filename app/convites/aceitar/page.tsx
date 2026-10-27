import Image from "next/image";
import { AcceptCompanyAdminInvitationForm } from "@/app/convites/aceitar/accept-invitation-form";
import { createClient } from "@/lib/supabase/server";

export const dynamic = "force-dynamic";

export default async function AcceptCompanyAdminInvitationPage() {
  const client = await createClient();
  let authenticated = false;
  if (client) {
    try {
      const { data, error } = await client.auth.getUser();
      authenticated = !error && Boolean(data.user);
    } catch {
      authenticated = false;
    }
  }
  return <main className="auth-shell">
    <div className="brand-lockup"><Image className="brand-mark brand-mark-image" src="/econtroll-logo.png" width={64} height={64} alt="" aria-hidden="true" /><span>eControll</span></div>
    <AcceptCompanyAdminInvitationForm authenticated={authenticated} />
    <footer className="page-footer">eControll · Convite empresarial seguro</footer>
  </main>;
}
