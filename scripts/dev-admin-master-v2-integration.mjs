import { readFile } from "node:fs/promises";
import { spawn } from "node:child_process";
import { createServer } from "node:net";
import { resolve } from "node:path";
import { fileURLToPath } from "node:url";
import { resolveHomologationSupabaseEnv } from "../lib/supabase/homologation-env.ts";

const root = resolve(fileURLToPath(new URL("..", import.meta.url)));
const configPath = resolve(root, ".env.homologation.local");
const port = 3105;
const distDir = ".next-admin-master-v2-integration";
const siteUrl = "http://127.0.0.1:3105";
const allowedKeys = new Set([
  "ECONTROLL_SUPABASE_TARGET", "ECONTROLL_HML_ENABLED", "ECONTROLL_HML_PROJECT_ID",
  "ECONTROLL_HML_SUPABASE_URL", "ECONTROLL_HML_PUBLISHABLE_KEY", "ECONTROLL_HML_SITE_URL",
  "ECONTROLL_HML_COMPANY_CREATION_ENABLED", "ECONTROLL_HML_COMPANY_MANAGEMENT_ENABLED",
]);

function parse(contents) {
  const values = {};
  for (const [index, raw] of contents.split(/\r?\n/).entries()) {
    const line = raw.trim();
    if (!line || line.startsWith("#")) continue;
    const match = /^([A-Z0-9_]+)=(.*)$/.exec(line);
    if (!match || !allowedKeys.has(match[1]) || Object.hasOwn(values, match[1])) {
      throw new Error(`Invalid local HML config at line ${index + 1}`);
    }
    values[match[1]] = match[2].trim();
  }
  return values;
}

function assertPortFree() {
  return new Promise((resolvePromise, reject) => {
    const server = createServer();
    server.once("error", (error) => reject(new Error(error.code === "EADDRINUSE"
      ? "Port 3105 is already in use; no process was started."
      : "Loopback bind was denied; no process was started.")));
    server.listen(port, "127.0.0.1", () => server.close((error) => error ? reject(error) : resolvePromise()));
  });
}

let parsed;
try {
  parsed = parse(await readFile(configPath, "utf8"));
} catch {
  console.error("Dedicated HML config is missing or invalid. No process was started.");
  process.exit(1);
}

const config = { ...parsed, ECONTROLL_HML_SITE_URL: siteUrl };
const env = resolveHomologationSupabaseEnv(config);
if (!env || env.projectId !== "psqetcrjrhbamefpfnje"
  || env.url !== "https://psqetcrjrhbamefpfnje.supabase.co"
  || env.companyCreationEnabled || env.companyManagementEnabled) {
  console.error("HML destination or read-only write-flag preflight failed. No process was started.");
  process.exit(1);
}

try {
  await assertPortFree();
} catch (error) {
  console.error(error.message);
  process.exit(1);
}

const childEnv = {
  ...process.env,
  ...config,
  ECONTROLL_NEXT_DIST_DIR: distDir,
  NEXT_PUBLIC_SUPABASE_URL: "",
  NEXT_PUBLIC_SUPABASE_PUBLISHABLE_KEY: "",
  NEXT_PUBLIC_SUPABASE_ANON_KEY: "",
  NEXT_PUBLIC_SITE_URL: "",
  SUPABASE_URL: "",
  SUPABASE_ANON_KEY: "",
  SUPABASE_SERVICE_ROLE_KEY: "",
  SUPABASE_SECRET_KEY: "",
};
const next = resolve(root, "node_modules/next/dist/bin/next");
console.log(`Starting read-only Admin Master integration on http://127.0.0.1:${port}; HML destination verified and company/branch writes disabled.`);
const child = spawn(process.execPath, [next, "dev", "--hostname", "127.0.0.1", "--port", String(port), "--webpack"], {
  cwd: root,
  env: childEnv,
  stdio: "inherit",
});
for (const signal of ["SIGINT", "SIGTERM"]) process.on(signal, () => child.kill(signal));
child.on("error", () => {
  console.error("Could not start the isolated local integration server.");
  process.exitCode = 1;
});
child.on("exit", (code, signal) => { process.exitCode = signal ? 1 : (code ?? 1); });
