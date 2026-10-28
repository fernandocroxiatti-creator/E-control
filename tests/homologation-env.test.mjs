import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { resolve } from "node:path";
import { fileURLToPath } from "node:url";
import test from "node:test";
import {
  HOMOLOGATION_PROJECT_ID,
  HOMOLOGATION_SUPABASE_URL,
  PRODUCTION_PROJECT_ID,
  PRODUCTION_SUPABASE_URL,
  getHomologationSiteUrl,
  getProductionSiteUrl,
  isAuthorizedSupabaseTarget,
  isHomologationTarget,
  resolveHomologationSupabaseEnv,
  resolvePreviewHomologationSupabaseEnv,
  resolveProductionSupabaseEnv,
  resolveSupabaseEnv,
} from "../lib/supabase/homologation-env.ts";

const projectRoot = resolve(fileURLToPath(new URL("..", import.meta.url)));
const configured = {
  ECONTROLL_SUPABASE_TARGET: "homologation",
  ECONTROLL_HML_ENABLED: "true",
  ECONTROLL_HML_PROJECT_ID: HOMOLOGATION_PROJECT_ID,
  ECONTROLL_HML_SUPABASE_URL: HOMOLOGATION_SUPABASE_URL,
  ECONTROLL_HML_PUBLISHABLE_KEY: "sb_publishable_test_only_not_a_credential",
};

test("accepts only the exact explicitly enabled homologation project and a publishable key", () => {
  const result = resolveHomologationSupabaseEnv(configured);
  assert.deepEqual(result, {
    target: "homologation",
    projectId: HOMOLOGATION_PROJECT_ID,
    url: HOMOLOGATION_SUPABASE_URL,
    publishableKey: configured.ECONTROLL_HML_PUBLISHABLE_KEY,
    companyCreationEnabled: false,
    companyManagementEnabled: false,
    companyInvitationsEnabled: false,
  });
});

const productionConfigured = {
  ECONTROLL_SUPABASE_TARGET: "production",
  ECONTROLL_PROD_ENABLED: "true",
  ECONTROLL_PROD_PROJECT_ID: PRODUCTION_PROJECT_ID,
  ECONTROLL_PROD_SUPABASE_URL: PRODUCTION_SUPABASE_URL,
  NEXT_PUBLIC_SUPABASE_URL: PRODUCTION_SUPABASE_URL,
  NEXT_PUBLIC_SUPABASE_PUBLISHABLE_KEY: "sb_publishable_production_test_only",
  ECONTROLL_PROD_SITE_URL: "https://e-control-delta.vercel.app",
};

test("accepts only exact explicit production config and keeps writes disabled by default", () => {
  assert.deepEqual(resolveProductionSupabaseEnv(productionConfigured), {
    target: "production",
    projectId: PRODUCTION_PROJECT_ID,
    url: PRODUCTION_SUPABASE_URL,
    publishableKey: productionConfigured.NEXT_PUBLIC_SUPABASE_PUBLISHABLE_KEY,
    companyCreationEnabled: false,
    companyManagementEnabled: false,
    companyInvitationsEnabled: false,
  });
});

test("production resolver fails closed for missing, HML, mismatched, or privileged config", () => {
  for (const override of [
    { ECONTROLL_SUPABASE_TARGET: undefined },
    { ECONTROLL_SUPABASE_TARGET: "homologation" },
    { ECONTROLL_PROD_ENABLED: "false" },
    { ECONTROLL_PROD_PROJECT_ID: HOMOLOGATION_PROJECT_ID },
    { ECONTROLL_PROD_SUPABASE_URL: HOMOLOGATION_SUPABASE_URL },
    { NEXT_PUBLIC_SUPABASE_URL: HOMOLOGATION_SUPABASE_URL },
    { NEXT_PUBLIC_SUPABASE_PUBLISHABLE_KEY: undefined },
    { NEXT_PUBLIC_SUPABASE_PUBLISHABLE_KEY: "sb_secret_not_allowed" },
    { ECONTROLL_HML_ENABLED: "true" },
    { ECONTROLL_HML_PROJECT_ID: HOMOLOGATION_PROJECT_ID },
  ]) assert.equal(resolveProductionSupabaseEnv({ ...productionConfigured, ...override }), null);
});

