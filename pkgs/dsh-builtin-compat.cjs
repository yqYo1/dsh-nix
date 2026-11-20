"use strict";

const { createRequire } = require("node:module");
const fs = require("node:fs");
const path = require("node:path");

// Exact consumption set of internalModules() (app-boot lib/index.js).
const ALLOW_IDS = [
  "internal/modules/esm/loader",
  "internal/modules/cjs/loader",
  "internal/modules/helpers",
  "internal/modules/esm/utils",
  "internal/modules/esm/resolve",
];

const TRIGGER_CODE = "Unsupported/no-getter";

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
        typeof moduleId === "string" &&
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
  const anchorCandidates = [
    path.join(
      __dirname,
      "..",
      "packages",
      "boot",
      "app-boot",
      "lib",
      "index.js",
    ),
    path.join(
      __dirname,
      "..",
      "node_modules",
      "@deepseek-ai",
      "dsh-app-boot",
      "lib",
      "index.js",
    ),
  ];
  const anchor = anchorCandidates.find((candidate) => fs.existsSync(candidate));
  if (anchor === undefined) {
    throw new Error(
      `packaged app-boot anchor not found: ${anchorCandidates.join(", ")}`,
    );
  }
  // Resolve through the real packaged tree so app-boot's later
  // `createRequire(import.meta.url)(...)` hits the same cached instance.
  const addon = createRequire(anchor)("node-addon-require-builtin");
  if (
    addon === null ||
    (typeof addon !== "object" && typeof addon !== "function")
  ) {
    throw new Error(`unexpected addon export shape: ${typeof addon}`);
  }
  if (typeof addon.requireBuiltin !== "function") {
    throw new Error("addon.requireBuiltin is not a function");
  }
  // CJS consumers may also reach the default interop export
  // (the addon sets `exports.default = { requireBuiltin, ... }`).
  if (
    addon.default === null ||
    addon.default === undefined ||
    (typeof addon.default !== "object" &&
      typeof addon.default !== "function") ||
    typeof addon.default.requireBuiltin !== "function"
  ) {
    throw new Error("addon.default.requireBuiltin is not a function");
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
    throw new Error("addon.requireBuiltin assignment did not stick");
  }
  // Both exports initially reference the same function; keep that identity.
  const wrappedDefault =
    nativeDefault === nativeTop
      ? wrappedTop
      : wrapRequireBuiltin(nativeDefault, cache);
  addon.default.requireBuiltin = wrappedDefault;
  if (addon.default.requireBuiltin !== wrappedDefault) {
    throw new Error("addon.default.requireBuiltin assignment did not stick");
  }
} catch (err) {
  throw new Error(
    `[dsh-builtin-compat] failed to install requireBuiltin fallback: ${
      err !== null && err !== undefined && err.message
        ? err.message
        : String(err)
    }`,
    { cause: err },
  );
}
