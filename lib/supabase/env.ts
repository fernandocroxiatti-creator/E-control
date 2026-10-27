import {
  getHomologationSiteUrl,
  getProductionSiteUrl,
  resolveSupabaseEnv,
} from "./homologation-env";

export function getSupabaseEnv() {
  return resolveSupabaseEnv(process.env);
}

export function getSiteUrl() {
  const target = resolveSupabaseEnv(process.env);
  if (target?.target === "homologation") return getHomologationSiteUrl(process.env);
  if (target?.target === "production") {
    const url = getProductionSiteUrl(process.env);
    if (url) return url;
  }
  throw new Error("Supabase target or site URL is not explicitly configured.");
}

export function safeInternalPath(value: string | null | undefined, fallback = "/dashboard") {
  if (!value || !value.startsWith("/") || value.startsWith("//") || value.includes("\\")) {
    return fallback;
  }

  try {
    const resolved = new URL(value, "http://localhost");
    return resolved.origin === "http://localhost" ? `${resolved.pathname}${resolved.search}${resolved.hash}` : fallback;
  } catch {
    return fallback;
  }
}
