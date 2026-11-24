import "server-only";

/** Logs only an opaque correlation ID and a bounded database/runtime code.
 * Never include form values, Supabase messages, users, tenant IDs or secrets. */
export function reportBusinessPartyFailure(diagnosticId: string, error: unknown) {
  const code = typeof error === "object" && error !== null && "code" in error && typeof error.code === "string"
    ? error.code.slice(0, 16)
    : "UNEXPECTED";
  console.error(JSON.stringify({ event: "business_party.create.failed", diagnostic_id: diagnosticId, code }));
}
