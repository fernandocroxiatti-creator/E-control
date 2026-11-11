import {
  getHomologationSiteUrl,
  getProductionSiteUrl,
  resolveSupabaseEnv,
} from "./homologation-env";

export { safeInternalPath } from "./homologation-env";

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