test("target routing never falls back between HML and production credentials", async () => {
  assert.equal(resolveSupabaseEnv(productionConfigured)?.projectId, PRODUCTION_PROJECT_ID);
  assert.equal(resolveSupabaseEnv({ ...productionConfigured, ECONTROLL_SUPABASE_TARGET: "homologation" }), null);
  assert.equal(resolveSupabaseEnv(configured)?.projectId, HOMOLOGATION_PROJECT_ID);
  assert.equal(resolveSupabaseEnv({ ...configured, ECONTROLL_SUPABASE_TARGET: "unknown" }), null);
  assert.equal(resolveSupabaseEnv({}), null);
});

test("production recovery URL requires exact explicitly enabled domain", () => {
  assert.equal(getProductionSiteUrl(productionConfigured)?.toString(), "https://e-control-delta.vercel.app/");
  assert.equal(getProductionSiteUrl({ ...productionConfigured, ECONTROLL_PROD_SITE_URL: "http://localhost:3000" }), null);
  assert.equal(getProductionSiteUrl({ ...productionConfigured, ECONTROLL_PROD_ENABLED: "false" }), null);
});

test("management target accepts only resolver-produced exact HML or production identities", () => {
  assert.equal(isAuthorizedSupabaseTarget(resolveHomologationSupabaseEnv(configured)), true);
  assert.equal(isAuthorizedSupabaseTarget(resolveProductionSupabaseEnv(productionConfigured)), true);
  assert.equal(isAuthorizedSupabaseTarget({ target: "production", projectId: HOMOLOGATION_PROJECT_ID, url: HOMOLOGATION_SUPABASE_URL }), false);
});

test("fails closed when target enablement, ID, URL, or publishable key is missing or inconsistent", () => {
  for (const override of [
    { ECONTROLL_SUPABASE_TARGET: "production" },
    { ECONTROLL_HML_ENABLED: "false" },
    { ECONTROLL_PROD_ENABLED: "true" },
    { ECONTROLL_PROD_PROJECT_ID: PRODUCTION_PROJECT_ID },
    { ECONTROLL_HML_PROJECT_ID: undefined },
    { ECONTROLL_HML_PROJECT_ID: "unknown-project" },
    { ECONTROLL_HML_PROJECT_ID: PRODUCTION_PROJECT_ID },
    { ECONTROLL_HML_SUPABASE_URL: undefined },
    { ECONTROLL_HML_SUPABASE_URL: "https://psqetcrjrhbamefpfnje.supabase.co/other" },
    { ECONTROLL_HML_SUPABASE_URL: PRODUCTION_SUPABASE_URL },
    { ECONTROLL_HML_PUBLISHABLE_KEY: undefined },
    { ECONTROLL_HML_PUBLISHABLE_KEY: "service_role" },
    { ECONTROLL_HML_PUBLISHABLE_KEY: "sb_secret_not_allowed" },
    { ECONTROLL_HML_PUBLISHABLE_KEY: "sb_publishable_invalid value" },
  ]) {
    assert.equal(resolveHomologationSupabaseEnv({ ...configured, ...override }), null);
  }
});

