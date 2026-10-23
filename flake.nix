# Nix-native DSH profile packager.
#
# A PLUGIN bundle is a plain (often non-flake) package directory: it carries
# its own package.json (with `dsh.bundle.patch`) and cordis.patch.yml.  We
# import it verbatim — we never transcribe its rows.
# A PROFILE bundle is the artifact we build: an immutable DSH profile
# directory (package.json manifest + node_modules view) that `dsh --profile`
# consumes.  Cordis stays DSH's runtime; this flake does not reimplement it.
#
#   nix flake check                         assertions + profile artifact shape
#   nix eval .#profiles.tui --json          the declared profile (ordered layers)
#   nix build .#packages.x86_64-linux.tui   the immutable profile directory
#   ./scripts/profile-smoke.sh              boot it with the packaged dsh CLI
#
# Optional: examples/profiles/dsh-web.nix shows importing dsh's own shipped
# bundles (non-flake repo input) with zero transcription; wire it in when a
# dsh checkout is visible to the flake.
{
  description = "Nix-native DSH profile packager";

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
      officialPlugins = import ./lib/official-plugins.nix { inherit lib; };
      # Pinned builds of the official ON-DEMAND bundles (published npm
      # releases): profiles may name them exactly like shipped bundles.
      officialPluginsFor = system:
        let
          pkgs = nixpkgs.legacyPackages.${system};
        in
        lib.genAttrs (lib.attrNames officialPlugins.pins) (name:
          pkgs.callPackage ./pkgs/official-plugin.nix (
            {
              npmName = name;
              fetchPnpmDeps = fetchPnpmDepsFor system;
            }
            // officialPlugins.pins.${name}
          ));
      # The official bundles shipped by the dsh installation: every package
      # under `packages/bundle/` and `packages/experimental/` that declares
      # `dsh.bundle.patch`.  Names resolve from the installation at runtime —
      # users reference them bare, with nothing to package.  Mirrors upstream
      # `PROFILE_TEMPLATES` app bundles plus `OPTIONAL_BUNDLES` (opt-in,
      # switched off by default in upstream templates).  The
      # `official-bundles` check fails on drift with the pinned dsh source.
      inBoxNames = [
        # App bundles (upstream profile templates).
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
      tui = import ./examples/profiles/tui.nix {
        inherit plugins profilesLib inBoxNames;
      };
      tui-spec = import ./examples/profiles/tui-spec.nix {
        inherit profilesLib inBoxNames;
      };
      web = import ./examples/profiles/web.nix {
        inherit profilesLib inBoxNames;
      };
      headless = import ./examples/profiles/headless.nix {
        inherit profilesLib inBoxNames;
      };

      profiles = {
        inherit
          tui
          tui-spec
          web
          headless
          ;
      };

      homeManagerModules.dsh = import ./modules/home-manager/dsh.nix {
        pluginsLib = plugins;
        inherit profilesLib inBoxNames;
        dshSrc = dsh;
        inherit fetchPnpmDepsFor officialPluginsFor;
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

          tui = profilesLib.buildProfileBundle {
            inherit pkgs;
            profile = profiles.tui;
          };

          tui-spec = profilesLib.buildProfileBundle {
            inherit pkgs;
            profile = profiles.tui-spec;
          };

          web = profilesLib.buildProfileBundle {
            inherit pkgs;
            profile = profiles.web;
          };

          headless = profilesLib.buildProfileBundle {
            inherit pkgs;
            profile = profiles.headless;
          };
        }
      );

      checks = forAllSystems (
        system:
        let
          pkgs = nixpkgs.legacyPackages.${system};
          tuiArtifact = self.packages.${system}.tui;
          tuiSpecArtifact = self.packages.${system}.tui-spec;
          expectedLayers = builtins.toJSON [ "@dsh-nix/tui-core" ];
        in
        {
          profile-tui =
            pkgs.runCommand "dsh-profile-tui-check"
              {
                nativeBuildInputs = [ pkgs.jq ];
              }
              ''
                package_json=${tuiArtifact}/package.json
                actual_layers=$(jq -c '.dsh.profile.bundles' "$package_json")
                expected_layers=${lib.escapeShellArg expectedLayers}
                test "$actual_layers" = "$expected_layers"

                test -L ${tuiArtifact}/node_modules/@dsh-nix/tui-core

                touch "$out"
              '';

          profile-tui-spec =
            pkgs.runCommand "dsh-profile-tui-spec-check"
              {
                nativeBuildInputs = [ pkgs.jq ];
              }
              ''
                package_json=${tuiSpecArtifact}/package.json
                actual_layers=$(jq -c '.dsh.profile.bundles' "$package_json")
                expected_layers=${lib.escapeShellArg expectedLayers}
                test "$actual_layers" = "$expected_layers"
                test -L ${tuiSpecArtifact}/node_modules/@dsh-nix/tui-core
                # New contract: exact-direct projection. The scope parent
                # is a real directory holding a single package link; the
                # old whole-scope symlink would leak siblings and collide
                # with same-scope Nix entries.
                test -d ${tuiSpecArtifact}/node_modules/@dsh-nix
                test ! -L ${tuiSpecArtifact}/node_modules/@dsh-nix

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
          # placed anywhere else in the tree.
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

          # Official on-demand pins must track the pinned dsh tag: the pinned
          # names equal the upstream ON_DEMAND_BUNDLES list, every pin version
          # equals the source version, and no pin ships discovery placeholders.
          # A tag bump that forgets lib/official-plugins.nix fails loud here.
          official-pins =
            pkgs.runCommand "dsh-official-pins-check"
              {
                nativeBuildInputs = [ pkgs.jq ];
                src = dsh;
                pins = builtins.toJSON (builtins.mapAttrs (_: p: {
                  inherit (p) version tarballHash depsHash;
                }) officialPlugins.pins);
              }
              ''
                version=$(jq -r .version "$src/apps/cli/package.json")
                upstream=$(sed -n '/ON_DEMAND_BUNDLES/,/\]/p' "$src/packages/boot/app-boot/src/official-bundle-packages.ts" \
                  | grep -oE "'@deepseek-ai/[^']+'" | tr -d "'" | sort)
                pinned=$(printf '%s\n' "$pins" | jq -r 'keys[]' | sort)
                if [ "$upstream" != "$pinned" ]; then
                  echo "official-pins: pinned names differ from upstream ON_DEMAND_BUNDLES" >&2
                  diff <(printf '%s\n' "$pinned") <(printf '%s\n' "$upstream") >&2 || true
                  exit 1
                fi
                printf '%s\n' "$pins" \
                  | jq -r 'to_entries[] | [.key, .value.version, .value.tarballHash, .value.depsHash] | @tsv' \
                  > "$TMPDIR/pins.tsv"
                while IFS=$'\t' read -r name pin_version tarball_hash deps_hash; do
                  if [ "$pin_version" != "$version" ]; then
                    echo "official-pins: $name pinned at $pin_version but the dsh source is $version; refresh lib/official-plugins.nix" >&2
                    exit 1
                  fi
                  case "$tarball_hash" in
                    sha512-*) : ;;
                    *) echo "official-pins: $name tarballHash is not a sha512 SRI" >&2; exit 1 ;;
                  esac
                  case "$deps_hash" in
                    sha256-*) : ;;
                    *) echo "official-pins: $name depsHash is not a sha256 SRI (still in discovery mode?)" >&2; exit 1 ;;
                  esac
                done < "$TMPDIR/pins.tsv"
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

          # Real-codex runtime gate: artifact shape (original assertions,
          # preserved) + ordered direct projection via the live FOD, lock
          # bytes retained, no auto-peer leakage, REAL transitive import,
          # exact signed-out bin oracles under a genuine rejecting
          # no-network guard (fresh HOME/XDG, pnpm-free PATH, DSH's own
          # private pnpm), packaged signed-out `dsh plugin exec`,
          # and an actual profile boot (checker + packaged rc.2, port 0).
          # No credential, session, or compaction API runs are claimed.
          profile-codex =
            let
              profile = import ./tests/fixtures/codex-profile.nix {
                inherit profilesLib inBoxNames;
              };
              artifact = profilesLib.buildProfileBundle { inherit pkgs profile; };
            in
            pkgs.runCommand "dsh-profile-codex-check"
              {
                nativeBuildInputs = [ pkgs.jq pkgs.nodejs pkgs.diffutils ];
                codexLock = ./tests/fixtures/codex-pnpm-lock.yaml;
                guard = ./tests/fixtures/no-net-guard.cjs;
              }
              ''
                set -euo pipefail
                work="$TMPDIR/codex"
                mkdir -p "$work"
                fail() { echo "profile-codex FAIL: $*" >&2; exit 1; }
                pass() { echo "profile-codex ok: $*"; }

                # --- original artifact-shape assertions (preserved) ---
                jq -e '.dsh.profile.bundles == ["@deepseek-ai/dsh-base", "@deepseek-ai/dsh-web-app", "dsh-codex"]' \
                  ${artifact}/package.json > /dev/null
                test -f ${artifact}/node_modules/dsh-codex/package.json
                jq -e '.[0].id == "llm-openai-codex" and .[0].config.searchMode == "live" and .[0].config.useNativeCompaction == true' \
                  ${artifact}/cordis.patch.yml > /dev/null
                pass "artifact shape (bundles, user layer)"

                # --- ordered direct projection via the live FOD ---
                fod=$(dirname $(dirname $(readlink ${artifact}/node_modules/dsh-codex)))
                jq -e '. == [{"spec":"dsh-codex@0.3.2","packageName":"dsh-codex"}]' \
                  "$fod/direct-specs.json" > /dev/null \
                  || fail "direct-specs not exactly the one declared spec"
                cmp "$fod/pnpm-lock.yaml" "$codexLock" \
                  || fail "FOD lock bytes differ from the committed lock"
                test -f "$fod/direct-specs.json" -a -f "$fod/pnpm-lock.yaml" \
                  || fail "FOD missing direct-specs.json/pnpm-lock.yaml"
                pass "ordered direct projection + lock bytes retained"
                [ "$(ls ${artifact}/node_modules)" = "dsh-codex" ] \
                  || fail "profile top level leaked beyond the direct spec"
                pass "no auto-peer leakage at profile top"

                # --- guard positive control (before trusting it below) ---
                ${pkgs.nodejs}/bin/node --require "$guard" --input-type=module -e \
                  "await fetch('http://example.com/')" 2>"$work/guard-proof.err" \
                  && fail "guard did not block fetch"
                grep -q 'NETWORK_FORBIDDEN' "$work/guard-proof.err" \
                  || fail "guard error signature missing"
                pass "no-network guard rejects egress"

                # --- real transitive import (not symlink shape) ---
                ${pkgs.nodejs}/bin/node --input-type=module -e "
                  const m = await import('${artifact}/node_modules/dsh-codex/lib/index.js');
                  const keys = Object.keys(m);
                  for (const k of ['loginOpenAICodex', 'openAICodexAuthStatus', 'diagnoseOpenAICodex']) {
                    if (!keys.includes(k)) { console.error('missing export ' + k); process.exit(1); }
                  }
                  console.log('IMPORT-OK ' + keys.length + ' keys');
                " > "$work/import.log" 2>&1 \
                  || { cat "$work/import.log" >&2; fail "real codex index import"; }
                grep -q '^IMPORT-OK' "$work/import.log" || fail "import marker missing"
                pass "real transitive index import ($(cat "$work/import.log"))"

                # --- bin oracles: fresh env, pnpm-free PATH, rejecting guard ---
                export HOME="$work/home"
                export XDG_DATA_HOME="$HOME/.local/share" XDG_STATE_HOME="$HOME/.local/state"
                export XDG_CONFIG_HOME="$HOME/.config" XDG_CACHE_HOME="$HOME/.cache"
                mkdir -p "$HOME" "$XDG_DATA_HOME" "$XDG_STATE_HOME" "$XDG_CONFIG_HOME" "$XDG_CACHE_HOME"
                if command -v pnpm > /dev/null 2>&1; then fail "ambient pnpm on PATH (must be pnpm-free)"; fi
                pass "parent PATH proven pnpm-free"
                run_bin() {
                  # run_bin <label> <args...> : env -i + guard, captures rc/out/err
                  label=$1; shift
                  if env -i PATH=${pkgs.nodejs}/bin:/usr/bin:/bin HOME="$HOME" \
                    XDG_DATA_HOME="$XDG_DATA_HOME" XDG_STATE_HOME="$XDG_STATE_HOME" \
                    XDG_CONFIG_HOME="$XDG_CONFIG_HOME" XDG_CACHE_HOME="$XDG_CACHE_HOME" \
                    NODE_OPTIONS="--require $guard" \
                    ${pkgs.nodejs}/bin/node ${artifact}/node_modules/dsh-codex/lib/bin.js "$@" \
                    > "$work/$label.out" 2> "$work/$label.err"; then
                    printf '0' > "$work/$label.rc"
                  else
                    printf '%s' "$?" > "$work/$label.rc"
                  fi
                }
                run_bin help --help
                [ "$(cat "$work/help.rc")" = "0" ] || fail "bin --help rc"
                grep -q 'Usage: dsh plugin --profile' "$work/help.out" || fail "bin --help text"
                pass "bin --help rc0 under guard"
                run_bin status status
                [ "$(cat "$work/status.rc")" = "1" ] || fail "status rc is not the exact signed-out rc1"
                [ "$(cat "$work/status.out")" = "OpenAI Codex: signed out" ] \
                  || fail "status exact signed-out text"
                grep -Eq 'ERR_MODULE_NOT_FOUND|Cannot find package|ERR_PNPM_RECURSIVE_EXEC_FIRST_FAIL|NETWORK_FORBIDDEN' "$work/status.out" "$work/status.err" \
                  && fail "status rc1 is an import/net error, not signed-out"
                pass "status rc1 exact signed-out (not import-error rc1)"
                run_bin status-json status --json
                [ "$(cat "$work/status-json.rc")" = "1" ] || fail "status --json rc"
                jq -e '. == {schemaVersion: 1, package: "dsh-codex", version: "0.3.2", status: "signed-out"}' \
                  "$work/status-json.out" > /dev/null \
                  || fail "status --json exact document"
                grep -Eq 'ERR_MODULE_NOT_FOUND|Cannot find package|ERR_PNPM_RECURSIVE_EXEC_FIRST_FAIL|NETWORK_FORBIDDEN' "$work/status-json.out" "$work/status-json.err" \
                  && fail "status --json hit import/pnpm/network error, not signed-out"
                pass "status --json rc1 exact signed-out document"
                # doctor rc1 here is the COMPATIBILITY mismatch
                # (dsh-llm/dsh-llm-pi-ai supported rc.1 vs installed rc.2),
                # NOT the missing credential: a missing file alone is not a
                # doctor failure. Assert the truthful report, never a fake
                # compatible success; compaction is not exercised at all.
                run_bin doctor-json doctor --json
                [ "$(cat "$work/doctor-json.rc")" = "1" ] || fail "doctor --json rc"
                jq -e '.credentialFile.state == "missing"' "$work/doctor-json.out" > /dev/null \
                  || fail "doctor credential state"
                jq -e '.compatibility.status == "incompatible"' "$work/doctor-json.out" > /dev/null \
                  || fail "doctor compatibility status (must stay incompatible)"
                jq -e '.compatibility.packages."@deepseek-ai/dsh-llm" == {supported: "0.2.0-rc.1", installed: "0.2.0-rc.2", status: "incompatible"}' \
                  "$work/doctor-json.out" > /dev/null \
                  || fail "doctor dsh-llm mismatch row"
                jq -e '.compatibility.packages."@deepseek-ai/dsh-llm-pi-ai" == {supported: "0.2.0-rc.1", installed: "0.2.0-rc.2", status: "incompatible"}' \
                  "$work/doctor-json.out" > /dev/null \
                  || fail "doctor dsh-llm-pi-ai mismatch row"
                jq -e '.compatibility.packages."@earendil-works/pi-ai" == {supported: "0.85.1", installed: "0.85.1", status: "compatible"}' \
                  "$work/doctor-json.out" > /dev/null \
                  || fail "doctor pi-ai row"
                pass "doctor --json rc1 truthful incompatibility report"
                test ! -e "$HOME/.dsh" || fail "bin runs created .dsh in fresh HOME"
                pass "bin/index create no .dsh under fresh HOME"

                # --- packaged `dsh plugin exec` (genuine managed-profile path) ---
                # The managed profile is resolved under HOME/.dsh; the wrapper
                # supplies private pnpm. Its generated bin shim also needs sed.
                # A signed-out status returns rc1 and the exact JSON document,
                # with the CLI's normal nonzero-command diagnostic on stderr.
                execHome="$work/exec-home"
                mkdir -p "$execHome/.dsh/profiles"
                cp -a ${artifact} "$execHome/.dsh/profiles/codex"
                chmod -R u+w "$execHome/.dsh/profiles/codex"
                if env -i PATH=${pkgs.nodejs}/bin:${pkgs.coreutils}/bin:${pkgs.gnused}/bin:/usr/bin:/bin HOME="$execHome" \
                  XDG_DATA_HOME="$execHome/.local/share" XDG_STATE_HOME="$execHome/.local/state" \
                  XDG_CONFIG_HOME="$execHome/.config" XDG_CACHE_HOME="$execHome/.cache" \
                  NODE_OPTIONS="--require $guard" \
                  ${self.packages.${system}.dsh}/bin/dsh plugin --profile codex exec dsh-codex status --json \
                  > "$work/exec.out" 2> "$work/exec.err"; then
                  fail "dsh plugin exec unexpectedly rc0 (signed-out status is rc1)"
                else
                  [ "$?" = "1" ] || fail "exec rc is not the signed-out rc1"
                fi
                grep -q 'Already up to date' "$work/exec.out" \
                  || fail "exec stdout lacks the private-pnpm up-to-date line"
                grep -q 'using pnpm v' "$work/exec.out" \
                  || fail "exec stdout lacks the private-pnpm signature"
                grep -E '^\{"schemaVersion":1,"package":"dsh-codex","version":"0\.3\.2","status":"signed-out"\}$' "$work/exec.out" \
                  > /dev/null || { echo "--- exec.out begin ---" >&2; cat "$work/exec.out" >&2; echo "--- exec.out end ---" >&2; echo "--- exec.err begin ---" >&2; cat "$work/exec.err" >&2; echo "--- exec.err end ---" >&2; fail "exec stdout lacks the exact signed-out document line"; }
                grep -Eq 'ERR_MODULE_NOT_FOUND|Cannot find package|ERR_PNPM_RECURSIVE_EXEC_FIRST_FAIL|NETWORK_FORBIDDEN' "$work/exec.out" "$work/exec.err" \
                  && fail "exec hit import/pnpm/network error, not signed-out"
                grep -q 'dsh: plugin command failed; diagnostics:' "$work/exec.err" \
                  || fail "exec stderr lacks the expected rc1 diagnostic line"
                pass "dsh plugin exec rc1 exact signed-out via private pnpm"
                # the SOURCE artifact is untouched (exec mutates only the copy)
                jq -e '.dsh.profile.bundles == ["@deepseek-ai/dsh-base", "@deepseek-ai/dsh-web-app", "dsh-codex"]' \
                  ${artifact}/package.json > /dev/null \
                  || fail "source artifact mutated"
                test -L ${artifact}/node_modules/dsh-codex || fail "source artifact link disturbed"
                pass "source artifact immutable"

                # --- actual profile boot (checker + packaged rc.2, port 0) ---
                bootHome="$work/boot-home"
                mkdir -p "$bootHome/profiles"
                cp -a ${artifact} "$bootHome/profiles/codex"
                chmod -R u+w "$bootHome/profiles/codex"
                if ! env -i PATH=${pkgs.nodejs}/bin:/usr/bin:/bin HOME="$bootHome" \
                  NODE_OPTIONS="--require $guard" \
                  ${pkgs.nodejs}/bin/node --expose-internals \
                  --require ${self.packages.${system}.dsh}/lib/dsh-builtin-compat.cjs \
                  ${./scripts/check-profile.mjs} \
                  ${self.packages.${system}.dsh} codex "$bootHome" --port 0 --no-open \
                  > "$work/boot.log" 2>&1; then
                  cat "$work/boot.log" >&2
                  fail "codex profile boot (module import was green; app boot must be too)"
                fi
                grep -q '^CHECK-OK$' "$work/boot.log" || fail "boot lacks CHECK-OK"
                pass "codex profile boot CHECK-OK under guard"

                mkdir -p "$out"
                printf 'CODEX-ARTIFACT-OK %s\n' ${artifact} > "$out/marker"
                cp "$work/status-json.out" "$work/doctor-json.out" "$work/boot.log" "$out/"
              '';

          # Spec-lock regression: evaluated validator-unit battery and
          # actual ordered-profile/transitive-closure artifact checks.
          profile-spec-lock = (import ./tests/spec-lock.nix { inherit pkgs; }).check;

          profile-boot-tui =
            pkgs.runCommand "dsh-profile-boot-tui-check" { nativeBuildInputs = [ pkgs.nodejs ]; } ''
              export HOME="$TMPDIR/home"
              home="$HOME/.dsh"
              mkdir -p "$home/profiles"
              cp -a ${self.packages.${system}.tui} "$home/profiles/tui"
              chmod -R u+w "$home/profiles/tui"
              if ! ${pkgs.nodejs}/bin/node --expose-internals \
                --require ${self.packages.${system}.dsh}/lib/dsh-builtin-compat.cjs \
                ${./scripts/check-profile.mjs} \
                ${self.packages.${system}.dsh} tui "$home" \
                > "$TMPDIR/check.log" 2>&1; then
                cat "$TMPDIR/check.log" >&2
                exit 1
              fi
              grep -q '^CHECK-OK$' "$TMPDIR/check.log"
              printf 'activated\ndisposed\n' > "$TMPDIR/expected-lifecycle"
              cmp "$TMPDIR/expected-lifecycle" "$home/tui-fixture-lifecycle.log"
              mkdir -p "$out"
              cp "$home/tui-fixture-lifecycle.log" "$out/lifecycle"
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

          # Opt-in official bundles need no packaging: base + web-app plus two
          # experimental layers (session-search, the worktree tool) must boot
          # exactly like the plain web profile.
          profile-boot-experimental =
            let
              profile = profilesLib.mkProfileBundle {
                name = "experimental";
                plugins = [
                  "@deepseek-ai/dsh-base"
                  "@deepseek-ai/dsh-web-app"
                  "@deepseek-ai/dsh-experimental-session-search"
                  "@deepseek-ai/dsh-experimental-tool-worktree"
                ];
                inherit inBoxNames;
              };
              artifact = profilesLib.buildProfileBundle { inherit pkgs profile; };
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
                # Composition is exact: all four declared layers, order kept.
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
                # A dropped opt-in layer would still let the boot pass; assert
                # the launcher reported no skipped bundle.
                if grep -q 'skipping profile bundle' "$TMPDIR/check.log"; then
                  cat "$TMPDIR/check.log" >&2
                  exit 1
                fi
                touch "$out"
              '';

          # Official kernel plugins mount without packaging: a patch row in
          # the profile's own layer names the package and the name resolves
          # from the dsh installation (no bundle, no Nix package).  base +
          # web-app + one official tool plugin (str-replace-editor, not part
          # of any shipped bundle) must compose the row and boot CHECK-OK.
          profile-official-plugin =
            let
              profile = profilesLib.mkProfileBundle {
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
              artifact = profilesLib.buildProfileBundle { inherit pkgs profile; };
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

          # Official ON-DEMAND bundles by name: dsh-subagent-codex and
          # dsh-subagent-claude-code are not in the installation, so dsh-nix
          # builds them from their pinned npm releases (official/ pins).  The
          # profile links them like Nix-package plugins and boots with no
          # skipped bundle.
          profile-official-on-demand =
            let
              profile = profilesLib.mkProfileBundle {
                name = "official-on-demand";
                plugins = [
                  "@deepseek-ai/dsh-base"
                  "@deepseek-ai/dsh-web-app"
                  "@deepseek-ai/dsh-subagent-codex"
                  "@deepseek-ai/dsh-subagent-claude-code"
                ];
                officialPlugins = officialPluginsFor system;
                inherit inBoxNames;
              };
              artifact = profilesLib.buildProfileBundle { inherit pkgs profile; };
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
