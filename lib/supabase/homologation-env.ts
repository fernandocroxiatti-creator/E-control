export const HOMOLOGATION_PROJECT_ID = "psqetcrjrhbamefpfnje";
export const HOMOLOGATION_SUPABASE_URL = "https://psqetcrjrhbamefpfnje.supabase.co";

export const PRODUCTION_PROJECT_ID = "wlqsjwofypqxwleacsvh";
export const PRODUCTION_SUPABASE_URL = "https://wlqsjwofypqxwleacsvh.supabase.co";

export type HomologationEnvironment = Record<string, string | undefined>;

export type SupabaseEnvironment = {
  target: "homologation" | "production";
  projectId: string;
  url: string;
  publishableKey: string;
  companyCreationEnabled: boolean;
  companyManagementEnabled: boolean;
  companyInvitationsEnabled: boolean;
  operationalEnabled: boolean;
};

/** Resolves the isolated local HML configuration. */
export function resolveHomologationSupabaseEnv(
  env: HomologationEnvironment,
): SupabaseEnvironment | null {
  const projectId = env.ECONTROLL_HML_PROJECT_ID;
  const url = env.ECONTROLL_HML_SUPABASE_URL;
  const publishableKey = env.ECONTROLL_HML_PUBLISHABLE_KEY;

  if (env.ECONTROLL_SUPABASE_TARGET !== "homologation" || env.ECONTROLL_HML_ENABLED !== "true") return null;
  if (env.ECONTROLL_PROD_ENABLED === "true" || env.ECONTROLL_PROD_PROJECT_ID || env.ECONTROLL_PROD_SUPABASE_URL) return null;
  if (!projectId || projectId === PRODUCTION_PROJECT_ID || projectId !== HOMOLOGATION_PROJECT_ID) return null;
  if (!url || url === PRODUCTION_SUPABASE_URL || url !== HOMOLOGATION_SUPABASE_URL) return null;
  if (!publishableKey || !/^sb_publishable_[A-Za-z0-9_-]+$/.test(publishableKey)) return null;
  if (/service_role|sb_secret_/i.test(publishableKey)) return null;

  return {
    target: "homologation",
    projectId,
    url,
    publishableKey,
    companyCreationEnabled: env.ECONTROLL_HML_COMPANY_CREATION_ENABLED === "true",
    companyManagementEnabled: env.ECONTROLL_HML_COMPANY_MANAGEMENT_ENABLED === "true",
    companyInvitationsEnabled: env.ECONTROLL_HML_COMPANY_INVITATIONS_ENABLED === "true",
    operationalEnabled: env.ECONTROLL_HML_OPERATIONAL_ENABLED === "true",
  };
}

/**
 * Resolves a Vercel Preview only when its standard public Supabase URL is the
 * exact HML project. This keeps Preview simple without accepting production as
 * an implicit fallback. Write capabilities are deliberately unavailable here.
 */
export function resolvePreviewHomologationSupabaseEnv(
  env: HomologationEnvironment,
): SupabaseEnvironment | null {
  const url = env.NEXT_PUBLIC_SUPABASE_URL;
  const publishableKey = env.NEXT_PUBLIC_SUPABASE_PUBLISHABLE_KEY;

  if (env.ECONTROLL_SUPABASE_TARGET || env.ECONTROLL_HML_ENABLED || env.ECONTROLL_PROD_ENABLED) return null;
  if (env.ECONTROLL_HML_PROJECT_ID || env.ECONTROLL_HML_SUPABASE_URL || env.ECONTROLL_HML_PUBLISHABLE_KEY) return null;
  if (env.ECONTROLL_PROD_PROJECT_ID || env.ECONTROLL_PROD_SUPABASE_URL) return null;
  if (url !== HOMOLOGATION_SUPABASE_URL) return null;
  if (!publishableKey || !/^sb_publishable_[A-Za-z0-9_-]+$/.test(publishableKey)) return null;
  if (/service_role|sb_secret_/i.test(publishableKey)) return null;

  return {
    target: "homologation",
    projectId: HOMOLOGATION_PROJECT_ID,
    url,
    publishableKey,
    companyCreationEnabled: false,
    companyManagementEnabled: false,
    companyInvitationsEnabled: false,
    operationalEnabled: false,
  };
}

/** Resolves production only when both the deployment target and its exact project
 * identity are explicitly configured. It never reads HML-specific credentials. */
