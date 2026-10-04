#!/usr/bin/env node
/**
 * Build-time profile check: boot a composed profile with dsh's own boot()
 * and dispose immediately.  boot() runs auditStartupEntries internally
 * (packages/boot/app-boot/src/index.ts), so a non-zero exit means the tree
 * failed to settle or a required entry stayed PENDING/FAILED — the exact
 * runtime fail-loud, surfaced at `nix build` time.  Scope is boot+dispose
 * only: the check never commits launcher readiness and never starts an
 * application task itself, but it cannot prove no plugin scheduled one —
 * rc.2 headless starts its run during apply without using appReady
 * (headless/src/index.ts), so an active plugin may have scheduled
 * fire-and-forget work that outlives the tree.  A nonzero appExit requested
 * during boot is recorded and fails the check (no CHECK-OK); it is never
 * waived to keep the check green.
 *
 * The sequence mirrors the primary source `apps/cli/src/profile-boot.ts`
 * at pinned dsh-v0.2.0-rc.2 (prepareProfile → composeProfile → runProfile):
 *   - loadProfile() resolves the profile against the scratch DSH_HOME, then
 *     the profile root cordis.yml is rewritten to the empty entry list
 *     (the Loader anchors baseUrl at it; a Loader write-back must never bake
 *     composed rows into it);
 *   - createRuntimeResolution({ installAnchor, profile }) computes the
 *     immutable runtime resolution before any plugin imports — there is no
 *     heal step in rc.2, and resolution failure must fail loud (no fallback);
 *   - readProfilePatches() stacks bundle layers in dsh.profile.bundles
 *     order, the profile's own user layer, the home-level
 *     `$DSH_HOME/cordis.patch.yml` layer, --patch overlays (none in this
 *     check), and the telemetry switch;
 *   - boot() mounts with profileContext + the frozen launch environment +
 *     PluginPackages(resolution) + cmdline args, exactly as a real
 *     `dsh --profile` run.
 *
 * Usage: check-profile.mjs <dsh-install> <profile-name> <dsh-home> [args...]
 *   <dsh-install>  the packaged dsh store path (its apps/cli/package.json
 *                  is the install anchor)
 *   <profile-name> the profile directory name under <dsh-home>/profiles
 *   <dsh-home>     a scratch DSH_HOME holding the profile under test
 *   args...        extra command-line args provided via cmdlineArgs
 *                  (web: --port 0 to avoid binding 3080; headless: the task)
 */
import { join } from 'node:path'
import { pathToFileURL } from 'node:url'
import { writeFileSync } from 'node:fs'

const NAME = 'dsh'
const [install, name, home, ...args] = process.argv.slice(2)
if (!install || !name || !home) {
  console.error('usage: check-profile.mjs <dsh-install> <profile-name> <dsh-home> [args...]')
  process.exit(2)
}
const installAnchor = join(install, 'apps/cli/package.json')
process.env.DSH_HOME = home
const lib = (pkg) => pathToFileURL(join(install, pkg, 'lib/index.js')).href

const {
  boot,
  createRuntimeResolution,
  loadLayeredEnv,
  loadProfile,
  PluginPackages,
  readProfilePatches,
  reportSkippedBundles,
} = await import(lib('packages/boot/app-boot'))
const { provideCmdline } = await import(lib('packages/boot/cmdline'))
const { DSH_LAUNCH_ENVIRONMENT_KEY } =
  await import(lib('packages/util/launch-environment'))

// Same as prepareProfile() in the primary source: resolve against the
// scratch home, report skipped bundles, then rewrite the empty root config
// the Loader anchors on.  The home is passed explicitly; it equals
// resolveDshHome() because DSH_HOME was set above.
const profile = loadProfile(NAME, name, installAnchor, home)
reportSkippedBundles(NAME, profile)
// Byte-identical to PROFILE_ROOT_CONFIG in apps/cli/src/profile-boot.ts.
writeFileSync(join(profile.dir, 'cordis.yml'), `# dsh profile root — an empty entry list. The tree is composed as patches:
# each bundle in package.json's dsh.profile.bundles, then cordis.patch.yml, then any
# --patch overlays. Edit cordis.patch.yml, not this file.
[]
`)

// Same as composeProfile(): the immutable runtime resolution is computed
// before any plugin imports, from exactly { installAnchor, profile }.
const resolution = await createRuntimeResolution({ installAnchor, profile })
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
}
const patches = readProfilePatches(NAME, profileContext, profile)
// Same as runCli(): the frozen layered environment snapshot for this run.
const environment = loadLayeredEnv(NAME)

// Launcher-owned readiness, same shape as createAppReady() in the primary
// source, but NEVER committed: this is a boot-only check.  The registrar
// exists so plugins that await readiness can mount; it is cleared (never
// fired) as soon as boot settles, without starting any application task
// itself, then the tree is disposed.  Any rejection before or during boot
// propagates and fails the check — nothing here swallows plugin errors.
const listeners = new Set()
const appReady = {
  onReady(listener) {
    listeners.add(listener)
    return () => { listeners.delete(listener) }
  },
}
const clearReady = () => { listeners.clear() }
// Bounded exit request: a plugin may call appExit during mount.  A nonzero
// request must fail the check with no CHECK-OK; a zero request still
// permits boot/dispose when the audit settles.
let requestedExitCode = 0
const recordExit = (code) => {
  // Preserve the first failure: a later successful exit cannot erase it.
  if (requestedExitCode === 0) requestedExitCode = code ?? 0
}
// Same host setup as runProfile(): profile facts, frozen environment,
// package resolution, then the invocation's command line.
let ctx
try {
  ctx = await boot(NAME, join(profile.dir, 'cordis.yml'), patches, async (hostCtx) => {
    hostCtx.provide('profileContext', profileContext)
    hostCtx.provide(DSH_LAUNCH_ENVIRONMENT_KEY, environment)
    await hostCtx.plugin(PluginPackages, { resolution })
    provideCmdline(hostCtx, { args, exit: recordExit, ready: appReady })
  })
} finally {
  // Never commit readiness; drop registrants even when boot rejects.
  clearReady()
}
try {
  await ctx.fiber.dispose()
} finally {
  // Drop readiness registrants created during disposal; never fire them.
  clearReady()
}
if (requestedExitCode !== 0) {
  console.error(`dsh: profile check failed: app requested exit ${requestedExitCode}`)
  process.exit(requestedExitCode)
}
console.log('CHECK-OK')
// A one-shot surface (headless) may have scheduled a fire-and-forget run
// that outlives the tree; the check is about boot, so exit deterministically
// once boot settled and the tree disposed.
process.exit(0)
