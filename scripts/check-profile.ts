#!/usr/bin/env node
// @ts-nocheck
import { existsSync } from "node:fs";
import { join } from "node:path";
import { pathToFileURL } from "node:url";
import { writeFileSync } from "node:fs";

const NAME = "dsh";
const [install, name, home, ...args] = process.argv.slice(2);
if (!install || !name || !home) {
  console.error(
    "usage: check-profile.mjs <dsh-install> <profile-name> <dsh-home> [args...]",
  );
  process.exit(2);
}
// The full workspace keeps packages under packages/...; the production
// deployment puts the same packages under node_modules/@deepseek-ai/... .
const installAnchor = existsSync(join(install, "apps/cli/package.json"))
  ? join(install, "apps/cli/package.json")
  : join(install, "package.json");
process.env.DSH_HOME = home;
const packageNames = {
  "packages/boot/app-boot": "@deepseek-ai/dsh-app-boot",
  "packages/boot/cmdline": "@deepseek-ai/dsh-cmdline",
  "packages/util/launch-environment": "@deepseek-ai/dsh-launch-environment",
};
const lib = (pkg) => {
  const local = join(install, pkg, "lib/index.js");
  if (existsSync(local)) return pathToFileURL(local).href;
  return pathToFileURL(
    join(install, "node_modules", packageNames[pkg], "lib/index.js"),
  ).href;
};

const {
  boot,
  createRuntimeResolution,
  loadLayeredEnv,
  loadProfile,
  PluginPackages,
  readProfilePatches,
  reportSkippedBundles,
} = await import(lib("packages/boot/app-boot"));
const { provideCmdline } = await import(lib("packages/boot/cmdline"));
const { DSH_LAUNCH_ENVIRONMENT_KEY } = await import(
  lib("packages/util/launch-environment")
);

// Same as prepareProfile() in the primary source: resolve against the
// scratch home, report skipped bundles, then rewrite the empty root config
// the Loader anchors on.  The home is passed explicitly; it equals
// resolveDshHome() because DSH_HOME was set above.
const profile = loadProfile(NAME, name, installAnchor, home);
reportSkippedBundles(NAME, profile);
// Byte-identical to PROFILE_ROOT_CONFIG in apps/cli/src/profile-boot.ts.
writeFileSync(
  join(profile.dir, "cordis.yml"),
  `# dsh profile root — an empty entry list. The tree is composed as patches:
# each bundle in package.json's dsh.profile.bundles, then cordis.patch.yml, then any
# --patch overlays. Edit cordis.patch.yml, not this file.
[]
`,
);

// Same as composeProfile(): the immutable runtime resolution is computed
// before any plugin imports, from exactly { installAnchor, profile }.
const resolution = await createRuntimeResolution({ installAnchor, profile });
// This check carries no --patch overlays; the profileContext otherwise
// mirrors runProfile() field for field.
const profileContext = {
  name,
  dir: profile.dir,
  patchPath: profile.patchPath,
  installAnchor,
  startedBundles: profile.layers.map((layer) => layer.packageName),
  cwd: process.cwd(),
  home,
  overlays: [],
  telemetryDisabledEnv: process.env.DSH_TELEMETRY_DISABLED,
};
const patches = readProfilePatches(NAME, profileContext, profile);
// Same as runCli(): the frozen layered environment snapshot for this run.
const environment = loadLayeredEnv(NAME);

// Launcher-owned readiness, same shape as createAppReady() in the primary
// source, but NEVER committed: this is a boot-only check.  The registrar
// exists so plugins that await readiness can mount; it is cleared (never
// fired) as soon as boot settles, without starting any application task
// itself, then the tree is disposed.  Any rejection before or during boot
// propagates and fails the check — nothing here swallows plugin errors.
const listeners = new Set();
const appReady = {
  onReady(listener) {
    listeners.add(listener);
    return () => {
      listeners.delete(listener);
    };
  },
};
const clearReady = () => {
  listeners.clear();
};
// Bounded exit request: a plugin may call appExit during mount.  A nonzero
// request must fail the check with no CHECK-OK; a zero request still
// permits boot/dispose when the audit settles.
let requestedExitCode = 0;
const recordExit = (code) => {
  // Preserve the first failure: a later successful exit cannot erase it.
  if (requestedExitCode === 0) requestedExitCode = code ?? 0;
};
// Same host setup as runProfile(): profile facts, frozen environment,
// package resolution, then the invocation's command line.
let ctx;
try {
  ctx = await boot(
    NAME,
    join(profile.dir, "cordis.yml"),
    patches,
    async (hostCtx) => {
      hostCtx.provide("profileContext", profileContext);
      hostCtx.provide(DSH_LAUNCH_ENVIRONMENT_KEY, environment);
      await hostCtx.plugin(PluginPackages, { resolution });
      provideCmdline(hostCtx, { args, exit: recordExit, ready: appReady });
    },
  );
} finally {
  // Never commit readiness; drop registrants even when boot rejects.
  clearReady();
}
try {
  await ctx.fiber.dispose();
} finally {
  // Drop readiness registrants created during disposal; never fire them.
  clearReady();
}
if (requestedExitCode !== 0) {
  console.error(
    `dsh: profile check failed: app requested exit ${requestedExitCode}`,
  );
  process.exit(requestedExitCode);
}
console.log("CHECK-OK");
// A one-shot surface (headless) may have scheduled a fire-and-forget run
// that outlives the tree; the check is about boot, so exit deterministically
// once boot settled and the tree disposed.
process.exit(0);
