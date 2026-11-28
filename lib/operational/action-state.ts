export type OperationalActionState = { status: "idle" | "success" | "error"; message?: string };
export const operationalIdle: OperationalActionState = { status: "idle" };
