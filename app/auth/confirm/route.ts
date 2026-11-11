import { NextResponse, type NextRequest } from "next/server";
import type { EmailOtpType } from "@supabase/supabase-js";
import { resolveAuthActivationDestination } from "@/lib/supabase/auth-activation";
import { getSiteUrl } from "@/lib/supabase/env";
import { createClient } from "@/lib/supabase/server";

const EMAIL_ACTION_TYPES = new Set<EmailOtpType>(["invite", "recovery"]);

function failure(reason: "invite-invalid" | "recovery-invalid") {
  return NextResponse.redirect(new URL(`/login?auth=${reason}`, getSiteUrl()));
}

/**
 * Server-side confirmation for e-mail invitation and recovery links.
 *
 * Supabase's default e-mail links return a session in a URL fragment. A
 * fragment is intentionally absent from HTTP requests, so an SSR callback
 * cannot validate it. The hosted e-mail templates point here with TokenHash;
 * verifyOtp then writes the newly verified session cookies before redirecting.
 */
export async function GET(request: NextRequest) {
  const tokenHash = request.nextUrl.searchParams.get("token_hash");
  const rawType = request.nextUrl.searchParams.get("type");
  const destination = resolveAuthActivationDestination(request.nextUrl.searchParams.get("redirect_to"));
  const type = rawType as EmailOtpType;

  if (!tokenHash || !destination || !EMAIL_ACTION_TYPES.has(type)) {
    return failure(rawType === "recovery" ? "recovery-invalid" : "invite-invalid");
  }

  // An invite link must remain an invite link, and a recovery link must
  // remain a recovery link; a token cannot switch the server-owned flow.
  if ((type === "invite" && destination.flow === "password-recovery")
    || (type === "recovery" && destination.flow !== "password-recovery")) {
    return failure(type === "recovery" ? "recovery-invalid" : "invite-invalid");
  }

  const supabase = await createClient();
  if (!supabase) return failure(type === "recovery" ? "recovery-invalid" : "invite-invalid");

  // verifyOtp replaces a previous browser session with the identity bound to
  // the one-time link. No browser-supplied e-mail, user ID or return URL is
  // trusted, and no token is logged or included in the final location.
  const { data, error } = await supabase.auth.verifyOtp({ token_hash: tokenHash, type });
  if (error || !data.user || !data.session) {
    return failure(type === "recovery" ? "recovery-invalid" : "invite-invalid");
  }

  return NextResponse.redirect(new URL(destination.destination, getSiteUrl()));
}
