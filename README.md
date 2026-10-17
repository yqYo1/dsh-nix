# dsh-nix

Build [DeepSeek Harness](https://github.com/deepseek-ai/deepseek-harness) (`dsh`) with Nix and manage profiles and Home Manager configuration declaratively.
The DSH source is pinned as a flake input; the current package is `0.2.1-rc.1`.

- **`pkgs.dsh`**: the CLI package, built from the pnpm monorepo.
- **profile packager**: resolves plugin dependencies and composes profiles at build time.
- **`programs.dsh`**: the Home Manager module managing profile composition under `~/.dsh`. Its scope is separated from user data such as sessions, settings, and credentials.

## Plugin composition

Profile `plugins` accept the following forms, mixed in declaration order:

- **in-box bundle**: a name such as `"@deepseek-ai/dsh-base"`, resolved from the DSH package being run.
- **pnpm spec**: `"dsh-codex@0.3.2"` or `"github:someone/plugin"`; builds a pnpm graph including transitive/peer dependencies at build time.
- **Nix package**: a user-declared derivation such as `pkgs.buildNpmPackage { ... }`; linked into the profile with its built dependency closure intact.
- **Nix path**: a prebuilt plugin directory with `package.json` at its root, such as `./my-plugin`; required runtime dependencies must be contained in the artifact.

Layers are registered from each package's `dsh.bundle.patch` declaration.
`plugins` declaration order is the layer order and does not depend on pnpm manifest or lockfile key order.
Spec transitive/peer dependencies stay in the runtime graph and are never promoted to direct profile plugins or layers.
Scoped packages are linked per package inside their scope directory, so they coexist with Nix plugins in the same scope.
If a spec and a Nix plugin share a package name, the build fails.

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
  profiles.headless = {
    plugins = [ "@deepseek-ai/dsh-base" "@deepseek-ai/dsh-headless" ];
  };
  profiles.web = {
    plugins = [ "@deepseek-ai/dsh-base" "@deepseek-ai/dsh-web-app" ];
  };
  profiles.custom = {
    plugins = [
      "@deepseek-ai/dsh-base"
      "dsh-codex@0.3.2"
    ];
    specsLock = ./custom-pnpm-lock.yaml;
    specsHash = "sha256-..."; # use the hash reported by the real build
    userPatchesFile = ./patches.yml;
  };
  homePatchesFile = ./home-patches.yml;
  # settings = { ... }; # seeds ~/.dsh/settings.yaml only when it does not exist
};
```

Activation materialises each immutable profile into `~/.dsh/profiles/<name>` and skips re-materialising an identical artifact via its stamp.
Profiles owned by the module are updated and removed; sessions, settings, credentials, and unmanaged profiles are preserved.

```sh
dsh --profile headless "task"
dsh --profile web # http://127.0.0.1:3080
```

### Building standalone

```sh
nix build --accept-flake-config .#dsh
nix build --accept-flake-config .#tui-spec
nix eval --accept-flake-config .#profiles.tui-spec --json
```

The `default` package is `dsh`.
Accepting the flake configuration enables the public binary cache `yqyo1.cachix.org`.
The public key for signature verification is pinned in `flake.nix`; downloads need no token.
Cache uploads from GitHub Actions use the repository secret `CACHIX_AUTH_TOKEN`.

## User-declared npm packages

A `pkgs.buildNpmPackage` derivation is passed directly in `plugins`.
The source, `package-lock.json`, `npmDepsHash`, and build settings are managed by the user's package declaration; dsh-nix composes the finished plugin into the profile.
Profiles that declare only Nix plugins do not need `specsLock`/`specsHash`.
When spec plugins are mixed in, specify them as before for the spec side's dependency pinning.

The example below adds to the configuration importing the Home Manager module from the previous section.
`./my-plugin` is an npm project containing `package.json`, `package-lock.json`, the patch referenced by `dsh.bundle.patch`, and the runtime source.

```nix
{ pkgs, ... }:
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
  programs.dsh = {
    enable = true;
    profiles.custom.plugins = [ "@deepseek-ai/dsh-base" myPlugin ];
  };
}
```

`src` may also be a source input pinned in the user's flake.
Put the real hash reported by the first build's `got:` into `npmDepsHash`, then rebuild the same declaration to confirm success.
For plugins that need compilation, omit `dontNpmBuild` so the required npm build scripts run.

The plugin root is resolved at build time.
If the artifact has `package.json` at its top level, that directory is preferred; otherwise the direct package under `lib/node_modules/<name>/package.json` (including scoped packages) is searched.
Zero or multiple candidates fail the build.
The package name is read from the selected `package.json` `name`, not the derivation `pname`.
The plugin's `node_modules` is preserved without moving or flattening, so transitive dependencies resolve from the plugin's existing layout.

## Pinning spec plugin dependencies

`specsLock` takes a pnpm 11 `pnpm-lock.yaml` that declares only the target spec plugins as direct dependencies of the root importer (`.`).
Extra workspace importers are not allowed.
Manage the lockfile itself, recording version, integrity, and peer dependency combinations, in Git along with your configuration.
When adding or updating plugins, update the lockfile in the same Nix-managed pnpm 11 environment.
An example local `file:` spec and its lockfile live in `examples/profiles/tui-spec.nix` and `examples/profiles/tui-spec-pnpm-lock.yaml`.

Builds with a lockfile run with `--frozen-lockfile`.
Mismatches with the declaration, extra direct dependencies, and missing registry integrity fail; there is no fallback to unpinned resolution.
Even a frozen install downloads pinned packages that are not in the cache.

`specsHash` is not an input to dependency resolution; it verifies the built artifact.
After updating the lockfile, build with `specsHash = "";` and then rebuild with the `got:` value Nix actually reported.
Preserving the full runtime graph changes the artifact, so hashes from the previous format must be re-discovered.

For compatibility, hash-only setups that omit `specsLock` remain available.
However, they re-resolve registry version ranges, so a cold build of the same configuration can produce a different artifact.
For reproducible setups, specify both `specsLock` and `specsHash`.

## Regression verification

```sh
# Public flake: profile artifacts, rc.2 boot, Home Manager-independent checks
nix flake check --accept-flake-config --no-update-lock-file --no-write-lock-file
# Dedicated test flake: evaluation and sandbox activation on the pinned real Home Manager
nix flake check ./tests --accept-flake-config --no-update-lock-file --no-write-lock-file
# Real TUI startup and disposal
nix develop --accept-flake-config --no-update-lock-file --no-write-lock-file -c bash scripts/profile-smoke.sh
# profile install → activation → boot with the real daemon and driver 0
nix develop ./tests --accept-flake-config --no-update-lock-file --no-write-lock-file -c bash scripts/hm-e2e.sh
```

The public flake does not depend on Home Manager.
Only the regression checks that use HM are split into the `tests/` subflake, with the HM pin managed solely in `tests/flake.lock`.
This mirrors the [catppuccin/nix dev-flake](https://github.com/catppuccin/nix/blob/main/dev/flake.nix) separation.
Relative inputs (`path:../.`) require Nix >= 2.26.
The user's Home Manager choice and how `homeManagerModules.dsh` is imported do not change.
After updating the public flake's inputs/lock, also run `nix flake lock ./tests` to sync the test-side graph.
The DSH updater syncs both locks and then runs the public checks, the dedicated tests checks, and the real host E2E.

- **validator/artifacts**: verifies declaration order, pinned lock bytes, same-scope coexistence, direct-plugin-only projection, and real transitive imports.
- **Codex runtime**: uses a fresh HOME/XDG and a rejecting network guard to verify the real CLI, `dsh plugin exec` through the package-bundled private pnpm, and real profile boot/dispose.
- **User-declared npm packages**: declares a genuine `buildNpmPackage` derivation directly and verifies standard-output root selection, rejection of ambiguous inputs, dependency imports, the CLI, and rc.2 boot and lifecycle.
- **HM sandbox**: runs the real activation program across multiple generations to verify materialisation, real imports, removal, re-execution, preservation of user data, and refusal of symlinks for spec profiles and user-declared npm packages. Nix CLIs inside the sandbox are shims and are distinguished from real host package-install proof.
- **HM host**: isolates HOME/XDG/Nix state in scratch and installs the given packages with the real daemon and driver 0, verifying real imports of the materialised npm plugin, its CLI, and rc.2 boot. External guards confirm the real user's profiles, gcroots, and app data remain unchanged.

`scripts/check-profile.mjs` uses the pinned rc.2 path `loadProfile` → `createRuntimeResolution` → `readProfilePatches` → `boot`.
It fails without emitting `CHECK-OK` if DSH's own startup audit fails or a non-zero exit is requested during boot.
After boot the tree is disposed; launcher readiness is not asserted.
This verification is not proof of authenticated generation or native compaction.

`dsh-codex@0.3.2`'s `doctor` strictly compares the supported DSH API against `0.2.0-rc.1` and therefore reports a diagnostic incompatibility with exit code 1 against rc.2.
Regression checks confirm this diagnostic as-is and never spoof package metadata.
The `status` exit code 1 when signed out is likewise verified by distinguishing the exact `signed-out` response from import/network failures.
Running an actual agent requires credentials.

## Notes

- The nixpkgs that builds the module's default package must provide `fetchPnpmDeps`, `pnpmConfigHook`, and pnpm 11.
- Upstream's standard surfaces are `web` and `headless`. The TUI is composed as a plugin.
- Updating `specsLock`/`specsHash` and activating consumers are consumer-side management tasks. This repository's tests do not modify consumer dotfiles.

## License

MIT
