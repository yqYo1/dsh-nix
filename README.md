# dsh-nix

Build [DeepSeek Harness](https://github.com/deepseek-ai/deepseek-harness) (`dsh`) with Nix and manage profiles and Home Manager configuration declaratively.
The DSH source is pinned as a flake input; the current package is `0.2.1-rc.2`.

- **`pkgs.dsh`**: the CLI package, built from the pnpm monorepo.
- **profile builder**: composes profiles from bundles, Nix packages, and plugin paths at build time.
- **official plugins (bundles)**: every official bundle — the installable plugin unit in dsh — is usable by profile name: in-box bundles resolve from the installation and the two on-demand subagent bundles are linked from the installed dsh tree (built from the pinned source). Official plugin packages that ship without a bundle of their own mount through profile patch rows. For official packages, users package nothing.
- **built-in profile templates**: the five shipped templates are installed by default as profiles, can be extended in place, replaced by a same-named user profile, or disabled individually.
- **`programs.dsh`**: the Home Manager module managing profile composition under `~/.dsh`. Its scope is separated from user data such as sessions, settings, and credentials.

## Contents

- [Plugins](#plugins)
- [Usage](#usage)
- [Regression verification](#regression-verification)
- [Notes](#notes)

## Plugins

DSH has two units. A **cordis plugin** is a runtime component; every part of the product is one, and patch rows mount plugins. A **bundle** is the installable plugin unit: a package that declares `dsh.bundle`, whose patch file is an ordered layer of rows. `dsh plugin` and the plugin market only act on bundles, and a package without `dsh.bundle` installs as a plain dependency (no layer).

The `plugins` list follows that model: an entry that declares `dsh.bundle` contributes a layer, and a package without it is a dependency that rows can name. Entries are set in `programs.dsh.templates.<name>.extraPlugins` or `programs.dsh.profiles.<name>.plugins`/`extraPlugins` (see [Profiles and templates](#profiles-and-templates)); a plugin that is not an official bundle must be a Nix package or plugin path, and bare package names or pnpm spec strings are rejected.

The following forms are accepted, mixed in declaration order:

- **official bundle**: a name such as `"@deepseek-ai/dsh-base"` — nothing to package (see [Official bundles](#official-bundles)).
- **Nix package**: an out-of-tree derivation such as `pkgs.buildNpmPackage { ... }`; linked into the profile with its built dependency closure intact.
- **Nix path**: a prebuilt plugin directory with `package.json` at its root, such as `./my-plugin`; required runtime dependencies must be contained in that directory.

### Official bundles

The official installable plugin set is the official bundle set (upstream `PROFILE_TEMPLATES` + `OPTIONAL_BUNDLES` + `ON_DEMAND_BUNDLES`). Every official bundle is accepted by name; users never package or hash them. The 18 installation bundles are in-box names: they resolve from the dsh installation and never enter the profile's dependencies.

- **bundles of the shipped profile templates** (upstream `PROFILE_TEMPLATES`, resolved from the installation):
  - `@deepseek-ai/dsh-base`
  - `@deepseek-ai/dsh-web-app`
  - `@deepseek-ai/dsh-headless`
  - `@deepseek-ai/dsh-sdk-app`
  - `@deepseek-ai/dsh-sdk-minimal`
  - `@deepseek-ai/dsh-acp-app`
- **optional bundles** (upstream `OPTIONAL_BUNDLES`, shipped switched off):
  - `@deepseek-ai/dsh-experimental-session-search`
  - `@deepseek-ai/dsh-experimental-ralph-bundle`
  - `@deepseek-ai/dsh-experimental-terminal-bundle`
  - `@deepseek-ai/dsh-experimental-badge-skill-bundle`
  - `@deepseek-ai/dsh-experimental-session-titles-bundle`
  - `@deepseek-ai/dsh-experimental-agent-team-profile`
  - `@deepseek-ai/dsh-experimental-voice-input-bundle`
  - `@deepseek-ai/dsh-experimental-cot-translation-bundle`
  - `@deepseek-ai/dsh-experimental-auto-review`
  - `@deepseek-ai/dsh-experimental-inspector-profile`
  - `@deepseek-ai/dsh-experimental-plugin-market-bundle`
  - `@deepseek-ai/dsh-experimental-tool-worktree`
- **on-demand official bundles** (not installation dependencies; the pinned dsh source builds them and dsh-nix links the installed package, provider binaries included — no npm fetch, version pin, lockfile, or store hash is maintained):
  - `@deepseek-ai/dsh-subagent-codex`
  - `@deepseek-ai/dsh-subagent-claude-code`

Optional bundles are installation dependencies, so an in-box name resolves without any profile link.
On-demand bundles are catalog-only (not installation dependencies), so the built package is linked into the profile when named; without that link dsh would skip the bundle.

```nix
programs.dsh.profiles.research = {
  plugins = [
    "@deepseek-ai/dsh-base"
    "@deepseek-ai/dsh-web-app"
    "@deepseek-ai/dsh-experimental-session-search" # shipped optional bundle
    "@deepseek-ai/dsh-subagent-codex"              # on-demand, linked from the dsh source
  ];
};
```

The accepted name list and the on-demand list are drift-checked against the pinned DSH source, so a dsh bump that ships new bundles or changes the on-demand set fails `nix flake check`.

### Out-of-tree plugins (Nix packages and paths)

dsh-nix does not accept pnpm/Git spec strings or compute dependency hashes for you: a plugin that is not an official bundle must be built as a Nix derivation (or provided as a plugin path) and passed in `plugins` or `extraPlugins`.
A `pkgs.buildNpmPackage` derivation is passed directly there; its source, `package-lock.json`, `npmDepsHash`, and build settings are owned by that declaration. The same entry can extend a shipped template (`templates.<name>.extraPlugins`) or be part of a fully custom profile (`profiles.<name>.plugins`).

The example below is a Home Manager configuration. `./my-plugin` is an npm project containing `package.json`, `package-lock.json`, the patch referenced by `dsh.bundle.patch`, and the runtime source.

```nix
{ inputs, pkgs, ... }:
let
  myPlugin = pkgs.buildNpmPackage {
    pname = "my-plugin";
    version = "1.0.0";
    src = ./my-plugin;
    npmDepsHash = pkgs.lib.fakeHash; # replace with the got: value from the first build
    dontNpmBuild = true; # for plugins that need no compilation
  };
in
{
  imports = [ inputs.dsh-nix.homeManagerModules.dsh ];
  programs.dsh = {
    enable = true;
    profiles.custom.plugins = [ "@deepseek-ai/dsh-base" myPlugin ];
  };
}
```

`src` may also be a source input pinned in the user's flake.
Put the real hash reported by the first build's `got:` into `npmDepsHash`, then rebuild the same declaration to confirm success.
For plugins that need compilation, omit `dontNpmBuild` so the required npm build scripts run.

The plugin's effective root is resolved at build time.
If the plugin directory has `package.json` at its top level, that directory is preferred; otherwise the direct package under `lib/node_modules/<name>/package.json` (including scoped packages) is searched.
Zero or multiple candidates fail the build.
The package name is read from the selected `package.json` `name`, not the derivation `pname`.
The plugin's `node_modules` is preserved without moving or flattening, so transitive dependencies resolve from the plugin's existing layout.

### Plugin packages without a bundle

Not every official plugin package is a bundle: a cordis plugin such as `@deepseek-ai/dsh-tool-str-replace-editor` ships in the installation with no `dsh.bundle` of its own, and upstream's own README composes it by row. The profile's `userPatches` layer can insert that row by package name; the name resolves from the installation, so it needs no Nix packaging either.

Because the package declares no `dsh.bundle`, `dsh plugin` treats it as a plain dependency and activates no layer — the row is the mount point. Use this for plugin packages rather than expecting a layer:

```nix
programs.dsh.templates.web.userPatches = [
  {
    insert = [
      { id = "str-replace-editor"; name = "@deepseek-ai/dsh-tool-str-replace-editor"; }
    ];
  }
];
```

### Composition rules

Each entry that declares `dsh.bundle.patch` contributes a layer.
Bundle declaration order is the layer order.
Scoped packages are linked per package inside their scope directory, so they coexist with Nix-provided plugins in the same scope.
If two entries share a package name, the build fails.

## Usage

### Overlay

```nix
imports = [ inputs.dsh-nix.nixosModules.default ];
# Or add the overlay directly:
nixpkgs.overlays = [ inputs.dsh-nix.overlays.default ];

environment.systemPackages = [ pkgs.dsh ];
```

The Home Manager module's `package` uses `pkgs.dsh` when the overlay is applied, and otherwise builds the bundled `pkgs/dsh.nix`.
An explicitly specified `package` is never replaced or rewrapped by the module.

### Home Manager

```nix
inputs.dsh-nix.url = "github:yqYo1/dsh-nix";
inputs.dsh-nix.inputs.nixpkgs.follows = "nixpkgs";

imports = [ inputs.dsh-nix.homeManagerModules.dsh ];

programs.dsh = {
  enable = true;
  # The five shipped templates are installed by default as profiles of the
  # same name, each taking its bundles from the dsh installation; disable one
  # individually.
  templates.acp.enable = false;
  # Add or override only what you name on the web template profile.
  templates.web.extraPlugins = [ "@deepseek-ai/dsh-experimental-session-search" ];
  templates.web.userPatches = [
    {
      insert = [
        { id = "str-replace-editor"; name = "@deepseek-ai/dsh-tool-str-replace-editor"; }
      ];
    }
  ];
  # A user-defined profile that extends a shipped template; this works even
  # while that template profile is disabled.
  profiles.research = {
    extends = "web";
    extraPlugins = [ "@deepseek-ai/dsh-experimental-session-search" ];
  };
  # A fully custom profile: no template; `plugins` is the whole composition.
  # Non-official plugins are Nix packages or paths (see [Out-of-tree plugins](#out-of-tree-plugins-nix-packages-and-paths)).
  profiles.custom = {
    plugins = [ "@deepseek-ai/dsh-base" "@deepseek-ai/dsh-experimental-session-search" ];
    userPatchesFile = ./patches.yml;
  };
  homePatchesFile = ./home-patches.yml;
  # settings = { ... }; # seeds ~/.dsh/settings.yaml only when it does not exist
};
```

#### Profiles and templates

`web`, `headless`, `sdk`, `sdk-minimal`, and `acp` are the shipped profile templates (upstream `PROFILE_TEMPLATES`).
All five default to enabled; their bundle list is read from the installed dsh at build time, so it is never maintained here.
`templates.<name>.enable = false` removes one template profile; disabling all five installs no template profiles.
`templates.<name>.extraPlugins` and `templates.<name>.userPatches` add entries or override only the rows they name. `extraPlugins` accepts the same forms as `plugins`. A bundle already contributed by the template cannot be listed again (the build fails), whether extending it in place or through `extends`; template bundles cannot be removed.
`profiles.<name>` declares a user-defined profile and must set either `plugins` (full custom composition) or `extends = "<template>"` (template bundles and settings with `extraPlugins`/`userPatches` applied on top), not both. For a user profile, `extraPlugins` requires `extends`; `profiles.<name>.enable = false` removes a user profile. `profiles` starts empty; the five templates above are the only profiles installed by default.

The template profile and a user profile of the same name are exclusive: `profiles.web` requires `templates.web.enable = false`, otherwise evaluation fails. An `extends` reference does not require the template profile to be enabled, so `profiles.research.extends = "web"` works with `templates.web.enable = false`.

An existing configuration that declared `profiles.web.plugins = [...]` is a fully custom profile and now clashes with the default `templates.web`; set `templates.web.enable = false` to keep it, or move the additions to `templates.web.extraPlugins`/`userPatches`.

Profile names are single path components under `~/.dsh/profiles`. Empty names, `.`, `..`, `node_modules`, names containing a slash, a backslash, or a control character are rejected.
`userPatches` is JSON-serialisable only; use `userPatchesFile` for `!!js` expressions.
The home-level patch (`homePatchesFile`) is applied after each profile's own patch layer.
`dsh --profile <name> --dump-config` prints the effective composition for inspection.

#### Module options

- `programs.dsh.enable` — install the CLI and run profile activation.
- `programs.dsh.package` — the CLI derivation; defaults to `pkgs.dsh` via the overlay or the bundled build. Keep it the unwrapped dsh installation: template profiles read `PROFILE_TEMPLATES` from it and on-demand bundles link its source tree.
- `programs.dsh.templates.<name>` — a shipped template profile: `enable` (default `true`), `extraPlugins`, `userPatches`/`userPatchesFile`.
- `programs.dsh.profiles.<name>` — a user-defined profile: `enable` (default `true`), `extends`, `extraPlugins`, `plugins`, `userPatches`/`userPatchesFile`.
- `programs.dsh.homePatchesFile` — machine-level `cordis.patch.yml`, applied after each profile's patch layer.
- `programs.dsh.settings` — seed-only `settings.yaml` content, written only when the file does not exist.

#### Activation

Activation materialises each immutable profile into `~/.dsh/profiles/<name>` and skips re-materialising an identical profile directory via its stamp.
Profiles owned by the module are updated and removed; sessions, settings, credentials, and unmanaged profiles are preserved.

```sh
dsh --profile headless "task"
dsh --profile web # http://127.0.0.1:3080
```

### Building standalone

```sh
nix build --accept-flake-config .#dsh
nix build --accept-flake-config .#web
nix build --accept-flake-config .#headless
nix eval --accept-flake-config .#profiles.local-plugin --json
```

Runnable example profiles live in [`examples/`](examples/README.md); the checks build and boot them.
The `default` package is `dsh`.
Accepting the flake configuration enables the public binary cache `yqyo1.cachix.org`.
The public key for signature verification is pinned in `flake.nix`; downloads need no token.
Cache uploads from GitHub Actions use the repository secret `CACHIX_AUTH_TOKEN`.

## Regression verification

```sh
# Public flake: profile directories, rc.2 boot, Home Manager-independent checks
nix flake check --accept-flake-config --no-update-lock-file --no-write-lock-file
# Dedicated test flake: evaluation and sandbox activation on the pinned real Home Manager
nix flake check ./tests --accept-flake-config --no-update-lock-file --no-write-lock-file
# Real local-plugin startup and disposal
nix develop --accept-flake-config --no-update-lock-file --no-write-lock-file -c bash scripts/profile-smoke.sh
# profile install → activation → boot with the real daemon and driver 0
nix develop ./tests --accept-flake-config --no-update-lock-file --no-write-lock-file -c bash scripts/hm-e2e.sh
```

The public flake does not depend on Home Manager.
Only the regression checks that use HM are split into the `tests/` subflake, with the HM pin managed solely in `tests/flake.lock`.
This mirrors the [catppuccin/nix dev-flake](https://github.com/catppuccin/nix/blob/main/dev/flake.nix) separation.
Relative inputs (`path:../.`) require Nix >= 2.26.
The user's Home Manager choice and how `homeManagerModules.dsh` is imported do not change.
After updating the public flake's inputs/lock, also run `nix flake lock ./tests --update-input dsh-nix` to sync the test-side graph (a plain lock cannot see the moved `path:../.` input).
`scripts/update-dsh.sh` retargets the `dsh` input, syncs both locks, and then runs the public checks, the dedicated tests checks, and the real host E2E.

- **validator/profile shape**: verifies declaration order, same-scope coexistence, direct-plugin-only projection, and real transitive imports.
- **Official bundles**: drift-checks the accepted bundle set against the pinned DSH source (installation `dependencies` ∩ `dsh.bundle.patch`) and checks the on-demand list against upstream `ON_DEMAND_BUNDLES` (each must be a built bundle in the source).
- **Bundle and row composition**: boots a profile composed with two optional bundles, boots a profile that mounts an installed plugin package by a user patch row, and links both on-demand subagent bundles from the installation (provider binaries included) into a profile that boots. A resolution guard verifies every plugin package named by a shipped bundle's rows exists in the built installation.
- **Profile templates**: the module's template names match the pinned `PROFILE_TEMPLATES`; a template profile boots with no user bundle list; an extended template keeps its bundles, appends the extra one, and applies the user patch layer.
- **Out-of-tree plugins**: declares a genuine `buildNpmPackage` derivation directly and verifies standard-output root selection, rejection of ambiguous inputs, dependency imports, the CLI, and rc.2 boot and lifecycle.
- **Nix-packaged plugin**: builds a real registry plugin (`dsh-codex@0.3.2`) as a Nix derivation and boots a profile with it; the HM host E2E declares the same derivation in `programs.dsh.profiles.codex` through the HM flake, activates with driver 0, and boots `CHECK-OK`.
- **HM sandbox**: runs the real activation program across multiple generations to verify materialisation, real imports, removal, re-execution, preservation of user data, and refusal of symlinks for out-of-tree plugins. Nix CLIs inside the sandbox are shims and are distinguished from real host package-install proof.
- **HM host**: isolates HOME/XDG/Nix state in scratch and installs the given packages with the real daemon and driver 0, verifying real imports of the materialised Nix plugins (`dsh-codex`, `user-npm`), their CLI use, and rc.2 boot. External guards confirm the real user's profiles, gcroots, and app data remain unchanged.

`scripts/check-profile.mjs` uses the pinned rc.2 path `loadProfile` → `createRuntimeResolution` → `readProfilePatches` → `boot`.
It fails without emitting `CHECK-OK` if DSH's own startup audit fails or a non-zero exit is requested during boot.
After boot the tree is disposed; launcher readiness is not asserted.
Running an actual agent requires credentials.

## Repository layout

- `pkgs/` — the `dsh` package build, its pnpm-deps FOD support and the Node builtin shim.
- `lib/` — profile composition (`profiles.nix`, `plugins.nix`) and build-time helpers (`read-profile-template.mjs`).
- `modules/home-manager/` — the `programs.dsh` Home Manager module.
- `examples/` — runnable example profiles and a local example plugin; the checks build and boot them.
- `scripts/` — operator/CI commands: `update-dsh.sh`, `profile-smoke.sh`, `hm-e2e.sh`, `check-profile.mjs`.
- `tests/` — the dedicated test flake, its fixtures (`tests/fixtures/`) and the real Home Manager harnesses.
- `flake.nix` / `flake.lock` — the public flake and its pinned inputs; `tests/flake.lock` pins the test-side Home Manager graph.

## Notes

- The `deepseek-harness-pnpm-deps` fixed-output derivation is always fetched with a dedicated pinned nixpkgs (`nixpkgs-fetch`), independent of the `nixpkgs` input, so following your own nixpkgs (`inputs.dsh-nix.inputs.nixpkgs.follows = "nixpkgs"`) keeps the pinned deps hash valid. Never add `follows` to `nixpkgs-fetch`. The nixpkgs that builds the rest of the package must provide `pnpmConfigHook` and pnpm 11.
- The `dsh-codex` test fixture (`tests/fixtures/codex-plugin.nix`) owns its lock and hash internally; users are never asked for plugin hashes. Activating consumers is a consumer-side management task; this repository's tests do not modify consumer dotfiles.

## License

MIT
