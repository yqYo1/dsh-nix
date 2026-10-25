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
import { pathToFileURL } from 'node:url'

const [install, name] = process.argv.slice(2)
if (!install) {
  console.error('read-profile-template: usage: read-profile-template.mjs <dsh-install> [<template-name>]')
  process.exit(2)
}
const moduleUrl = pathToFileURL(`${install}/packages/boot/app-boot/lib/index.js`).href
const mod = await import(moduleUrl)
const templates = mod.PROFILE_TEMPLATES ?? {}
if (!name) {
  process.stdout.write(JSON.stringify(templates))
  process.exit(0)
}
const template = templates[name]
if (template === undefined) {
  console.error(
    `read-profile-template: unknown profile template ${JSON.stringify(name)}; known: ${Object.keys(templates).sort().join(', ')}`,
  )
  process.exit(3)
}
process.stdout.write(JSON.stringify(template.bundles))
