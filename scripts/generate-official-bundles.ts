#!/usr/bin/env node
// @ts-nocheck
// Regenerate lib/official-bundles.json from a built dsh installation.
// Usage: node --experimental-strip-types scripts/generate-official-bundles.ts <dsh-install>
import { existsSync, writeFileSync } from "node:fs";
import { join, resolve } from "node:path";
import { pathToFileURL } from "node:url";

const install = resolve(process.argv[2] ?? "");
if (!install) {
  console.error("usage: generate-official-bundles.ts <dsh-install>");
  process.exit(2);
}
const candidates = [
  join(install, "packages/util/official-bundles/lib/index.js"),
  join(install, "node_modules/@deepseek-ai/dsh-official-bundles/lib/index.js"),
];
const modulePath = candidates.find((candidate) => existsSync(candidate));
if (!modulePath) {
  console.error(`official-bundles export not found under ${install}`);
  process.exit(2);
}
const mod = await import(pathToFileURL(modulePath).href);
const profileTemplates = Object.fromEntries(
  Object.entries(mod.PROFILE_TEMPLATES).map(([name, value]) => [
    name,
    Array.isArray(value) ? value : value.bundles,
  ]),
);
const catalog = {
  profileTemplates,
  optional: mod.OPTIONAL_BUNDLES,
  onDemand: mod.ON_DEMAND_BUNDLES,
};
if (
  !Array.isArray(catalog.optional) ||
  !Array.isArray(catalog.onDemand) ||
  Object.values(profileTemplates).some((bundles) => !Array.isArray(bundles))
) {
  console.error("official-bundles export has an unexpected shape");
  process.exit(2);
}
writeFileSync(
  join(import.meta.dirname, "..", "lib", "official-bundles.json"),
  JSON.stringify(catalog, null, 2) + "\n",
);