test("Preview can use only standard public variables when they identify exact HML and keeps writes disabled", () => {
  const previewConfigured = {
    NEXT_PUBLIC_SUPABASE_URL: HOMOLOGATION_SUPABASE_URL,
    NEXT_PUBLIC_SUPABASE_PUBLISHABLE_KEY: "sb_publishable_preview_test_only",
  };
  assert.deepEqual(resolvePreviewHomologationSupabaseEnv(previewConfigured), {
    target: "homologation",
    projectId: HOMOLOGATION_PROJECT_ID,
    url: HOMOLOGATION_SUPABASE_URL,
    publishableKey: previewConfigured.NEXT_PUBLIC_SUPABASE_PUBLISHABLE_KEY,
    companyCreationEnabled: false,
    companyManagementEnabled: false,
    companyInvitationsEnabled: false,
  });
  assert.equal(resolveSupabaseEnv(previewConfigured)?.projectId, HOMOLOGATION_PROJECT_ID);
  for (const override of [
    { NEXT_PUBLIC_SUPABASE_URL: PRODUCTION_SUPABASE_URL },
    { NEXT_PUBLIC_SUPABASE_URL: "https://unknown.supabase.co" },
    { NEXT_PUBLIC_SUPABASE_PUBLISHABLE_KEY: undefined },
    { NEXT_PUBLIC_SUPABASE_PUBLISHABLE_KEY: "sb_secret_not_allowed" },
    { ECONTROLL_PROD_PROJECT_ID: PRODUCTION_PROJECT_ID },
    { ECONTROLL_HML_ENABLED: "true" },
    { ECONTROLL_SUPABASE_TARGET: "production" },
  ]) assert.equal(resolvePreviewHomologationSupabaseEnv({ ...previewConfigured, ...override }), null);
});

test("company creation requires its separate explicit enable flag", () => {
  assert.equal(resolveHomologationSupabaseEnv(configured)?.companyCreationEnabled, false);
  assert.equal(resolveHomologationSupabaseEnv({
    ...configured,
    ECONTROLL_HML_COMPANY_CREATION_ENABLED: "true",
  })?.companyCreationEnabled, true);
});

test("company and branch management requires its own explicit flag", () => {
  assert.equal(resolveHomologationSupabaseEnv(configured)?.companyManagementEnabled, false);
  assert.equal(resolveHomologationSupabaseEnv({
    ...configured,
    ECONTROLL_HML_COMPANY_MANAGEMENT_ENABLED: "true",
  })?.companyManagementEnabled, true);
});

test("company invitations require a separate explicit environment flag", () => {
  assert.equal(resolveHomologationSupabaseEnv(configured)?.companyInvitationsEnabled, false);
  assert.equal(resolveHomologationSupabaseEnv({
    ...configured,
    ECONTROLL_HML_COMPANY_INVITATIONS_ENABLED: "true",
  })?.companyInvitationsEnabled, true);
  assert.equal(resolveProductionSupabaseEnv(productionConfigured)?.companyInvitationsEnabled, false);
  assert.equal(resolveProductionSupabaseEnv({
    ...productionConfigured,
    ECONTROLL_PROD_COMPANY_INVITATIONS_ENABLED: "true",
  })?.companyInvitationsEnabled, true);
});

test("homologation recovery links use localhost or a Vercel Preview host", () => {
  assert.equal(getHomologationSiteUrl({
    ECONTROLL_HML_SITE_URL: "https://e-control-delta.vercel.app",
    NEXT_PUBLIC_SITE_URL: "https://e-control-delta.vercel.app",
  }).toString(), "http://localhost:3000/");
  assert.equal(getHomologationSiteUrl({ ECONTROLL_HML_SITE_URL: "http://localhost:3000" }).toString(), "http://localhost:3000/");
  assert.equal(getHomologationSiteUrl({ ECONTROLL_HML_SITE_URL: "http://127.0.0.1:3105" }).toString(), "http://127.0.0.1:3105/");
  assert.equal(getHomologationSiteUrl({ ECONTROLL_HML_SITE_URL: "https://e-control-delta.vercel.app" }).toString(), "http://localhost:3000/");
  assert.equal(getHomologationSiteUrl({
    VERCEL_ENV: "preview",
    VERCEL_URL: "e-control-git-admin-master-v2-integration-559627win.vercel.app",
  }).toString(), "https://e-control-git-admin-master-v2-integration-559627win.vercel.app/");
  assert.equal(getHomologationSiteUrl({
    VERCEL_ENV: "preview",
    VERCEL_URL: "untrusted-project.vercel.app",
  }).toString(), "http://localhost:3000/");
});

