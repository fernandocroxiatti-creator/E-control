import { NextResponse, type NextRequest } from "next/server";
import { randomUUID, timingSafeEqual } from "node:crypto";
import type { EmailOtpType } from "@supabase/supabase-js";
import { resolveAuthActivationDestination } from "@/lib/supabase/auth-activation";
import { getSiteUrl } from "@/lib/supabase/env";
import { createClient } from "@/lib/supabase/server";

const EMAIL_ACTION_TYPES = new Set<EmailOtpType>(["invite", "recovery"]);
const CSRF_COOKIE = "econtroll_auth_confirm_csrf";

const CONFIRMATION_HEADERS = {
  "Cache-Control": "no-store, private, max-age=0",
  "Pragma": "no-cache",
  "Referrer-Policy": "no-referrer",
  "Content-Security-Policy": "default-src 'none'; style-src 'unsafe-inline'; base-uri 'none'; form-action 'self'; frame-ancestors 'none'",
  "X-Content-Type-Options": "nosniff",
  "X-Frame-Options": "DENY",
  "Permissions-Policy": "camera=(), microphone=(), geolocation=()",
};

function failure(reason: "invite-invalid" | "recovery-invalid") {
  const response = NextResponse.redirect(new URL(`/login?auth=${reason}`, getSiteUrl()));
  applyConfirmationHeaders(response);
  response.cookies.set({ name: CSRF_COOKIE, value: "", path: "/auth/confirm", maxAge: 0 });
  return response;
}

function applyConfirmationHeaders(response: NextResponse) {
  Object.entries(CONFIRMATION_HEADERS).forEach(([name, value]) => response.headers.set(name, value));
}

function methodNotAllowed() {
  const response = new NextResponse(null, { status: 405 });
  applyConfirmationHeaders(response);
  response.headers.set("Allow", "GET, POST");
  return response;
}

function escapeHtml(value: string) {
  return value.replace(/[&<>'"]/g, (character) => ({
    "&": "&amp;",
    "<": "&lt;",
    ">": "&gt;",
    "'": "&#39;",
    "\"": "&quot;",
  })[character] ?? character);
}

function validSubmissionCsrf(expected: string | undefined, received: string) {
  if (!expected || !received || expected.length !== received.length) return false;
  return timingSafeEqual(Buffer.from(expected), Buffer.from(received));
}

function sameOriginRequest(request: NextRequest) {
  const siteUrl = getSiteUrl();
  if (request.headers.get("origin") !== siteUrl.origin) return false;

  // Browsers that send Fetch Metadata must identify this as a same-origin
  // navigation. Safari versions that do not emit this header remain supported.
  const fetchSite = request.headers.get("sec-fetch-site");
  return !fetchSite || fetchSite === "same-origin";
}

function validRequest(
  tokenHash: string | null,
  rawType: string | null,
  redirectTo: string | null,
) {
  const type = rawType as EmailOtpType;
  const destination = resolveAuthActivationDestination(redirectTo);
  if (!tokenHash || !destination || !EMAIL_ACTION_TYPES.has(type)) return null;

  // An invite link must remain an invite link, and a recovery link must
  // remain a recovery link; a token cannot switch the server-owned flow.
  if ((type === "invite" && destination.flow === "password-recovery")
    || (type === "recovery" && destination.flow !== "password-recovery")) return null;

  return { tokenHash, type, destination };
}

function confirmationPage({ tokenHash, type, redirectTo, csrf }: {
  tokenHash: string;
  type: EmailOtpType;
  redirectTo: string;
  csrf: string;
}) {
  // This document intentionally contains no scripts, images or third-party
  // resources. The token exists only in this uncached response and the form
  // body; it is never copied to storage, cookies, logs or a redirect URL.
  return `<!doctype html>
<html lang="pt-BR">
  <head><meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1"><title>Confirmar acesso · eControll</title></head>
  <body>
    <main>
      <h1>Confirmar acesso</h1>
      <p>Para sua segurança, confirme que deseja continuar.</p>
      <form method="post" action="/auth/confirm" autocomplete="off">
        <input type="hidden" name="token_hash" value="${escapeHtml(tokenHash)}">
        <input type="hidden" name="type" value="${escapeHtml(type)}">
        <input type="hidden" name="redirect_to" value="${escapeHtml(redirectTo)}">
        <input type="hidden" name="csrf" value="${escapeHtml(csrf)}">
        <button type="submit">Continuar com segurança</button>
      </form>
    </main>
  </body>
</html>`;
}

