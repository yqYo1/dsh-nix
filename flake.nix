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
  inputs.systems.url = "github:nix-systems/default";
  # Regression tests use real Home Manager, not replicated option stubs.
  inputs.home-manager = {
    url = "github:nix-community/home-manager/d9d750e4fc11c10cab2da677bdd31e427f3a3a71";
    inputs.nixpkgs.follows = "nixpkgs";
  };
  inputs.dsh = {
    url = "github:deepseek-ai/deepseek-harness/dsh-v0.2.0-rc.2";
    flake = false;
  };

  outputs =
    {
      self,
      nixpkgs,
      systems,
      home-manager,
      dsh,
    }:
    let
      lib = nixpkgs.lib;
      supportedSystems = import systems;
      forAllSystems = f: lib.genAttrs supportedSystems (system: f system);

      plugins = import ./lib/plugins.nix { inherit lib; };
      profilesLib = import ./lib/profiles.nix { inherit lib; };
      inBoxNames = [
        "@deepseek-ai/dsh-base"
        "@deepseek-ai/dsh-web-app"
        "@deepseek-ai/dsh-headless"
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
      };

      # `pkgs.dsh` for any consumer applying the overlay.
      overlay = final: prev: {
        dsh = final.callPackage ./pkgs/dsh.nix { src = dsh; };
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
        in
        {
          dsh = pkgs.callPackage ./pkgs/dsh.nix { src = dsh; };

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
                test -L ${tuiSpecArtifact}/node_modules/@dsh-nix

                touch "$out"
              '';

          boot-checker-wiring = import ./tests/boot-checker.nix { inherit pkgs; };

          home-manager-integration = (import ./tests/hm-real.nix {
            inherit pkgs;
            hmPath = home-manager;
          }).check;

          profile-regression = (import ./tests/profile-regression.nix { inherit pkgs; }).check;

          profile-codex =
            let
              profile = import ./tests/fixtures/codex-profile.nix {
                inherit profilesLib inBoxNames;
              };
              artifact = profilesLib.buildProfileBundle { inherit pkgs profile; };
            in
            pkgs.runCommand "dsh-profile-codex-check" { nativeBuildInputs = [ pkgs.jq ]; } ''
              jq -e '.dsh.profile.bundles == ["@deepseek-ai/dsh-base", "@deepseek-ai/dsh-web-app", "dsh-codex"]' \
                ${artifact}/package.json > /dev/null
              test -f ${artifact}/node_modules/dsh-codex/package.json
              jq -e '.[0].id == "llm-openai-codex" and .[0].config.searchMode == "live" and .[0].config.useNativeCompaction == true' \
                ${artifact}/cordis.patch.yml > /dev/null
              mkdir -p "$out"
              printf 'CODEX-ARTIFACT-OK %s\n' ${artifact} > "$out/marker"
            '';

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
          # boot() (which runs assertEntriesActivated) and dispose.  A
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
                  ${self.packages.${system}.dsh} web "$home" --port 0 \
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
                # rc.2 starts the one-shot runner during apply, without
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
                  ${self.packages.${system}.dsh} web-nobase "$home" --port 0 \
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
