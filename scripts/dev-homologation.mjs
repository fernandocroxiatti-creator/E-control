import { readFile } from "node:fs/promises";
import { spawn } from "node:child_process";
import { resolve } from "node:path";
import { fileURLToPath } from "node:url";
import { resolveHomologationSupabaseEnv } from "../lib/supabase/homologation-env.ts";

const projectRoot = resolve(fileURLToPath(new URL("..", import.meta.url)));
const configPath = resolve(projectRoot, ".env.homologation.local");
const allowedKeys = new Set([
  "ECONTROLL_SUPABASE_TARGET",
  "ECONTROLL_HML_ENABLED",
  "ECONTROLL_HML_PROJECT_ID",
  "ECONTROLL_HML_SUPABASE_URL",
  "ECONTROLL_HML_PUBLISHABLE_KEY",
  "ECONTROLL_HML_SITE_URL",
  "ECONTROLL_HML_COMPANY_CREATION_ENABLED",
]);

function parseConfig(contents) {
  const values = {};
  for (const [index, rawLine] of contents.split(/\r?\n/).entries()) {
    const line = rawLine.trim();
    if (!line || line.startsWith("#")) continue;
    const match = /^([A-Z0-9_]+)=(.*)$/.exec(line);
    if (!match || !allowedKeys.has(match[1]) || Object.hasOwn(values, match[1])) {
      throw new Error(`Invalid homologation config at line ${index + 1}.`);
    }
    values[match[1]] = match[2].trim();
  }
  return values;
}

let config;
try {
  config = parseConfig(await readFile(configPath, "utf8"));
} catch {
  console.error("Homologation config is missing or invalid. No app process was started.");
  process.exit(1);
}

const supabaseEnv = resolveHomologationSupabaseEnv(config);
if (!supabaseEnv) {
  console.error("Homologation config is incomplete, disabled, or does not match the authorized project. No app process was started.");
  process.exit(1);
}

const childEnv = {
  ...process.env,
  ...config,
  // Prevent legacy generic variables inherited from shell or .env.local from becoming fallbacks.
  NEXT_PUBLIC_SUPABASE_URL: "",
  NEXT_PUBLIC_SUPABASE_PUBLISHABLE_KEY: "",
  NEXT_PUBLIC_SITE_URL: "",
};
const nextBin = resolve(projectRoot, "node_modules/next/dist/bin/next");
const child = spawn(process.execPath, [nextBin, "dev", "--hostname", "127.0.0.1", "--port", "3000"], {
  cwd: projectRoot,
  env: childEnv,
  stdio: "inherit",
});

for (const signal of ["SIGINT", "SIGTERM"]) {
  process.on(signal, () => child.kill(signal));
}
child.on("error", () => {
  console.error("Could not start the local Next.js development server.");
  process.exitCode = 1;
});
child.on("exit", (code, signal) => {
  process.exitCode = signal ? 1 : (code ?? 1);
});