/**
 * Displays a deliberate, script-free confirmation before consuming an Auth
 * e-mail token. A GET is safe for link previewers and most mail scanners.
 */
export async function GET(request: NextRequest) {
  const validation = validRequest(
    request.nextUrl.searchParams.get("token_hash"),
    request.nextUrl.searchParams.get("type"),
    request.nextUrl.searchParams.get("redirect_to"),
  );

  if (!validation) {
    return failure(request.nextUrl.searchParams.get("type") === "recovery" ? "recovery-invalid" : "invite-invalid");
  }

  const csrf = randomUUID();
  const response = new NextResponse(confirmationPage({
    tokenHash: validation.tokenHash,
    type: validation.type,
    redirectTo: request.nextUrl.searchParams.get("redirect_to")!,
    csrf,
  }), { status: 200, headers: { "Content-Type": "text/html; charset=utf-8" } });
  applyConfirmationHeaders(response);
  response.cookies.set({
    name: CSRF_COOKIE,
    value: csrf,
    httpOnly: true,
    sameSite: "strict",
    secure: process.env.NODE_ENV === "production",
    path: "/auth/confirm",
  });
  return response;
}

// Do not delegate HEAD to GET. Link previewers may probe with HEAD, and only
// an explicit POST may validate a token.
export function HEAD() {
  return methodNotAllowed();
}

export function OPTIONS() {
  return methodNotAllowed();
}

/**
 * Consumes an Auth token only after an explicit same-origin form submission.
 */
export async function POST(request: NextRequest) {
  if (!sameOriginRequest(request)) return failure("invite-invalid");

  const form = await request.formData();
  const tokenHash = form.get("token_hash");
  const rawType = form.get("type");
  const redirectTo = form.get("redirect_to");
  const csrf = form.get("csrf");
  const type = typeof rawType === "string" ? rawType : null;
  const validation = validRequest(
    typeof tokenHash === "string" ? tokenHash : null,
    type,
    typeof redirectTo === "string" ? redirectTo : null,
  );

  if (!validation || typeof csrf !== "string" || !validSubmissionCsrf(request.cookies.get(CSRF_COOKIE)?.value, csrf)) {
    return failure(type === "recovery" ? "recovery-invalid" : "invite-invalid");
  }

  const supabase = await createClient();
  if (!supabase) return failure(validation.type === "recovery" ? "recovery-invalid" : "invite-invalid");

  // verifyOtp replaces a previous browser session with the identity bound to
  // the one-time link. No browser-supplied e-mail, user ID or return URL is
  // trusted, and no token is logged or included in the final location.
  const { data, error } = await supabase.auth.verifyOtp({ token_hash: validation.tokenHash, type: validation.type });
  if (error || !data.user || !data.session) {
    return failure(validation.type === "recovery" ? "recovery-invalid" : "invite-invalid");
  }

  const response = NextResponse.redirect(new URL(validation.destination.destination, getSiteUrl()));
  applyConfirmationHeaders(response);
  response.cookies.set({ name: CSRF_COOKIE, value: "", path: "/auth/confirm", maxAge: 0 });
  return response;
}

/**
 * Legacy note: token validation intentionally happens in POST, never GET.
 * Do not move verifyOtp into GET: mail security scanners can prefetch links.
 *
 * A scanner capable of retaining cookies and submitting same-origin forms can
 * still behave like a browser. The rollout therefore also requires direct,
 * non-rewritten Auth links and a controlled production test.
 */
