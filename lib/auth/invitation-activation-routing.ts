export const AUTH_ACTIVATION_FLOWS = {
  companyOwnerInvite: "company-owner-invite",
  employeeInvite: "employee-invite",
  passwordRecovery: "password-recovery",
} as const;

export type AuthActivationFlow = typeof AUTH_ACTIVATION_FLOWS[keyof typeof AUTH_ACTIVATION_FLOWS];

export type ActivationDestination = {
  flow: AuthActivationFlow;
  destination: string;
};

const DESTINATIONS: Record<AuthActivationFlow, string> = {
  [AUTH_ACTIVATION_FLOWS.companyOwnerInvite]: "/reset-password?setup=invite&next=%2Fconvites%2Faceitar",
  [AUTH_ACTIVATION_FLOWS.employeeInvite]: "/reset-password?setup=invite&next=%2Fconvites%2Ffuncionario%2Faceitar",
  [AUTH_ACTIVATION_FLOWS.passwordRecovery]: "/reset-password?setup=recovery&next=%2Fdashboard",
};

// These are the only callback targets emitted before SSR confirmation is
// enabled. They are kept solely for a safe, finite transition of Auth e-mails.
const LEGACY_CALLBACK_NEXT: Record<AuthActivationFlow, string> = {
  [AUTH_ACTIVATION_FLOWS.companyOwnerInvite]: "/reset-password?next=%2Fconvites%2Faceitar",
  [AUTH_ACTIVATION_FLOWS.employeeInvite]: "/reset-password?next=%2Fconvites%2Ffuncionario%2Faceitar",
  [AUTH_ACTIVATION_FLOWS.passwordRecovery]: "/reset-password",
};

function destinationForFlow(flow: string | null): ActivationDestination | null {
  if (!flow || !(flow in DESTINATIONS)) return null;
  const typedFlow = flow as AuthActivationFlow;
  return { flow: typedFlow, destination: DESTINATIONS[typedFlow] };
}

function legacyDestinationForNext(next: string | null): ActivationDestination | null {
  if (!next) return null;
  const flow = (Object.keys(LEGACY_CALLBACK_NEXT) as AuthActivationFlow[])
    .find((candidate) => LEGACY_CALLBACK_NEXT[candidate] === next);
  return flow ? { flow, destination: DESTINATIONS[flow] } : null;
}

/** The redirectTo path emitted to Supabase Auth, selected only on the server. */
export function authActivationRedirectPath(flow: AuthActivationFlow, ssrConfirmationEnabled: boolean): string {
  if (ssrConfirmationEnabled) return `/auth/confirm?flow=${encodeURIComponent(flow)}`;

  const callback = new URL("/auth/callback", "http://localhost");
  callback.searchParams.set("next", LEGACY_CALLBACK_NEXT[flow]);
  return `${callback.pathname}${callback.search}`;
}

/**
 * Maps a supplied Supabase RedirectTo to a fixed internal destination. Both
 * the canonical SSR target and the exact historical callback targets are
 * accepted; every other origin, path and query shape fails closed.
 */
export function resolveAuthActivationDestination(
  value: string | null,
  expectedSiteUrl: URL,
): ActivationDestination | null {
  if (!value) return null;

  try {
    const received = new URL(value);
    if (received.protocol !== expectedSiteUrl.protocol
      || received.host !== expectedSiteUrl.host
      || received.username
      || received.password
      || received.hash) return null;

    if (received.pathname === "/auth/confirm" && received.searchParams.size === 1) {
      return destinationForFlow(received.searchParams.get("flow"));
    }

    if (received.pathname === "/auth/callback" && received.searchParams.size === 1) {
      return legacyDestinationForNext(received.searchParams.get("next"));
    }
  } catch {
    // Malformed or external redirectTo values must never become navigation.
  }
  return null;
}
