export type MasterAccessActionState = {
  status: "idle" | "success" | "error";
  message?: string;
};

// Client-side initial state. Keep values out of `use server` modules: Next.js
// Server Action files may export only async functions at runtime.
export const masterAccessIdle: MasterAccessActionState = { status: "idle" };
