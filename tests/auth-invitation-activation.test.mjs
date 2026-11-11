import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { fileURLToPath } from "node:url";
import { resolve } from "node:path";
import test from "node:test";

const root = resolve(fileURLToPath(new URL("..", import.meta.url)));
const read = (file) => readFileSync(resolve(root, file), "utf8");
const routing = await import(new URL("../lib/auth/invitation-activation-routing.ts", import.meta.url));
const routingSource = read("lib/auth/invitation-activation-routing.ts");
const activation = read("lib/supabase/auth-activation.ts");
const confirmationRoute = read("app/auth/confirm/route.ts");
const callbackRoute = read("app/auth/callback/route.ts");
const authActions = read("app/actions/auth.ts");
const companyActions = read("app/actions/company-admin-invitations.ts");
const operationalActions = read("app/actions/operational.ts");
const resetPage = read("app/reset-password/page.tsx");
const loginPage = read("app/login/page.tsx");

test("e-mail activation uses fixed flows and closed internal destinations", () => {
  for (const flow of ["company-owner-invite", "employee-invite", "password-recovery"]) {
    assert.match(routingSource, new RegExp(`: "${flow}"`));
  }
  assert.match(activation, /ECONTROLL_AUTH_SSR_CONFIRMATION_ENABLED === "true"/);
  assert.match(activation, /import "server-only"/);
  assert.match(activation, /authActivationRedirectPath/);
  assert.match(routingSource, /received\.host !== expectedSiteUrl\.host/);
  assert.match(routingSource, /received\.searchParams\.size === 1/);
  assert.doesNotMatch(activation, /\bredirect\([^)]*value/i);
});

test("emission stays legacy by default and switches only with the explicit SSR flag", () => {
  assert.equal(routing.authActivationRedirectPath("company-owner-invite", false), "/auth/callback?next=%2Freset-password%3Fnext%3D%252Fconvites%252Faceitar");
  assert.equal(routing.authActivationRedirectPath("employee-invite", false), "/auth/callback?next=%2Freset-password%3Fnext%3D%252Fconvites%252Ffuncionario%252Faceitar");
  assert.equal(routing.authActivationRedirectPath("password-recovery", false), "/auth/callback?next=%2Freset-password");
  assert.equal(routing.authActivationRedirectPath("company-owner-invite", true), "/auth/confirm?flow=company-owner-invite");
});

test("confirmation accepts only canonical SSR and exact legacy redirects", () => {
  const site = new URL("https://www.econtroll.com.br");
  assert.deepEqual(
    routing.resolveAuthActivationDestination("https://www.econtroll.com.br/auth/confirm?flow=company-owner-invite", site),
    { flow: "company-owner-invite", destination: "/reset-password?setup=invite&next=%2Fconvites%2Faceitar" },
  );
  assert.deepEqual(
    routing.resolveAuthActivationDestination("https://www.econtroll.com.br/auth/callback?next=%2Freset-password%3Fnext%3D%252Fconvites%252Ffuncionario%252Faceitar", site),
    { flow: "employee-invite", destination: "/reset-password?setup=invite&next=%2Fconvites%2Ffuncionario%2Faceitar" },
  );
  for (const unsafe of [
    "https://evil.example/auth/confirm?flow=company-owner-invite",
    "https://www.econtroll.com.br/auth/confirm?flow=company-owner-invite&next=%2Fdashboard",
    "https://www.econtroll.com.br/auth/callback?next=https%3A%2F%2Fevil.example",
    "https://www.econtroll.com.br/auth/confirm?flow=unknown",
  ]) assert.equal(routing.resolveAuthActivationDestination(unsafe, site), null);
});

test("confirmation endpoint shows a script-free interstitial on GET and verifies only on POST", () => {
  assert.match(confirmationRoute, /token_hash/);
  assert.match(confirmationRoute, /new Set<EmailOtpType>\(\["invite", "recovery"\]\)/);
  const getHandler = confirmationRoute.slice(
    confirmationRoute.indexOf("export async function GET"),
    confirmationRoute.indexOf("export function HEAD"),
  );
  const postHandler = confirmationRoute.slice(confirmationRoute.indexOf("export async function POST"));
  assert.doesNotMatch(getHandler, /verifyOtp/);
  assert.match(postHandler, /supabase\.auth\.verifyOtp\(\{ token_hash: validation\.tokenHash, type: validation\.type \}\)/);
  assert.match(confirmationRoute, /export function HEAD\(\)[\s\S]*?methodNotAllowed\(\)/);
  assert.match(confirmationRoute, /export function OPTIONS\(\)[\s\S]*?methodNotAllowed\(\)/);
  assert.match(confirmationRoute, /"Allow", "GET, POST"/);
  assert.match(confirmationRoute, /!data\.user \|\| !data\.session/);
  assert.match(confirmationRoute, /resolveAuthActivationDestination/);
  assert.match(confirmationRoute, /NextResponse\.redirect\(new URL\(validation\.destination\.destination, getSiteUrl\(\)\)\)/);
  assert.match(confirmationRoute, /randomUUID/);
  assert.match(confirmationRoute, /httpOnly: true/);
  assert.match(confirmationRoute, /sameSite: "strict"/);
  assert.match(confirmationRoute, /validSubmissionCsrf/);
  assert.match(confirmationRoute, /request\.headers\.get\("origin"\)/);
  assert.match(confirmationRoute, /"Cache-Control": "no-store, private, max-age=0"/);
  assert.match(confirmationRoute, /"Referrer-Policy": "no-referrer"/);
  assert.match(confirmationRoute, /Content-Security-Policy.*default-src 'none'/);
  assert.doesNotMatch(confirmationRoute, /<script/i);
  assert.doesNotMatch(confirmationRoute, /onload\s*=/i);
  assert.doesNotMatch(confirmationRoute, /localStorage|sessionStorage|document\.cookie/);
  assert.doesNotMatch(confirmationRoute, /console\.(?:log|error)/);
  assert.doesNotMatch(confirmationRoute, /service_role|SUPABASE_SERVICE_ROLE_KEY/i);
});

test("owner, employee and recovery e-mails use only the server-selected rollout target", () => {
  assert.match(companyActions, /getAuthActivationRedirectUrl\(AUTH_ACTIVATION_FLOWS\.companyOwnerInvite\)/);
  assert.match(operationalActions, /getAuthActivationRedirectUrl\(AUTH_ACTIVATION_FLOWS\.employeeInvite\)/);
  assert.match(authActions, /getAuthActivationRedirectUrl\(AUTH_ACTIVATION_FLOWS\.passwordRecovery\)/);
  assert.match(activation, /authSsrInvitationConfirmationEnabled/);
});

test("the password screen explicitly supports first-password activation and invalid links fail visibly", () => {
  assert.match(resetPage, /setup === "invite"/);
  assert.match(resetPage, /Defina sua primeira senha/);
  assert.match(resetPage, /safeInternalPath\(next, "\/dashboard"\)/);
  assert.match(loginPage, /invite-invalid/);
  assert.match(loginPage, /recovery-invalid/);
  assert.match(callbackRoute, /exchangeCodeForSession/);
});
