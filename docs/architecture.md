# Architecture

## Package layout

`pkgs/dsh.nix` separates two concerns:

- `dsh-build` is the build-time derivation. It installs the pnpm development
  closure, builds the workspace with TypeScript and node-gyp, and keeps the
  full built tree for tests and profile composition.
- `dsh-runtime-src` copies only the built apps, packages and metadata needed
  by the user package. `dsh` then installs the recursive production
  dependency closure and drops test-runner views.

The runtime wrapper uses Node with `--expose-internals` for the HMR service
and prefixes a private pnpm 11 for `dsh plugin` child processes. The pnpm-deps
fixed-output derivation is always fetched through the pinned `nixpkgs-fetch`
input so consumer nixpkgs overrides cannot change its build script or hash.

## Profiles and bundles

A **bundle** is a package directory with `package.json` and the patch file
declared by `dsh.bundle.patch`; dsh-nix imports it rather than transcribing its
rows. A **profile** is an immutable package.json manifest plus a node_modules
view consumed by `dsh --profile`. Cordis remains dsh's runtime.

## Home Manager module

The module owns composition under `~/.dsh`: profiles and the home-level
`cordis.patch.yml`. dsh owns mutable application data such as
`.credentials.yaml`, sessions and settings after the initial seed.

`plugins` and `extraPlugins` accept official bundle names, Nix packages or
paths, and local plugin paths in one ordered list. Non-official plugins must
be supplied as Nix packages or paths. A profile with `extends` starts from a
shipped template and appends entries; a profile with `plugins` is fully
custom. `templates` installs the shipped template profiles themselves.

## Node builtin compatibility

On the Nix Node 22/24 closures, the bundled `node-addon-require-builtin`
backend cannot load the internal loader ids used by app-boot. The preload
captures the five real builtin objects through Node's own internals and wraps
the addon's `requireBuiltin` in place. It only falls back when the code is
exactly `Unsupported/no-getter` and the id is one of those five ids; all other
results and errors pass through unchanged. The preload fails loudly before
installing a partial wrapper.
