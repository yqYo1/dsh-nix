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
  inputs.treefmt-nix = {
    url = "github:numtide/treefmt-nix";
    inputs.nixpkgs.follows = "nixpkgs";
  };
  inputs.dsh = {
    url = "github:deepseek-ai/deepseek-harness/dsh-v0.2.2-rc.3";
    flake = false;
  };

  outputs =
    {
      self,
      nixpkgs,
      nixpkgs-fetch,
      systems,
      treefmt-nix,
      dsh,
    }:
    let
      inherit (nixpkgs) lib;
      # Official support is Linux-only; Darwin is not built or tested here.
      supportedSystems = lib.filter (system: lib.hasSuffix "linux" system) (import systems);
      forAllSystems = f: lib.genAttrs supportedSystems f;
      treefmtEval = forAllSystems (
        system: treefmt-nix.lib.evalModule nixpkgs.legacyPackages.${system} ./treefmt.nix
      );

      # The one fetch support every dsh build uses.  The pnpm-deps FOD's
      # hash is bound to `fetchPnpmDeps`' script text, so it must never be
      # instantiated from a consumer-mutable nixpkgs.
      fetchPnpmDepsFor = system: nixpkgs-fetch.legacyPackages.${system}.fetchPnpmDeps;

      plugins = import ./lib/plugins.nix { inherit lib; };
      profilesLib = import ./lib/profiles.nix { inherit lib; };
      officialBundles = import ./lib/official-bundles.nix;

      # The official on-demand bundles are not installation dependencies, but
      # the pinned dsh source still contains and builds them.  Profile builds
      # link the installed package directly, so no npm fetch, version pin,
      # lockfile, or pnpm-store hash is maintained separately.
      onDemandBundles = officialBundles.onDemand;

      # The official bundles shipped by the dsh installation: every bundle in
      # the shipped profile templates plus the shipped optional bundles.
      # Mirrors upstream PROFILE_TEMPLATES + OPTIONAL_BUNDLES; the
      # `official-bundles` check fails on drift with the pinned source.
      inBoxNames = lib.unique (
        lib.concatLists (lib.attrValues officialBundles.profileTemplates) ++ officialBundles.optional
      );

      # Shipped profile templates (dsh `PROFILE_TEMPLATES`).  The module
      # installs one profile per name by default; the bundles come from the
      # dsh installation at build time, never from user configuration.
      profileTemplates = lib.attrNames officialBundles.profileTemplates;

      homeManagerModules.dsh = import ./modules/home-manager/dsh.nix {
        inherit
          profilesLib
          inBoxNames
          profileTemplates
          onDemandBundles
          ;
        buildPkgsFor = system: nixpkgs.legacyPackages.${system};
        dshPackageFor = system: self.packages.${system}.dsh;
        dshSrc = dsh;
        inherit fetchPnpmDepsFor;
      };

      # `pkgs.dsh` for any consumer applying the overlay.  The deps FOD is
      # built from the pinned fetch support so this path keeps the hash
      # valid under consumer nixpkgs overrides.
      overlay = final: _prev: {
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
        officialBundles
        homeManagerModules
        ;
      inherit overlay;

      overlays.default = overlay;

      # Convenience: importing this NixOS module wires the overlay into
      # nixpkgs, so `pkgs.dsh` resolves everywhere on the system.
      nixosModules.default = _: {
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

        }
      );

      formatter = forAllSystems (system: treefmtEval.${system}.config.build.wrapper);

      # Non-test checks only: formatting and version lockstep.  All
      # test/profile checks live in the tests subflake (tests/checks.nix,
      # owned by tests/flake.nix); test-only dependencies are owned there,
      # not by this closure.
      checks = forAllSystems (
        system:
        let
          pkgs = nixpkgs.legacyPackages.${system};
        in
        {
          # treefmt-nix: Nix/shell/JS/YAML/Markdown formatting; shellcheck,
          # actionlint, statix and deadnix are configured in treefmt.nix.
          treefmt = treefmtEval.${system}.config.build.check self;

          # Keep the user-visible version labels and the pinned input in
          # lockstep.  The package version is the source of truth; a tag
          # update that forgets the README fails here.
          version-consistency =
            pkgs.runCommand "dsh-version-consistency-check"
              {
                nativeBuildInputs = [ pkgs.gnugrep ];
                package = ./pkgs/dsh.nix;
                rootFlake = ./flake.nix;
                readme = ./README.md;
              }
              ''
                version=$(sed -n 's/^[[:space:]]*version = "\([^"]*\)";/\1/p' "$package")
                test -n "$version" || { echo "version-consistency: package version missing" >&2; exit 1; }
                grep -Fq "dsh-v$version" "$rootFlake" \
                  || { echo "version-consistency: flake input tag != package version $version" >&2; exit 1; }
                grep -Fq "current package is \`$version\`" "$readme" \
                  || { echo "version-consistency: README version != package version $version" >&2; exit 1; }
                echo "version consistency: $version"
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
              treefmtEval.${system}.config.build.wrapper
            ];
          };
        }
      );
    };
}
