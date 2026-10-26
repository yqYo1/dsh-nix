# Nix-native DSH profile builder.
#
# A BUNDLE is a plain (often non-flake) package directory: it carries its own
# package.json (with `dsh.bundle.patch`) and cordis.patch.yml.  We import it
# verbatim — we never transcribe its rows.
# A PROFILE is the artifact we build: an immutable DSH profile directory
# (package.json manifest + node_modules view) that `dsh --profile` consumes.
# Cordis stays DSH's runtime; this flake does not reimplement it.
#
#   nix flake check                         assertions + profile artifact shape
#   nix eval .#profiles.local-plugin --json   the declared profile (ordered bundles)
#   nix build .#packages.x86_64-linux.local-plugin   the immutable profile directory
#   ./scripts/profile-smoke.sh              boot it with the packaged dsh CLI
#
{
  description = "Nix-native DSH profile builder";

  nixConfig = {
    extra-substituters = [
      "https://yqyo1.cachix.org"
    ];
    extra-trusted-public-keys = [
      "yqyo1.cachix.org-1:8v2GAv9lm0AURGOHo92N4+lgAhVE0+v8ou3DFT7hDEg="
    ];
  };

  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
  # Pinned fetch support for the `deepseek-harness-pnpm-deps` fixed-output
  # derivation.  `fetchPnpmDeps` ships its build script in the *evaluating*
  # nixpkgs, so a consumer that follows its own nixpkgs into this flake would
  # otherwise fetch the store with a different script and miss the pinned
  # output hash.  The deps fetch therefore always runs from this pin;
  # everything else still builds with the consumer's nixpkgs.  Do NOT add
  # `follows` to this input — that reintroduces the fixed-output mismatch.
  inputs.nixpkgs-fetch.url = "github:NixOS/nixpkgs/a7868a727837f3c09cee2ce0ca671c76b1589fed";
  inputs.systems.url = "github:nix-systems/default";
  inputs.dsh = {
    url = "github:deepseek-ai/deepseek-harness/dsh-v0.2.1-rc.2";
    flake = false;
  };

  outputs =
    {
      self,
      nixpkgs,
      nixpkgs-fetch,
      systems,
      dsh,
    }:
    let
      lib = nixpkgs.lib;
      supportedSystems = import systems;
      forAllSystems = f: lib.genAttrs supportedSystems (system: f system);

      # The one fetch support every dsh build uses.  The pnpm-deps FOD's
      # hash is bound to `fetchPnpmDeps`' script text, so it must never be
      # instantiated from a consumer-mutable nixpkgs (issue #10).
      fetchPnpmDepsFor = system: (nixpkgs-fetch.legacyPackages.${system}).fetchPnpmDeps;

      plugins = import ./lib/plugins.nix { inherit lib; };
      profilesLib = import ./lib/profiles.nix { inherit lib; };
      # The official on-demand bundles are not installation dependencies, but
      # the pinned dsh source still contains and builds them.  Profile builds
      # link the installed package directly, so no npm fetch, version pin,
      # lockfile, or pnpm-store hash is maintained separately.
      onDemandBundles = [
        "@deepseek-ai/dsh-subagent-codex"
        "@deepseek-ai/dsh-subagent-claude-code"
      ];
      # The official bundles shipped by the dsh installation: every package
      # under `packages/bundle/` and `packages/experimental/` that declares
      # `dsh.bundle.patch`.  Names resolve from the installation at runtime —
      # users reference them bare, with nothing to package.  Mirrors upstream
      # `PROFILE_TEMPLATES` bundles plus `OPTIONAL_BUNDLES` (shipped switched
      # off, offered by the plugin manager).  The
      # `official-bundles` check fails on drift with the pinned dsh source.
      inBoxNames = [
        # Bundles of the shipped profile templates (`PROFILE_TEMPLATES`).
        "@deepseek-ai/dsh-base"
        "@deepseek-ai/dsh-web-app"
        "@deepseek-ai/dsh-headless"
        "@deepseek-ai/dsh-sdk-app"
        "@deepseek-ai/dsh-sdk-minimal"
        "@deepseek-ai/dsh-acp-app"
        # Opt-in bundles (upstream OPTIONAL_BUNDLES).
        "@deepseek-ai/dsh-experimental-session-search"
        "@deepseek-ai/dsh-experimental-ralph-bundle"
        "@deepseek-ai/dsh-experimental-terminal-bundle"
        "@deepseek-ai/dsh-experimental-badge-skill-bundle"
        "@deepseek-ai/dsh-experimental-session-titles-bundle"
        "@deepseek-ai/dsh-experimental-agent-team-profile"
        "@deepseek-ai/dsh-experimental-voice-input-bundle"
        "@deepseek-ai/dsh-experimental-cot-translation-bundle"
        "@deepseek-ai/dsh-experimental-auto-review"
        "@deepseek-ai/dsh-experimental-inspector-profile"
        "@deepseek-ai/dsh-experimental-plugin-market-bundle"
        "@deepseek-ai/dsh-experimental-tool-worktree"
      ];
      # Shipped profile templates (dsh `PROFILE_TEMPLATES`).  The module
      # installs one profile per name by default; the bundles come from the
      # dsh installation at build time, never from user configuration.
      profileTemplates = [ "acp" "headless" "sdk" "sdk-minimal" "web" ];
      localPlugin = import ./examples/profiles/local-plugin.nix {
        inherit plugins profilesLib inBoxNames;
      };
      web = import ./examples/profiles/web.nix {
        inherit profilesLib inBoxNames;
      };
      headless = import ./examples/profiles/headless.nix {
        inherit profilesLib inBoxNames;
      };

      profiles = {
        inherit
          web
          headless
          ;
        local-plugin = localPlugin;
      };

      homeManagerModules.dsh = import ./modules/home-manager/dsh.nix {
        pluginsLib = plugins;
        inherit profilesLib inBoxNames profileTemplates onDemandBundles;
        dshSrc = dsh;
        inherit fetchPnpmDepsFor;
      };

      # `pkgs.dsh` for any consumer applying the overlay.  The deps FOD is
      # built from the pinned fetch support so this path keeps the hash
      # valid under consumer nixpkgs overrides.
      overlay = final: prev: {
        dsh = final.callPackage ./pkgs/dsh.nix {
          src = dsh;
          fetchPnpmDeps = fetchPnpmDepsFor final.stdenv.hostPlatform.system;
        };
      };
    in
    {
      inherit
        lib
        plugins
        profilesLib
        profiles
        homeManagerModules
        ;
      inherit overlay;

      overlays.default = overlay;

      # Convenience: importing this NixOS module wires the overlay into
      # nixpkgs, so `pkgs.dsh` resolves everywhere on the system.
      nixosModules.default = { config, lib, ... }: {
        nixpkgs.overlays = [ overlay ];
      };

      packages = forAllSystems (
        system:
        let
          pkgs = nixpkgs.legacyPackages.${system};
          dshPackage = pkgs.callPackage ./pkgs/dsh.nix {
            src = dsh;
            fetchPnpmDeps = fetchPnpmDepsFor system;
          };
        in
        {
          # The default package is the primary user-facing DSH CLI. This
          # keeps `nix build` and `nix run .` useful without an attribute.
          default = dshPackage;
          dsh = dshPackage;

          local-plugin = profilesLib.buildProfile {
            inherit pkgs;
            profile = profiles.local-plugin;
          };

          web = profilesLib.buildProfile {
            inherit pkgs;
            profile = profiles.web;
          };

          headless = profilesLib.buildProfile {
            inherit pkgs;
            profile = profiles.headless;
          };
        }
      );

      checks = forAllSystems (
        system:
        let
          pkgs = nixpkgs.legacyPackages.${system};
          localPluginArtifact = self.packages.${system}.local-plugin;
          expectedBundles = builtins.toJSON [ "@dsh-nix/example-plugin" ];
        in
        {
          profile-local-plugin =
            pkgs.runCommand "dsh-profile-local-plugin-check"
              {
                nativeBuildInputs = [ pkgs.jq ];
              }
              ''
                package_json=${localPluginArtifact}/package.json
                actual_bundles=$(jq -c '.dsh.profile.bundles' "$package_json")
                expected_bundles=${lib.escapeShellArg expectedBundles}
                test "$actual_bundles" = "$expected_bundles"

                test -L ${localPluginArtifact}/node_modules/@dsh-nix/example-plugin

                touch "$out"
              '';

          # Official-bundle drift guard: the accepted by-name set must equal
          # every bundle the installation ships.  The rule mirrors the
          # plugin-manager's own `shipped` computation: a package is an
          # installation-provided bundle iff its name is a key of the
          # installation package.json `dependencies` and its manifest
          # declares `dsh.bundle.patch`.  The on-demand subagent bundles are
          # not installation dependencies (catalog-only), so the rule
          # excludes them without a path allowlist and cannot miss a bundle
          # placed anywhere else in the tree; they are covered by the
          # official-on-demand check and linked at build time.
          official-bundles =
            pkgs.runCommand "dsh-official-bundles-check"
              {
                nativeBuildInputs = [ pkgs.jq ];
                src = dsh;
                expected = builtins.toJSON inBoxNames;
              }
              ''
                cliDeps=$(jq -r '.dependencies // {} | keys[]' "$src/apps/cli/package.json")
                actual=$(
                  cd "$src"
                  find . -name node_modules -prune -o -name package.json -print | while IFS= read -r p; do
                    name=$(jq -r '.name // empty' "$p" 2>/dev/null) || continue
                    [ -n "$name" ] || continue
                    if printf '%s\n' "$cliDeps" | grep -qxF "$name" \
                      && jq -e '((.dsh // {}).bundle // {}).patch != null' "$p" >/dev/null 2>&1; then
                      printf '%s\n' "$name"
                    fi
                  done | sort
                )
                want=$(printf '%s\n' "$expected" | jq -r '.[]' | sort)
                if [ "$actual" != "$want" ]; then
                  echo "official-bundles: by-name set drifted from the installation's shipped bundles" >&2
                  diff <(printf '%s\n' "$want") <(printf '%s\n' "$actual") >&2 || true
                  echo "(left: accepted list, right: shipped bundles)" >&2
                  exit 1
                fi
                touch "$out"
              '';

          # The on-demand bundle names are the only per-bundle list this
          # repository keeps; it must equal upstream ON_DEMAND_BUNDLES, and
          # each name must be a built bundle in the pinned dsh source.  No npm
          # fetch, version pin, lockfile, or store hash is maintained here.
          official-on-demand =
            pkgs.runCommand "dsh-official-on-demand-check"
              {
                nativeBuildInputs = [ pkgs.jq ];
                src = dsh;
                install = self.packages.${system}.dsh;
                names = builtins.toJSON onDemandBundles;
              }
              ''
                upstream=$(sed -n '/ON_DEMAND_BUNDLES/,/\]/p' "$src/packages/boot/app-boot/src/official-bundle-packages.ts" \
                  | grep -oE "'@deepseek-ai/[^']+'" | tr -d "'" | sort)
                want=$(printf '%s\n' "$names" | jq -r '.[]' | sort)
                if [ "$upstream" != "$want" ]; then
                  echo "official-on-demand: names differ from upstream ON_DEMAND_BUNDLES" >&2
                  diff <(printf '%s\n' "$want") <(printf '%s\n' "$upstream") >&2 || true
                  exit 1
                fi
                for name in $want; do
                  matches=$(find "$install" -path '*/node_modules' -prune -o -name package.json -print \
                    | while IFS= read -r manifest; do
                        if [ "$(jq -r '.name // empty' "$manifest")" = "$name" ]; then
                          printf '%s\n' "$manifest"
                        fi
                      done)
                  count=$(printf '%s\n' "$matches" | grep -c . || true)
                  if [ "$count" -ne 1 ]; then
                    echo "official-on-demand: expected one built source package for $name, found $count" >&2
                    exit 1
                  fi
                  jq -e '((.dsh // {}).bundle // {}).patch != null' "$matches" >/dev/null \
                    || { echo "official-on-demand: $name declares no dsh.bundle.patch" >&2; exit 1; }
                  main=$(jq -r '.main // empty' "$matches")
                  [ -n "$main" ] && [ -f "$(dirname "$matches")/$main" ] \
                    || { echo "official-on-demand: $name is not built (missing $main)" >&2; exit 1; }
                done
                echo "on-demand bundles: $(printf '%s\n' "$want" | wc -l)"
                touch "$out"
              '';

          # Every plugin package named by a shipped bundle's rows must exist in
          # the built installation: that is what lets a profile row (or the
          # bundle itself) resolve the name without Nix packaging.  Guards the
          # "names resolve from the installation" promise across tag bumps.
          official-plugin-resolution =
            pkgs.runCommand "dsh-official-plugin-resolution-check"
              {
                nativeBuildInputs = [ pkgs.jq ];
                src = dsh;
                install = self.packages.${system}.dsh;
                shipped = builtins.toJSON inBoxNames;
              }
              ''
                printf '%s\n' "$shipped" | jq -r '.[]' | sort > "$TMPDIR/shipped.txt"
                cd "$src"
                find . -name node_modules -prune -o -name package.json -print > "$TMPDIR/pkgs.txt"
                : > "$TMPDIR/names.txt"
                : > "$TMPDIR/problems.txt"
                while IFS= read -r p; do
                  name=$(jq -r '.name // empty' "$p" 2>/dev/null) || continue
                  [ -n "$name" ] || continue
                  grep -qxF "$name" "$TMPDIR/shipped.txt" || continue
                  jq -r '[((.dsh // {}).bundle // {}).patch // empty] | flatten | .[]' "$p" > "$TMPDIR/patches.txt" 2>/dev/null || true
                  while IFS= read -r rel; do
                    [ -n "$rel" ] || continue
                    f="$(dirname "$p")/$rel"
                    if [ ! -f "$f" ]; then
                      echo "$name: declared patch $rel does not exist" >> "$TMPDIR/problems.txt"
                      continue
                    fi
                    grep -oE "name:[[:space:]]*['\"]?@deepseek-ai/[A-Za-z0-9._/-]+" "$f" \
                      | sed -E "s/^name:[[:space:]]*['\"]?//" >> "$TMPDIR/names.txt" || true
                  done < "$TMPDIR/patches.txt"
                done < "$TMPDIR/pkgs.txt"
                if [ -s "$TMPDIR/problems.txt" ]; then
                  echo "official-plugin-resolution: shipped bundle patch declarations are broken" >&2
                  cat "$TMPDIR/problems.txt" >&2
                  exit 1
                fi
                sed -E 's#^(@deepseek-ai/[^/]+)/.*#\1#' "$TMPDIR/names.txt" | sort -u > "$TMPDIR/want.txt"
                # -L follows the pnpm symlink farm; the depth bound stops the
                # traversal before parent/child workspace links recurse, and
                # still reaches every node_modules view (root, .pnpm, package).
                find -L "$install" -maxdepth 8 -path '*/node_modules/@deepseek-ai/*/package.json' -print 2>/dev/null \
                  | sed -E 's#.*/node_modules/(@deepseek-ai/[^/]+)/package.json#\1#' | sort -u > "$TMPDIR/have.txt" || true
                missing=$(comm -23 "$TMPDIR/want.txt" "$TMPDIR/have.txt")
                if [ -n "$missing" ]; then
                  echo "official-plugin-resolution: packages named by shipped bundle rows are absent from the installation:" >&2
                  printf '%s\n' "$missing" >&2
                  exit 1
                fi
                echo "resolved $(wc -l < "$TMPDIR/want.txt") official plugin packages from the installation"
                touch "$out"
              '';

          # The module installs the shipped profile templates by default; this
          # guard keeps its name list and every template's bundle list aligned
          # with the pinned dsh installation.
          profile-templates =
            pkgs.runCommand "dsh-profile-templates-check"
              {
                nativeBuildInputs = [ pkgs.nodejs pkgs.jq ];
                install = self.packages.${system}.dsh;
                names = builtins.toJSON profileTemplates;
                shipped = builtins.toJSON inBoxNames;
              }
              ''
                templates=$(node --expose-internals --require "$install/lib/dsh-builtin-compat.cjs" \
                  ${./lib/read-profile-template.mjs} "$install") || exit 1
                printf '%s\n' "$names" | jq -r '.[]' | sort > "$TMPDIR/want.txt"
                printf '%s' "$templates" | jq -r 'keys[]' | sort > "$TMPDIR/have.txt"
                if ! diff -u "$TMPDIR/want.txt" "$TMPDIR/have.txt"; then
                  echo "profile-templates: module template list differs from PROFILE_TEMPLATES" >&2
                  exit 1
                fi
                printf '%s' "$templates" | jq -r 'to_entries[] | .value.bundles[]' | sort -u > "$TMPDIR/bundles.txt"
                printf '%s\n' "$shipped" | jq -r '.[]' | sort > "$TMPDIR/shipped.txt"
                missing=$(comm -23 "$TMPDIR/bundles.txt" "$TMPDIR/shipped.txt")
                if [ -n "$missing" ]; then
                  echo "profile-templates: template bundles outside the in-box set:" >&2
                  printf '%s\n' "$missing" >&2
                  exit 1
                fi
                echo "templates: $(wc -l < "$TMPDIR/have.txt"); bundles: $(wc -l < "$TMPDIR/bundles.txt")"
                touch "$out"
              '';

          # A template profile takes its bundles from PROFILE_TEMPLATES and
          # boots without the user listing any bundle.
          profile-template =
            let
              profile = profilesLib.mkProfile {
                name = "web";
                extends = "web";
                inherit inBoxNames;
              };
              artifact = profilesLib.buildProfile {
                inherit pkgs profile;
                install = self.packages.${system}.dsh;
              };
            in
            pkgs.runCommand "dsh-profile-template-check"
              {
                nativeBuildInputs = [ pkgs.nodejs pkgs.jq ];
              }
              ''
                expected=$(node --expose-internals --require ${self.packages.${system}.dsh}/lib/dsh-builtin-compat.cjs \
                  ${./lib/read-profile-template.mjs} ${self.packages.${system}.dsh} web) || exit 1
                jq -e --argjson want "$expected" '.dsh.profile.bundles == $want' ${artifact}/package.json >/dev/null \
                  || { echo "profile-template: bundles differ from PROFILE_TEMPLATES.web" >&2; exit 1; }
                home="$TMPDIR/home"
                mkdir -p "$home/profiles"
                cp -a ${artifact} "$home/profiles/web"
                chmod -R u+w "$home/profiles/web"
                if ! ${pkgs.nodejs}/bin/node --expose-internals \
                  --require ${self.packages.${system}.dsh}/lib/dsh-builtin-compat.cjs \
                  ${./scripts/check-profile.mjs} \
                  ${self.packages.${system}.dsh} web "$home" --port 0 --no-open \
                  > "$TMPDIR/check.log" 2>&1; then
                  cat "$TMPDIR/check.log" >&2
                  exit 1
                fi
                grep -q 'CHECK-OK' "$TMPDIR/check.log" || { cat "$TMPDIR/check.log" >&2; exit 1; }
                if grep -q 'skipping profile bundle' "$TMPDIR/check.log"; then
                  cat "$TMPDIR/check.log" >&2
                  exit 1
                fi
                touch "$out"
              '';

          # Extending a template keeps its bundles and settings, appends the
          # declared extra bundle, and applies the user patch layer on top.
          profile-template-extension =
            let
              profile = profilesLib.mkProfile {
                name = "web-extended";
                extends = "web";
                extraPlugins = [ "@deepseek-ai/dsh-experimental-session-search" ];
                userPatches = [
                  {
                    insert = [
                      { id = "str-replace-editor"; name = "@deepseek-ai/dsh-tool-str-replace-editor"; }
                    ];
                  }
                ];
                inherit inBoxNames;
              };
              artifact = profilesLib.buildProfile {
                inherit pkgs profile;
                install = self.packages.${system}.dsh;
              };
            in
            pkgs.runCommand "dsh-profile-template-extension-check"
              {
                nativeBuildInputs = [ pkgs.nodejs pkgs.jq ];
              }
              ''
                expected=$(node --expose-internals --require ${self.packages.${system}.dsh}/lib/dsh-builtin-compat.cjs \
                  ${./lib/read-profile-template.mjs} ${self.packages.${system}.dsh} web) || exit 1
                jq -e --argjson want "$(printf '%s' "$expected" | jq -c '. + ["@deepseek-ai/dsh-experimental-session-search"]')" \
                  '.dsh.profile.bundles == $want' ${artifact}/package.json >/dev/null \
                  || { echo "profile-template-extension: template bundles were not kept in order" >&2; exit 1; }
                jq -e '.[0].insert[0].name == "@deepseek-ai/dsh-tool-str-replace-editor"' \
                  ${artifact}/cordis.patch.yml >/dev/null \
                  || { echo "profile-template-extension: user patch layer missing" >&2; exit 1; }
                home="$TMPDIR/home"
                mkdir -p "$home/profiles"
                cp -a ${artifact} "$home/profiles/web-extended"
                chmod -R u+w "$home/profiles/web-extended"
                if ! ${pkgs.nodejs}/bin/node --expose-internals \
                  --require ${self.packages.${system}.dsh}/lib/dsh-builtin-compat.cjs \
                  ${./scripts/check-profile.mjs} \
                  ${self.packages.${system}.dsh} web-extended "$home" --port 0 --no-open \
                  > "$TMPDIR/check.log" 2>&1; then
                  cat "$TMPDIR/check.log" >&2
                  exit 1
                fi
                grep -q 'CHECK-OK' "$TMPDIR/check.log" || { cat "$TMPDIR/check.log" >&2; exit 1; }
                if grep -q 'skipping profile bundle' "$TMPDIR/check.log"; then
                  cat "$TMPDIR/check.log" >&2
                  exit 1
                fi
                touch "$out"
              '';

          # Genuine user-declared buildNpmPackage regression: the raw
          # derivation goes straight into `plugins` (no installedRoot selectors).
          profile-user-npm = (import ./tests/user-npm.nix {
            inherit pkgs;
            dshPackage = self.packages.${system}.dsh;
            checker = ./scripts/check-profile.mjs;
          }).check;

          boot-checker-wiring = import ./tests/boot-checker.nix { inherit pkgs; };

          profile-regression = (import ./tests/profile-regression.nix { inherit pkgs; }).check;

          profile-boot-local-plugin =
            pkgs.runCommand "dsh-profile-boot-local-plugin-check" { nativeBuildInputs = [ pkgs.nodejs ]; } ''
              export HOME="$TMPDIR/home"
              home="$HOME/.dsh"
              mkdir -p "$home/profiles"
              cp -a ${self.packages.${system}.local-plugin} "$home/profiles/local-plugin"
              chmod -R u+w "$home/profiles/local-plugin"
              if ! ${pkgs.nodejs}/bin/node --expose-internals \
                --require ${self.packages.${system}.dsh}/lib/dsh-builtin-compat.cjs \
                ${./scripts/check-profile.mjs} \
                ${self.packages.${system}.dsh} local-plugin "$home" \
                > "$TMPDIR/check.log" 2>&1; then
                cat "$TMPDIR/check.log" >&2
                exit 1
              fi
              grep -q '^CHECK-OK$' "$TMPDIR/check.log"
              printf 'activated\ndisposed\n' > "$TMPDIR/expected-lifecycle"
              cmp "$TMPDIR/expected-lifecycle" "$home/example-plugin.log"
              mkdir -p "$out"
              cp "$home/example-plugin.log" "$out/lifecycle"
            '';

          home-module =
            pkgs.runCommand "dsh-home-module-check"
              {
                src = ./.;
                nativeBuildInputs = [ pkgs.nix ];
              }
              ''
                cd "$src"
                NIX_STATE_DIR="$TMPDIR/nix-state" \
                  ${pkgs.nix}/bin/nix-instantiate --eval --strict --json \
                  --arg pkgs 'import ${pkgs.path} {}' \
                  tests/home-module.nix > "$TMPDIR/result.json"
                ${pkgs.jq}/bin/jq -e '.all == true' "$TMPDIR/result.json" > /dev/null
                touch "$out"
              '';

          # Build-time fail-loud: boot each in-box profile with dsh's own
          # boot() (which runs auditStartupEntries) and dispose.  A
          # profile that would fail at runtime — missing services, failed
          # activation — fails `nix build` here instead.
          profile-boot-web =
            pkgs.runCommand "dsh-profile-boot-web-check"
              {
                nativeBuildInputs = [ pkgs.nodejs ];
              }
              ''
                home="$TMPDIR/home"
                mkdir -p "$home/profiles"
                cp -a ${self.packages.${system}.web} "$home/profiles/web"
                chmod -R u+w "$home/profiles/web"
                if ! ${pkgs.nodejs}/bin/node --expose-internals \
                  --require ${self.packages.${system}.dsh}/lib/dsh-builtin-compat.cjs \
                  ${./scripts/check-profile.mjs} \
                  ${self.packages.${system}.dsh} web "$home" --port 0 --no-open \
                  > "$TMPDIR/check.log" 2>&1; then
                  cat "$TMPDIR/check.log" >&2
                  exit 1
                fi
                grep -q 'CHECK-OK' "$TMPDIR/check.log" || { cat "$TMPDIR/check.log" >&2; exit 1; }
                touch "$out"
              '';

          profile-boot-headless =
            pkgs.runCommand "dsh-profile-boot-headless-check"
              {
                nativeBuildInputs = [ pkgs.nodejs ];
              }
              ''
                home="$TMPDIR/home"
                mkdir -p "$home/profiles"
                cp -a ${self.packages.${system}.headless} "$home/profiles/headless"
                chmod -R u+w "$home/profiles/headless"
                # rc.1 starts the one-shot runner during apply, without
                # appReady. This boot-only fixture disables that row and
                # parses help instead of starting a model/application task.
                # It covers base + headless startup, NOT runner execution.
                printf '%s\n' '[{"id":"headless-runner","disabled":true}]' \
                  > "$home/profiles/headless/cordis.patch.yml"
                if ! ${pkgs.nodejs}/bin/node --expose-internals \
                  --require ${self.packages.${system}.dsh}/lib/dsh-builtin-compat.cjs \
                  ${./scripts/check-profile.mjs} \
                  ${self.packages.${system}.dsh} headless "$home" --help \
                  > "$TMPDIR/check.log" 2>&1; then
                  cat "$TMPDIR/check.log" >&2
                  exit 1
                fi
                grep -q 'CHECK-OK' "$TMPDIR/check.log" || { cat "$TMPDIR/check.log" >&2; exit 1; }
                touch "$out"
              '';

          # Optional official bundles need no packaging: base + web-app plus two
          # experimental bundles (session-search, the worktree tool) must boot
          # exactly like the plain web profile.
          profile-boot-experimental =
            let
              profile = profilesLib.mkProfile {
                name = "experimental";
                plugins = [
                  "@deepseek-ai/dsh-base"
                  "@deepseek-ai/dsh-web-app"
                  "@deepseek-ai/dsh-experimental-session-search"
                  "@deepseek-ai/dsh-experimental-tool-worktree"
                ];
                inherit inBoxNames;
              };
              artifact = profilesLib.buildProfile { inherit pkgs profile; };
            in
            pkgs.runCommand "dsh-profile-boot-experimental-check"
              {
                nativeBuildInputs = [ pkgs.nodejs pkgs.jq ];
              }
              ''
                home="$TMPDIR/home"
                mkdir -p "$home/profiles"
                cp -a ${artifact} "$home/profiles/experimental"
                chmod -R u+w "$home/profiles/experimental"
                # Composition is exact: all four declared bundles, order kept.
                jq -e '.dsh.profile.bundles == ["@deepseek-ai/dsh-base", "@deepseek-ai/dsh-web-app", "@deepseek-ai/dsh-experimental-session-search", "@deepseek-ai/dsh-experimental-tool-worktree"]' \
                  "$home/profiles/experimental/package.json" >/dev/null
                if ! ${pkgs.nodejs}/bin/node --expose-internals \
                  --require ${self.packages.${system}.dsh}/lib/dsh-builtin-compat.cjs \
                  ${./scripts/check-profile.mjs} \
                  ${self.packages.${system}.dsh} experimental "$home" --port 0 --no-open \
                  > "$TMPDIR/check.log" 2>&1; then
                  cat "$TMPDIR/check.log" >&2
                  exit 1
                fi
                grep -q 'CHECK-OK' "$TMPDIR/check.log" || { cat "$TMPDIR/check.log" >&2; exit 1; }
                # A dropped optional bundle would still let the boot pass; assert
                # the launcher reported no skipped bundle.
                if grep -q 'skipping profile bundle' "$TMPDIR/check.log"; then
                  cat "$TMPDIR/check.log" >&2
                  exit 1
                fi
                touch "$out"
              '';

          # An official cordis plugin package that ships without a bundle of
          # its own mounts without packaging: a patch row in the profile's own
          # layer names the package and the name resolves from the built
          # installation (no bundle, no extra Nix packaging).  base + web-app +
          # one official tool plugin (str-replace-editor, no dsh.bundle) must
          # compose the row and boot CHECK-OK.
          profile-official-plugin =
            let
              profile = profilesLib.mkProfile {
                name = "official-plugin";
                plugins = [
                  "@deepseek-ai/dsh-base"
                  "@deepseek-ai/dsh-web-app"
                ];
                userPatches = [
                  {
                    insert = [
                      {
                        id = "str-replace-editor";
                        name = "@deepseek-ai/dsh-tool-str-replace-editor";
                      }
                    ];
                  }
                ];
                inherit inBoxNames;
              };
              artifact = profilesLib.buildProfile { inherit pkgs profile; };
            in
            pkgs.runCommand "dsh-profile-official-plugin-check"
              {
                nativeBuildInputs = [ pkgs.nodejs pkgs.jq ];
              }
              ''
                home="$TMPDIR/home"
                mkdir -p "$home/profiles"
                cp -a ${artifact} "$home/profiles/official-plugin"
                chmod -R u+w "$home/profiles/official-plugin"
                jq -e '.dsh.profile.bundles == ["@deepseek-ai/dsh-base", "@deepseek-ai/dsh-web-app"]' \
                  "$home/profiles/official-plugin/package.json" >/dev/null
                grep -q 'str-replace-editor' "$home/profiles/official-plugin/cordis.patch.yml"
                if ! ${pkgs.nodejs}/bin/node --expose-internals \
                  --require ${self.packages.${system}.dsh}/lib/dsh-builtin-compat.cjs \
                  ${./scripts/check-profile.mjs} \
                  ${self.packages.${system}.dsh} official-plugin "$home" --port 0 --no-open \
                  > "$TMPDIR/check.log" 2>&1; then
                  cat "$TMPDIR/check.log" >&2
                  exit 1
                fi
                grep -q 'CHECK-OK' "$TMPDIR/check.log" || { cat "$TMPDIR/check.log" >&2; exit 1; }
                if grep -q 'skipping profile bundle' "$TMPDIR/check.log"; then
                  cat "$TMPDIR/check.log" >&2
                  exit 1
                fi
                touch "$out"
              '';

          # A real third-party plugin packaged as a Nix derivation (the user
          # route): the fixture builds dsh-codex from a pinned closure and the
          # profile links it like any Nix plugin; no profile-level spec/hash
          # API is involved.
          profile-nix-plugin =
            let
              plugin = import ./tests/fixtures/codex-plugin.nix { inherit pkgs; };
              profile = profilesLib.mkProfile {
                name = "nix-plugin";
                plugins = [
                  "@deepseek-ai/dsh-base"
                  "@deepseek-ai/dsh-web-app"
                  plugin
                ];
                userPatches = [
                  {
                    id = "llm-openai-codex";
                    config = { searchMode = "live"; useNativeCompaction = true; };
                  }
                ];
                inherit inBoxNames;
              };
              artifact = profilesLib.buildProfile { inherit pkgs profile; };
            in
            pkgs.runCommand "dsh-profile-nix-plugin-check"
              {
                nativeBuildInputs = [ pkgs.nodejs pkgs.jq ];
              }
              ''
                jq -e '.dsh.profile.bundles == ["@deepseek-ai/dsh-base", "@deepseek-ai/dsh-web-app", "dsh-codex"]' \
                  ${artifact}/package.json >/dev/null
                test -L ${artifact}/node_modules/dsh-codex
                jq -e '.[0].id == "llm-openai-codex" and .[0].config.searchMode == "live"' \
                  ${artifact}/cordis.patch.yml >/dev/null
                home="$TMPDIR/home"
                mkdir -p "$home/profiles"
                cp -a ${artifact} "$home/profiles/nix-plugin"
                chmod -R u+w "$home/profiles/nix-plugin"
                if ! ${pkgs.nodejs}/bin/node --expose-internals \
                  --require ${self.packages.${system}.dsh}/lib/dsh-builtin-compat.cjs \
                  ${./scripts/check-profile.mjs} \
                  ${self.packages.${system}.dsh} nix-plugin "$home" --port 0 --no-open \
                  > "$TMPDIR/check.log" 2>&1; then
                  cat "$TMPDIR/check.log" >&2
                  exit 1
                fi
                grep -q 'CHECK-OK' "$TMPDIR/check.log" || { cat "$TMPDIR/check.log" >&2; exit 1; }
                if grep -q 'skipping profile bundle' "$TMPDIR/check.log"; then
                  cat "$TMPDIR/check.log" >&2
                  exit 1
                fi
                touch "$out"
              '';

          # Official ON-DEMAND bundles by name: dsh-subagent-codex and
          # dsh-subagent-claude-code are not installation dependencies, but the
          # pinned dsh source builds them; dsh-nix links the installed package
          # and boots with no skipped bundle.
          profile-official-on-demand =
            let
              profile = profilesLib.mkProfile {
                name = "official-on-demand";
                plugins = [
                  "@deepseek-ai/dsh-base"
                  "@deepseek-ai/dsh-web-app"
                ] ++ onDemandBundles;
                inherit inBoxNames;
                installBundles = onDemandBundles;
              };
              artifact = profilesLib.buildProfile { inherit pkgs profile; install = self.packages.${system}.dsh; };
            in
            pkgs.runCommand "dsh-profile-official-on-demand-check"
              {
                nativeBuildInputs = [ pkgs.nodejs pkgs.jq ];
              }
              ''
                home="$TMPDIR/home"
                mkdir -p "$home/profiles"
                cp -a ${artifact} "$home/profiles/official-on-demand"
                chmod -R u+w "$home/profiles/official-on-demand"
                jq -e '.dsh.profile.bundles == ["@deepseek-ai/dsh-base", "@deepseek-ai/dsh-web-app", "@deepseek-ai/dsh-subagent-codex", "@deepseek-ai/dsh-subagent-claude-code"]' \
                  "$home/profiles/official-on-demand/package.json" >/dev/null
                test -f "$home/profiles/official-on-demand/node_modules/@deepseek-ai/dsh-subagent-codex/package.json"
                test -f "$home/profiles/official-on-demand/node_modules/@deepseek-ai/dsh-subagent-claude-code/package.json"
                test -e "$home/profiles/official-on-demand/node_modules/@deepseek-ai/dsh-subagent-codex/node_modules/@openai/codex"
                test -e "$home/profiles/official-on-demand/node_modules/@deepseek-ai/dsh-subagent-claude-code/node_modules/@anthropic-ai/claude-agent-sdk"
                if ! ${pkgs.nodejs}/bin/node --expose-internals \
                  --require ${self.packages.${system}.dsh}/lib/dsh-builtin-compat.cjs \
                  ${./scripts/check-profile.mjs} \
                  ${self.packages.${system}.dsh} official-on-demand "$home" --port 0 --no-open \
                  > "$TMPDIR/check.log" 2>&1; then
                  cat "$TMPDIR/check.log" >&2
                  exit 1
                fi
                grep -q 'CHECK-OK' "$TMPDIR/check.log" || { cat "$TMPDIR/check.log" >&2; exit 1; }
                if grep -q 'skipping profile bundle' "$TMPDIR/check.log"; then
                  cat "$TMPDIR/check.log" >&2
                  exit 1
                fi
                touch "$out"
              '';

          # Counterexample: web-app without base must fail the boot check
          # with dsh's own fail-loud (pending services), proving the check
          # catches the composition error at build time.
          profile-boot-web-nobase =
            pkgs.runCommand "dsh-profile-boot-web-nobase-check"
              {
                nativeBuildInputs = [
                  pkgs.nodejs
                  pkgs.jq
                ];
              }
              ''
                home="$TMPDIR/home"
                mkdir -p "$home/profiles"
                cp -a ${self.packages.${system}.web} "$home/profiles/web-nobase"
                chmod -R u+w "$home/profiles/web-nobase"
                jq '.dsh.profile.bundles = ["@deepseek-ai/dsh-web-app"]' \
                  "$home/profiles/web-nobase/package.json" > "$TMPDIR/package.json"
                mv "$TMPDIR/package.json" "$home/profiles/web-nobase/package.json"
                if ${pkgs.nodejs}/bin/node --expose-internals \
                  --require ${self.packages.${system}.dsh}/lib/dsh-builtin-compat.cjs \
                  ${./scripts/check-profile.mjs} \
                  ${self.packages.${system}.dsh} web-nobase "$home" --port 0 --no-open \
                  > "$TMPDIR/check.log" 2>&1; then
                  echo "profile-boot-web-nobase: expected fail-loud, got success" >&2
                  exit 1
                fi
                grep -q 'did not activate' "$TMPDIR/check.log" \
                  || { cat "$TMPDIR/check.log" >&2; exit 1; }
                touch "$out"
              '';
        }
      );

      devShells = forAllSystems (
        system:
        let
          pkgs = nixpkgs.legacyPackages.${system};
        in
        {
          default = pkgs.mkShell {
            packages = with pkgs; [
              nodejs
              pnpm_11
              yq-go
            ];
          };
        }
      );
    };
}
