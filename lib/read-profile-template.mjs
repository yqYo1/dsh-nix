#!/usr/bin/env node
/**
 * Print one shipped profile template's initial bundle list as JSON.
 *
 * The list is read from the installed dsh (`PROFILE_TEMPLATES`), so dsh-nix
 * never duplicates the template definitions: a template profile is exactly
 * the composition the official installer initializes on first use.
 *
 * Usage:
 *   node --expose-internals --require <dsh>/lib/dsh-builtin-compat.cjs \
 *     read-profile-template.mjs <dsh-install> <template-name>
 */
import { existsSync, readFileSync } from "node:fs";
import { pathToFileURL } from "node:url";

const [install, name] = process.argv.slice(2);
if (!install) {
  console.error(
    "read-profile-template: usage: read-profile-template.mjs <dsh-install|profile-meta> [<template-name>]",
  );
  process.exit(2);
}
const metaFile = `${install}/share/dsh-nix/profile-templates.json`;
let templates;
if (existsSync(metaFile)) {
  templates = JSON.parse(readFileSync(metaFile, "utf8"));
} else {
  const moduleUrl = pathToFileURL(
    `${install}/packages/util/official-bundles/lib/index.js`,
  ).href;
  const mod = await import(moduleUrl);
  templates = mod.PROFILE_TEMPLATES ?? {};
}
if (!name) {
  process.stdout.write(JSON.stringify(templates));
  process.exit(0);
}
const template = templates[name];
if (template === undefined) {
  console.error(
    `read-profile-template: unknown profile template ${JSON.stringify(name)}; known: ${Object.keys(templates).sort().join(", ")}`,
  );
  process.exit(3);
}
process.stdout.write(JSON.stringify(template.bundles));
