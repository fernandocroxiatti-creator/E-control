import "server-only";
import {
  authActivationRedirectPath,
  resolveAuthActivationDestination as resolveDestination,
  type AuthActivationFlow,
} from "@/lib/auth/invitation-activation-routing";
import { getSiteUrl } from "@/lib/supabase/env";

export { AUTH_ACTIVATION_FLOWS } from "@/lib/auth/invitation-activation-routing";

/** Disabled unless explicitly enabled in a server-only Vercel environment. */
export function authSsrInvitationConfirmationEnabled() {
  return process.env.ECONTROLL_AUTH_SSR_CONFIRMATION_ENABLED === "true";
}

/** Builds a canonical redirectTo while preserving the legacy default rollout. */
export function getAuthActivationRedirectUrl(flow: AuthActivationFlow): string {
  return new URL(
    authActivationRedirectPath(flow, authSsrInvitationConfirmationEnabled()),
    getSiteUrl(),
  ).toString();
}

/** Strictly resolves both current SSR and transitional legacy callback URLs. */
export function resolveAuthActivationDestination(value: string | null) {
  return resolveDestination(value, getSiteUrl());
}