export function resolveProductionSupabaseEnv(env: HomologationEnvironment): SupabaseEnvironment | null {
  const projectId = env.ECONTROLL_PROD_PROJECT_ID;
  const url = env.ECONTROLL_PROD_SUPABASE_URL;
  const publicUrl = env.NEXT_PUBLIC_SUPABASE_URL;
  const publishableKey = env.NEXT_PUBLIC_SUPABASE_PUBLISHABLE_KEY;

  if (env.ECONTROLL_SUPABASE_TARGET !== "production" || env.ECONTROLL_PROD_ENABLED !== "true") return null;
  if (env.ECONTROLL_HML_ENABLED === "true" || env.ECONTROLL_HML_PROJECT_ID || env.ECONTROLL_HML_SUPABASE_URL) return null;
  if (projectId !== PRODUCTION_PROJECT_ID || url !== PRODUCTION_SUPABASE_URL || publicUrl !== PRODUCTION_SUPABASE_URL) return null;
  if (!publishableKey || !/^sb_publishable_[A-Za-z0-9_-]+$/.test(publishableKey) || /service_role|sb_secret_/i.test(publishableKey)) return null;

  return {
    target: "production",
    projectId,
    url,
    publishableKey,
    companyCreationEnabled: env.ECONTROLL_PROD_COMPANY_CREATION_ENABLED === "true",
    companyManagementEnabled: env.ECONTROLL_PROD_COMPANY_MANAGEMENT_ENABLED === "true",
    companyInvitationsEnabled: env.ECONTROLL_PROD_COMPANY_INVITATIONS_ENABLED === "true",
    operationalEnabled: env.ECONTROLL_PROD_OPERATIONAL_ENABLED === "true",
  };
}

export function resolveSupabaseEnv(env: HomologationEnvironment): SupabaseEnvironment | null {
  if (env.ECONTROLL_SUPABASE_TARGET === "homologation") return resolveHomologationSupabaseEnv(env);
  if (env.ECONTROLL_SUPABASE_TARGET === "production") return resolveProductionSupabaseEnv(env);
  if (!env.ECONTROLL_SUPABASE_TARGET) return resolvePreviewHomologationSupabaseEnv(env);
  return null;
}

export function isAuthorizedSupabaseTarget(value: Pick<SupabaseEnvironment, "target" | "projectId" | "url">): boolean {
  if (value.target === "homologation") return isHomologationTarget(value);
  if (value.target === "production") {
    return value.projectId === PRODUCTION_PROJECT_ID && value.url === PRODUCTION_SUPABASE_URL;
  }
  return false;
}

export function isHomologationTarget(value: Pick<SupabaseEnvironment, "projectId" | "url">): boolean {
  const isProductionProject = value.projectId === PRODUCTION_PROJECT_ID;
  const isProductionUrl = value.url === PRODUCTION_SUPABASE_URL;
  return !isProductionProject
    && !isProductionUrl
    && value.projectId === HOMOLOGATION_PROJECT_ID
    && value.url === HOMOLOGATION_SUPABASE_URL;
}

function getVercelPreviewSiteUrl(env: HomologationEnvironment): URL | null {
  if (env.VERCEL_ENV !== "preview") return null;
  const host = env.VERCEL_BRANCH_URL ?? env.VERCEL_URL;
  if (!host || !/^e-control(?:-[a-z0-9-]+)?\.vercel\.app$/.test(host)) return null;
  return new URL(`https://${host}`);
}

/** Recovery links for HML stay local or use Vercel's validated Preview host. */
export function getHomologationSiteUrl(env: HomologationEnvironment): URL {
  const configured = env.ECONTROLL_HML_SITE_URL;
  if (configured) {
    try {
      const url = new URL(configured);
      const localHost = url.hostname === "localhost" || url.hostname === "127.0.0.1";
      const allowedPort = ["3000", "3001", "3103", "3104", "3105"].includes(url.port);
      if (url.protocol === "http:" && localHost && allowedPort && !url.username && !url.password
        && url.pathname === "/" && !url.search && !url.hash) return url;
    } catch {
      // Invalid or non-local redirect targets fail closed below.
    }
  }
  const previewUrl = getVercelPreviewSiteUrl(env);
  if (previewUrl) return previewUrl;
  return new URL("http://localhost:3000");
}

export function getProductionSiteUrl(env: HomologationEnvironment): URL | null {
  if (!resolveProductionSupabaseEnv(env)) return null;
  const configured = env.ECONTROLL_PROD_SITE_URL;
  if (configured !== "https://e-control-delta.vercel.app") return null;
  try {
    const url = new URL(configured);
    if (url.protocol === "https:" && url.hostname === "e-control-delta.vercel.app"
      && !url.port && !url.username && !url.password && url.pathname === "/" && !url.search && !url.hash) return url;
  } catch {
    // Invalid site URL fails closed.
  }
  return null;
}
