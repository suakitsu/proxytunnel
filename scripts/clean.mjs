import { lstat, readdir, rm } from "node:fs/promises";
import { isAbsolute, relative, resolve } from "node:path";
import { fileURLToPath } from "node:url";

const projectRoot = resolve(fileURLToPath(new URL("..", import.meta.url)));
const removeRuntime = process.argv.includes("--runtime");

function checkedPath(relativePath) {
  const target = resolve(projectRoot, relativePath);
  const fromRoot = relative(projectRoot, target);
  if (!fromRoot || fromRoot.startsWith("..") || isAbsolute(fromRoot)) {
    throw new Error(`Refusing cleanup outside the project: ${target}`);
  }
  return target;
}

async function removeTarget(relativePath) {
  const target = checkedPath(relativePath);
  try {
    await lstat(target);
  } catch (error) {
    if (error.code === "ENOENT") return;
    throw error;
  }
  await rm(target, { recursive: true, force: true, maxRetries: 3, retryDelay: 150 });
  console.log(`removed ${relativePath}`);
}

const generatedTargets = [
  ".playwright-cli",
  "cloudflare/.wrangler",
  "dist",
  "output",
  "cloudflare/worker/generated",
  "cloudflare/worker-startup.cpuprofile",
];

for (const target of generatedTargets) await removeTarget(target);

if (removeRuntime) {
  for (const directory of ["var/history", "var/logs", "var/secrets"]) {
    const absolute = checkedPath(directory);
    let entries = [];
    try { entries = await readdir(absolute, { withFileTypes: true }); } catch (error) {
      if (error.code !== "ENOENT") throw error;
    }
    for (const entry of entries) {
      await removeTarget(`${directory}/${entry.name}`);
    }
  }
}

// Remove dependencies last so this script can finish without relying on files
// below node_modules. Restore them at any time with `npm ci`.
await removeTarget("cloudflare/node_modules");
