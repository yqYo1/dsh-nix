#!/usr/bin/env node
/**
 * tests/boot-checker-wiring.mjs — MOCK-WIRING regression tests for
 * scripts/check-profile.mjs.  These do NOT prove a real rc.2 boot: the
 * dsh-install tree here is a mock whose lib modules record the checker's
 * calls instead of mounting plugins.  What they pin is the checker's
 * rc.2 contract wiring against apps/cli/src/profile-boot.ts:
 * prepare → resolve → compose → boot+dispose, with fail-loud propagation.
 *
 * Scope note: the checker is boot+dispose only — it never commits launcher
 * readiness and never starts an application task itself.  Withholding
 * readiness alone does NOT prove no plugin scheduled work: rc.2 headless
 * starts its run during apply without using appReady, so a hard
 * no-network guard for real-headless external actions is a separate,
 * still-open fixture decision (parent owns it).  These mocks only prove
 * the registrar never fires and a nonzero appExit request fails the check.
 *
 * Run: nix develop -c -- node tests/boot-checker-wiring.mjs
 * (also suitable as a `nix flake check` derivation running the same command
 * with nodejs in nativeBuildInputs; needs no network and no real package.)
 */
import { spawnSync } from 'node:child_process'
import { mkdtempSync, mkdirSync, readFileSync, rmSync, writeFileSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { dirname, join } from 'node:path'
import { fileURLToPath } from 'node:url'

const HERE = dirname(fileURLToPath(import.meta.url))
const CHECKER = join(HERE, '..', 'scripts', 'check-profile.mjs')
// Scratch lives under TMPDIR (the Hermes scratch dir), never a hardcoded
// home path, so the checked-in test works on any machine.
const SCRATCH = join(process.env.TMPDIR ?? tmpdir(), 'boot-wiring')
mkdirSync(SCRATCH, { recursive: true })

/** Every fixture dir created, removed at the end of the run. */
const created = []
const track = (p) => { created.push(p); return p }
function cleanup() {
  for (const p of created.splice(0)) {
    try { rmSync(p, { recursive: true, force: true }) } catch { /* best-effort */ }
  }
}

/** Bounded child spawn: the checker must settle quickly against mocks. */
const SPAWN_TIMEOUT_MS = 30_000

let passed = 0
function ok(cond, label, extra) {
  if (!cond) {
    console.error(`FAIL: ${label}${extra === undefined ? '' : `\n${extra}`}`)
    process.exitCode = 1
    return
  }
  passed += 1
  console.log(`ok: ${label}`)
}

// --- mock dsh-install tree -------------------------------------------------
// Recording doubles: every export the checker imports is present with the
// rc.2 name/signature; calls append JSON lines to $MOCK_LOG.  MOCK_MODE
// selects the failure to inject: ok | boot-fails | noprofile |
// resolution-fails | dispose-fails | prepare-fails | exit-nonzero |
// exit-zero | exit-failure-then-success | exit-success-then-failure.
// The cmdline mock always arms a readiness listener (proving
// the checker never fires it) and honors the exit-* modes by calling the
// checker's exit function during host setup, as a plugin would.  The two
// ordering modes are mock evidence only: they call host.exit twice in the
// named order to pin first-nonzero-wins recordExit.
const APP_BOOT_MOCK = `
import { appendFileSync, existsSync, readFileSync } from 'node:fs'
import { join } from 'node:path'
const log = (rec) => appendFileSync(process.env.MOCK_LOG, JSON.stringify(rec) + '\\n')
const mode = process.env.MOCK_MODE ?? 'ok'
const markers = (file) => {
  try { return [readFileSync(file, 'utf8').trim()].filter(s => s !== '') }
  catch { return [] }
}
export class PluginPackages { static __mock = true }
export function loadProfile(bin, name, anchor, home, options) {
  log({ call: 'loadProfile', bin, name, anchor, home, optionsKeys: Object.keys(options ?? {}) })
  if (mode === 'noprofile') throw new Error(bin + ': profile ' + JSON.stringify(name) + ' does not exist')
  const manifest = JSON.parse(readFileSync(join(home, 'profiles', name, 'package.json'), 'utf8'))
  const dir = join(home, 'profiles', name)
  return {
    name, dir,
    patchPath: join(dir, 'cordis.patch.yml'),
    layers: (manifest?.dsh?.profile?.bundles ?? []).map((packageName) => ({ packageName, patches: [{ layer: packageName }] })),
    patches: markers(join(dir, 'cordis.patch.yml')),
    skippedBundles: [],
  }
}
export function reportSkippedBundles(bin, profile) {
  log({ call: 'reportSkippedBundles', bin, skipped: profile.skippedBundles })
}
export async function createRuntimeResolution(options) {
  log({ call: 'createRuntimeResolution', keys: Object.keys(options), profileName: options.profile?.name })
  if (mode === 'resolution-fails') throw new Error('dsh: runtime resolution failed: unreadable bundle manifest')
  return { MOCK: 'resolution' }
}
export function readProfilePatches(bin, context, initialProfile) {
  log({ call: 'readProfilePatches', bin, context: { ...context, overlays: context.overlays }, initialIsProfile: initialProfile?.name })
  return [
    ...initialProfile.layers.flatMap((l) => l.patches),
    ...markers(initialProfile.patchPath),
    ...markers(join(context.home, 'cordis.patch.yml')),
    ...context.overlays,
    ...((context.telemetryDisabledEnv ?? '') !== '' ? [{ telemetry: 'disabled' }] : []),
  ]
}
export function loadLayeredEnv(bin) {
  log({ call: 'loadLayeredEnv', bin })
  return { MOCK: 'env' }
}
export async function boot(bin, rootConfig, patches, prepare) {
  log({ call: 'boot', bin, rootConfig, patches, rootContentAtBoot: readFileSync(rootConfig, 'utf8') })
  if (mode === 'boot-fails') throw new Error(bin + ': startup failed: 1 required plugin did not activate')
  const provides = []
  const plugins = []
  const hostCtx = {
    provide: (k, v) => { provides.push(typeof k === 'string' ? k : '?') },
    plugin: async (svc, cfg) => {
      if (mode === 'prepare-fails') throw new Error(bin + ': host preparation failed: PluginPackages mount rejected')
      plugins.push({ service: svc?.__mock === true ? 'PluginPackages' : '?', hasResolution: cfg?.resolution?.MOCK === 'resolution' })
    },
  }
  await prepare(hostCtx)
  log({ call: 'prepare-host', provides, plugins })
  return { fiber: { dispose: async () => {
    log({ call: 'dispose' })
    if (mode === 'dispose-fails') throw new Error(bin + ': disposal failed: teardown rejected')
  } }, get: () => undefined }
}
`
const CMDLINE_MOCK = `
import { appendFileSync } from 'node:fs'
export function provideCmdline(ctx, host) {
  let readyRegistered = false
  if (host.ready !== undefined) {
    ctx.provide('appReady', host.ready)
    host.ready.onReady(() => appendFileSync(process.env.MOCK_LOG, JSON.stringify({ call: 'ready-fired' }) + '\\n'))
    readyRegistered = true
  }
  appendFileSync(process.env.MOCK_LOG, JSON.stringify({ call: 'provideCmdline', args: host.args, hasExit: typeof host.exit === 'function', hasReady: host.ready !== undefined, readyRegistered }) + '\\n')
  ctx.provide('cmdlineArgs', { get: () => Object.freeze([...host.args]) })
  ctx.provide('appExit', host.exit)
  if (process.env.MOCK_MODE === 'exit-nonzero') host.exit(3)
  if (process.env.MOCK_MODE === 'exit-zero') host.exit(0)
  if (process.env.MOCK_MODE === 'exit-failure-then-success') { host.exit(3); host.exit(0) }
  if (process.env.MOCK_MODE === 'exit-success-then-failure') { host.exit(0); host.exit(3) }
}
`
const LAUNCH_ENV_MOCK = `
export const DSH_LAUNCH_ENVIRONMENT_KEY = 'launchEnvironment'
`

function writeMockInstall() {
  const root = track(mkdtempSync(join(SCRATCH, 'mock-install-')))
  const files = {
    'apps/cli/package.json': '{"name":"mock-dsh-cli"}',
    'packages/boot/app-boot/lib/index.js': APP_BOOT_MOCK,
    'packages/boot/cmdline/lib/index.js': CMDLINE_MOCK,
    'packages/util/launch-environment/lib/index.js': LAUNCH_ENV_MOCK,
  }
  for (const [rel, content] of Object.entries(files)) {
    const abs = join(root, rel)
    mkdirSync(dirname(abs), { recursive: true })
    writeFileSync(abs, content)
  }
  return root
}

function writeHome(tag, { bundles = ['@deepseek-ai/dsh-base'], profileMarker = 'PROFILE-USER', homeMarker = 'HOME-LAYER', staleRoot = 'STALE-COMPOSED-ROWS', profileName = 'web' } = {}) {
  const home = track(mkdtempSync(join(SCRATCH, `home-${tag}-`)))
  const dir = join(home, 'profiles', profileName)
  mkdirSync(dir, { recursive: true })
  writeFileSync(join(dir, 'package.json'), JSON.stringify({ dsh: { profile: { bundles } } }))
  writeFileSync(join(dir, 'cordis.yml'), `${staleRoot}\n`)
  writeFileSync(join(dir, 'cordis.patch.yml'), `${profileMarker}\n`)
  writeFileSync(join(home, 'cordis.patch.yml'), `${homeMarker}\n`)
  return home
}

function runChecker(install, profile, home, args = [], env = {}) {
  const runDir = track(mkdtempSync(join(SCRATCH, 'run-')))
  const logFile = join(runDir, 'calls.jsonl')
  writeFileSync(logFile, '')
  const child = spawnSync(process.execPath, [CHECKER, install, profile, home, ...args], {
    encoding: 'utf8',
    timeout: SPAWN_TIMEOUT_MS,
    env: { ...process.env, MOCK_LOG: logFile, MOCK_MODE: 'ok', ...env },
  })
  let calls = []
  try {
    calls = readFileSync(logFile, 'utf8').split('\n').filter(Boolean).map((l) => JSON.parse(l))
  } catch { /* child may have failed before logging; assertions on status cover it */ }
  return { ...child, calls }
}

const ROOT_TEXT = `# dsh profile root — an empty entry list. The tree is composed as patches:
# each bundle in package.json's dsh.profile.bundles, then cordis.patch.yml, then any
# --patch overlays. Edit cordis.patch.yml, not this file.
[]
`

// --- cases -----------------------------------------------------------------
const install = writeMockInstall()

{
  // 1. happy path: ordered patches, full host setup, disposal, CHECK-OK, exit 0
  const home = writeHome('happy')
  const r = runChecker(install, 'web', home, ['--port', '0'])
  ok(r.status === 0, 'happy exits 0', r.stderr)
  ok(r.stdout.includes('CHECK-OK'), 'happy prints CHECK-OK, not just exit 0')
  const order = r.calls.map((c) => c.call)
  ok(JSON.stringify(order) === JSON.stringify(['loadProfile', 'reportSkippedBundles', 'createRuntimeResolution', 'readProfilePatches', 'loadLayeredEnv', 'boot', 'provideCmdline', 'prepare-host', 'dispose']),
    `happy call order mirrors profile-boot.ts (got ${order.join(' → ')})`)
  const boot = r.calls.find((c) => c.call === 'boot')
  ok(JSON.stringify(boot.patches) === JSON.stringify([{ layer: '@deepseek-ai/dsh-base' }, 'PROFILE-USER', 'HOME-LAYER']),
    `happy patch order is bundle → profile user → home layer (got ${JSON.stringify(boot.patches)})`)
  ok(boot.rootContentAtBoot === ROOT_TEXT, 'stale root cordis.yml reset to empty entry list before boot')
  const prep = r.calls.find((c) => c.call === 'prepare-host')
  ok(prep.provides.includes('profileContext') && prep.provides.includes('launchEnvironment') && prep.provides.includes('cmdlineArgs'),
    `host provides profileContext + launch env + cmdline (got ${prep.provides.join(', ')})`)
  ok(prep.plugins.length === 1 && prep.plugins[0].service === 'PluginPackages' && prep.plugins[0].hasResolution,
    'host mounts PluginPackages with the computed resolution')
  const cmdline = r.calls.find((c) => c.call === 'provideCmdline')
  ok(JSON.stringify(cmdline.args) === JSON.stringify(['--port', '0']) && cmdline.hasExit && cmdline.hasReady,
    'cmdline args/exit/ready forwarded')
  const rpc = r.calls.find((c) => c.call === 'readProfilePatches')
  ok(rpc.context.home === home && rpc.context.overlays.length === 0 && rpc.initialIsProfile === 'web',
    'composition context carries scratch home, empty overlays, loaded profile')
}

{
  // 2. home override: a second home resolves its own profile, not the first's
  const homeA = writeHome('override-a', { profileMarker: 'MARKER-A' })
  const homeB = writeHome('override-b', { profileMarker: 'MARKER-B' })
  const r = runChecker(install, 'web', homeB)
  ok(r.status === 0, 'home-override exits 0', r.stderr)
  const lp = r.calls.find((c) => c.call === 'loadProfile')
  ok(lp.home === homeB && lp.name === 'web', 'loadProfile resolves against the given home')
  const boot = r.calls.find((c) => c.call === 'boot')
  ok(boot.patches.includes('MARKER-B') && !boot.patches.includes('MARKER-A'),
    'patches come from the given home only')
  void homeA
}

{
  // 3. telemetry switch flows into the composition context
  const home = writeHome('telemetry')
  const r = runChecker(install, 'web', home, [], { DSH_TELEMETRY_DISABLED: '1' })
  ok(r.status === 0, 'telemetry exits 0', r.stderr)
  const boot = r.calls.find((c) => c.call === 'boot')
  ok(boot.patches.some((p) => p?.telemetry === 'disabled'), 'telemetry opt-out reaches patch composition')
}

{
  // 4. propagated errors: boot failure fails loud with the diagnostic
  const home = writeHome('bootfail')
  const r = runChecker(install, 'web', home, [], { MOCK_MODE: 'boot-fails' })
  ok(r.status !== 0, 'boot failure exits non-zero')
  ok(!r.stdout.includes('CHECK-OK'), 'boot failure prints no CHECK-OK')
  ok(/did not activate/.test(r.stderr), 'boot diagnostic surfaces on stderr (fail-loud, not swallowed)')
  ok(!r.calls.some((c) => c.call === 'dispose'), 'failed boot performs no success-path disposal')
}

{
  // 5. missing profile fails loud
  const home = writeHome('noprofile')
  const r = runChecker(install, 'nope', home, [], { MOCK_MODE: 'noprofile' })
  ok(r.status !== 0, 'missing profile exits non-zero')
  ok(!r.stdout.includes('CHECK-OK'), 'missing profile prints no CHECK-OK')
}

{
  // 6. resolution failure fails loud with no fallback
  const home = writeHome('resfail')
  const r = runChecker(install, 'web', home, [], { MOCK_MODE: 'resolution-fails' })
  ok(r.status !== 0, 'resolution failure exits non-zero')
  ok(!r.stdout.includes('CHECK-OK'), 'resolution failure prints no CHECK-OK')
  ok(!r.calls.some((c) => c.call === 'boot'), 'resolution failure never reaches boot (no silent fallback)')
}

{
  // 7. source pin: rc.2 contract only — no removed-API fallback
  const src = readFileSync(CHECKER, 'utf8')
  ok(!src.includes('healProfilesModuleFallback'), 'checker has no healProfilesModuleFallback fallback path')
  ok(!src.includes('ERR_INVALID_ARG_TYPE'), 'checker has no version-sniffing error-code fallback')
  ok(!src.includes('.commit('), 'checker never commits readiness (boot-only registrar, cleared on dispose)')
  for (const api of ['createRuntimeResolution', 'readProfilePatches', 'PluginPackages', 'profileContext', 'reportSkippedBundles', 'loadLayeredEnv']) {
    ok(src.includes(api), `checker uses rc.2 API ${api}`)
  }
}

{
  // 8. readiness is registered but never fired: the checker is boot-only and
  // never starts an application task itself.  (Caveat, kept explicit: this
  // alone does not prove a real headless plugin scheduled nothing — rc.2
  // headless starts its run during apply without appReady.  A hard
  // no-network guard for real-headless external actions stays open.)
  const home = writeHome('ready')
  const r = runChecker(install, 'web', home)
  ok(r.status === 0, 'readiness probe exits 0', r.stderr)
  ok(r.stdout.includes('CHECK-OK'), 'readiness probe still prints CHECK-OK')
  const cmdline = r.calls.find((c) => c.call === 'provideCmdline')
  ok(cmdline?.readyRegistered === true, 'mock readiness listener was armed (probe is live)')
  ok(!r.calls.some((c) => c.call === 'ready-fired'), 'armed readiness listener never fires (no commit, cleared on dispose)')
}

{
  // 9. nonzero appExit requested during boot fails the check — never waived
  const home = writeHome('exit-nonzero')
  const r = runChecker(install, 'web', home, [], { MOCK_MODE: 'exit-nonzero' })
  ok(r.status !== 0, 'nonzero app exit exits non-zero')
  ok(!r.stdout.includes('CHECK-OK'), 'nonzero app exit prints no CHECK-OK')
  ok(/requested exit 3/.test(r.stderr), 'nonzero app exit diagnostic surfaces on stderr')
  ok(r.calls.some((c) => c.call === 'dispose'), 'tree is still disposed before reporting the requested exit')
}

{
  // 10. zero appExit still permits boot/dispose when the audit settles
  const home = writeHome('exit-zero')
  const r = runChecker(install, 'web', home, [], { MOCK_MODE: 'exit-zero' })
  ok(r.status === 0, 'zero app exit exits 0', r.stderr)
  ok(r.stdout.includes('CHECK-OK'), 'zero app exit still prints CHECK-OK')
}

{
  // 11. disposal rejection fails the check — no silent CHECK-OK
  const home = writeHome('dispose-fails')
  const r = runChecker(install, 'web', home, [], { MOCK_MODE: 'dispose-fails' })
  ok(r.status !== 0, 'disposal rejection exits non-zero')
  ok(!r.stdout.includes('CHECK-OK'), 'disposal rejection prints no CHECK-OK')
  ok(/disposal failed|teardown rejected/.test(r.stderr), 'disposal diagnostic surfaces on stderr')
}

{
  // 12. host preparation failure (PluginPackages mount) fails loud
  const home = writeHome('prepare-fails')
  const r = runChecker(install, 'web', home, [], { MOCK_MODE: 'prepare-fails' })
  ok(r.status !== 0, 'host preparation failure exits non-zero')
  ok(!r.stdout.includes('CHECK-OK'), 'host preparation failure prints no CHECK-OK')
  ok(/host preparation|mount rejected/.test(r.stderr), 'host preparation diagnostic surfaces on stderr')
  ok(!r.calls.some((c) => c.call === 'dispose'), 'failed host preparation performs no success-path disposal')
}

{
  // 13. failure-then-success ordering: a later exit(0) cannot erase the
  // first nonzero request (mock evidence for first-nonzero-wins recordExit)
  const home = writeHome('exit-failure-then-success')
  const r = runChecker(install, 'web', home, [], { MOCK_MODE: 'exit-failure-then-success' })
  ok(r.status === 3, 'failure-then-success exits 3 (mock evidence: first nonzero wins)')
  ok(!r.stdout.includes('CHECK-OK'), 'failure-then-success prints no CHECK-OK')
  ok(/requested exit 3/.test(r.stderr), 'failure-then-success diagnostic surfaces requested exit 3')
  ok(r.calls.some((c) => c.call === 'dispose'), 'failure-then-success still disposes before reporting')
}

{
  // 14. success-then-failure ordering: an earlier exit(0) cannot mask a
  // later nonzero request (mock evidence for first-nonzero-wins recordExit)
  const home = writeHome('exit-success-then-failure')
  const r = runChecker(install, 'web', home, [], { MOCK_MODE: 'exit-success-then-failure' })
  ok(r.status === 3, 'success-then-failure exits 3 (mock evidence: later nonzero still fails)')
  ok(!r.stdout.includes('CHECK-OK'), 'success-then-failure prints no CHECK-OK')
  ok(/requested exit 3/.test(r.stderr), 'success-then-failure diagnostic surfaces requested exit 3')
  ok(r.calls.some((c) => c.call === 'dispose'), 'success-then-failure still disposes before reporting')
}

cleanup()
if (process.exitCode) console.error('\nboot-checker-wiring: FAILURES present (mock-wiring only; not a real-boot verdict)')
else console.log(`\nboot-checker-wiring: ${passed} assertions passed (mock-wiring only; not a real-package boot verdict)`)
