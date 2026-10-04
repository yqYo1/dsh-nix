'use strict';

// dsh Nix Node builtin compatibility preload (rc.2, narrowly triggered).
//
// Background: on the Nix Node 22/24 closures shipped here, the bundled
// `node-addon-require-builtin@0.1.6` native backend has no working ABI path,
// so its `requireBuiltin` throws `code === 'Unsupported/no-getter'` for the
// internal loader ids consumed by `internalModules()` in
// `packages/boot/app-boot/lib/index.js` (via `installRuntimeInterception`).
// With `--expose-internals` the real objects are loadable through Node
// itself, so this preload — installed with `node --require` BEFORE the CLI
// entrypoint — wraps the already-loaded addon exports in place and returns
// the exact builtin objects captured here at install time (before app-boot
// installs its resolver interception, so the cached fallback can neither be
// redirected nor re-enter the hook: fallback performs no later require call,
// it returns the cached object references).
//
// Why objects, not a createRequire closure: createRequire delegates to the
// mutable Module loading functions, so a captured closure alone is still
// redirectable — the unproven claim it "cannot be redirected" does not hold.
// Caching the five real export objects before wrapping removes the loader
// from the fallback path entirely.
//
// Trigger contract (narrow):
//   - the native `requireBuiltin` is always tried first with its original
//     receiver and original arguments; native success (or any non-matching
//     throw) passes through untouched with the original result/error.
//   - the cached fallback runs ONLY when ALL hold: the thrown `err.code`
//     is exactly `'Unsupported/no-getter'`, the first argument is a string,
//     and it is one of the exact five internal ids consumed by
//     `internalModules()`.
//   - anything else (other errors, non-allowlisted or non-string ids) never
//     touches the cache; the ORIGINAL error propagates.
//   - no fake objects: the fallback returns the real Node internals objects.
// Any failure to install the wrapper throws at preload time (fail-loud,
// before any wrapper is assigned, so no half-installed runtime).
// This file sets no globals, touches no environment, and performs no audit
// changes: it only wraps `requireBuiltin` on the resolved addon instance.

const { createRequire } = require('node:module');
const fs = require('node:fs');
const path = require('node:path');

// Exact consumption set of internalModules() (app-boot lib/index.js).
const ALLOW_IDS = [
  'internal/modules/esm/loader',
  'internal/modules/cjs/loader',
  'internal/modules/helpers',
  'internal/modules/esm/utils',
  'internal/modules/esm/resolve',
];

const TRIGGER_CODE = 'Unsupported/no-getter';

function wrapRequireBuiltin(nativeRequireBuiltin, cache) {
  function compatRequireBuiltin(...args) {
    try {
      return nativeRequireBuiltin.apply(this, args);
    } catch (err) {
      const moduleId = args[0];
      if (
        err !== null &&
        err !== undefined &&
        err.code === TRIGGER_CODE &&
        typeof moduleId === 'string' &&
        Object.hasOwn(cache, moduleId)
      ) {
        return cache[moduleId];
      }
      throw err;
    }
  }
  return compatRequireBuiltin;
}

try {
  // Derive the packaged app-boot anchor from this file's installed location
  // ($out/lib/dsh-builtin-compat.cjs -> $out/packages/boot/app-boot/...);
  // never hardcode a store path.
  const anchor = path.join(
    __dirname,
    '..',
    'packages',
    'boot',
    'app-boot',
    'lib',
    'index.js',
  );
  if (!fs.existsSync(anchor)) {
    throw new Error(`packaged app-boot anchor not found: ${anchor}`);
  }
  // Resolve through the real packaged tree so app-boot's later
  // `createRequire(import.meta.url)(...)` hits the same cached instance.
  const addon = createRequire(anchor)('node-addon-require-builtin');
  if (
    addon === null ||
    (typeof addon !== 'object' && typeof addon !== 'function')
  ) {
    throw new Error(`unexpected addon export shape: ${typeof addon}`);
  }
  if (typeof addon.requireBuiltin !== 'function') {
    throw new Error('addon.requireBuiltin is not a function');
  }
  // CJS consumers may also reach the default interop export
  // (the addon sets `exports.default = { requireBuiltin, ... }`).
  if (
    addon.default === null ||
    addon.default === undefined ||
    (typeof addon.default !== 'object' &&
      typeof addon.default !== 'function') ||
    typeof addon.default.requireBuiltin !== 'function'
  ) {
    throw new Error('addon.default.requireBuiltin is not a function');
  }
  const nativeTop = addon.requireBuiltin;
  const nativeDefault = addon.default.requireBuiltin;
  // Cache the exact five real builtin objects BEFORE wrapping, via a require
  // derived from the installed anchor. Capture failure throws here, before
  // any wrapper assignment, so install fails loudly with no half-installed
  // runtime. No fake objects: a failed capture propagates, never a stub.
  const captureRequire = createRequire(anchor);
  const cache = Object.create(null);
  for (const id of ALLOW_IDS) {
    cache[id] = captureRequire(id);
  }
  const wrappedTop = wrapRequireBuiltin(nativeTop, cache);
  addon.requireBuiltin = wrappedTop;
  if (addon.requireBuiltin !== wrappedTop) {
    throw new Error('addon.requireBuiltin assignment did not stick');
  }
  // Both exports initially reference the same function; keep that identity.
  const wrappedDefault =
    nativeDefault === nativeTop ? wrappedTop : wrapRequireBuiltin(nativeDefault, cache);
  addon.default.requireBuiltin = wrappedDefault;
  if (addon.default.requireBuiltin !== wrappedDefault) {
    throw new Error('addon.default.requireBuiltin assignment did not stick');
  }
} catch (err) {
  throw new Error(
    `[dsh-builtin-compat] failed to install requireBuiltin fallback: ${
      err !== null && err !== undefined && err.message ? err.message : String(err)
    }`,
    { cause: err },
  );
}