test("target predicate rejects production and any non-exact URL", () => {
  assert.equal(isHomologationTarget({ projectId: HOMOLOGATION_PROJECT_ID, url: HOMOLOGATION_SUPABASE_URL }), true);
  assert.equal(isHomologationTarget({ projectId: PRODUCTION_PROJECT_ID, url: PRODUCTION_SUPABASE_URL }), false);
  assert.equal(isHomologationTarget({ projectId: HOMOLOGATION_PROJECT_ID, url: `${HOMOLOGATION_SUPABASE_URL}/` }), false);
});

test("dedicated launcher reads its isolated config and clears generic Supabase variables", () => {
  const launcher = readFileSync(resolve(projectRoot, "scripts/dev-homologation.mjs"), "utf8");
  const config = {
    ECONTROLL_SUPABASE_TARGET: "homologation",
    ECONTROLL_HML_ENABLED: "true",
    ECONTROLL_HML_PROJECT_ID: HOMOLOGATION_PROJECT_ID,
    ECONTROLL_HML_SUPABASE_URL: HOMOLOGATION_SUPABASE_URL,
    ECONTROLL_HML_PUBLISHABLE_KEY: "sb_publishable_test_value",
    ECONTROLL_HML_COMPANY_CREATION_ENABLED: "false",
  };
  assert.match(launcher, /\.env\.homologation\.local/);
  assert.match(launcher, /NEXT_PUBLIC_SUPABASE_URL:\s*""/);
  assert.match(launcher, /NEXT_PUBLIC_SUPABASE_PUBLISHABLE_KEY:\s*""/);
  assert.match(launcher, /"--hostname",\s*"127\.0\.0\.1"/);
  assert.match(launcher, /resolveHomologationSupabaseEnv\(config\)/);
  assert.equal(config.ECONTROLL_SUPABASE_TARGET === "homologation", true);
  assert.equal(config.ECONTROLL_HML_ENABLED === "true", true);
  assert.equal(config.ECONTROLL_HML_PROJECT_ID === HOMOLOGATION_PROJECT_ID, true);
  assert.equal(/^sb_publishable_[A-Za-z0-9_-]+$/.test(config.ECONTROLL_HML_PUBLISHABLE_KEY ?? ""), true);
  assert.equal(config.ECONTROLL_HML_COMPANY_CREATION_ENABLED === "false", true);
});

test("isolated Admin Master V2 launcher requires exact HML and keeps all write flags disabled", () => {
  const launcher = readFileSync(resolve(projectRoot, "scripts/dev-admin-master-v2-integration.mjs"), "utf8");
  assert.match(launcher, /ECONTROLL_SUPABASE_TARGET/);
  assert.match(launcher, /resolveHomologationSupabaseEnv\(config\)/);
  assert.match(launcher, /env\.projectId !== "psqetcrjrhbamefpfnje"/);
  assert.match(launcher, /env\.url !== "https:\/\/psqetcrjrhbamefpfnje\.supabase\.co"/);
  assert.match(launcher, /companyCreationEnabled/);
  assert.match(launcher, /companyManagementEnabled/);
  assert.match(launcher, /3105/);
  assert.match(launcher, /ECONTROLL_NEXT_DIST_DIR/);
  assert.match(launcher, /SUPABASE_SERVICE_ROLE_KEY:\s*""/);
  assert.match(launcher, /stdio:\s*"inherit"/);
  assert.match(launcher, /const siteUrl = "http:\/\/127\.0\.0\.1:3105"/);
  assert.match(launcher, /ECONTROLL_HML_SITE_URL:\s*siteUrl/);
});
