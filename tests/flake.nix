{
  description = "Test-only Home Manager harness for dsh-nix (dev-flake separation a la catppuccin/nix)";

  nixConfig = {
    extra-substituters = [
      "https://yqyo1.cachix.org"
    ];
    extra-trusted-public-keys = [
      "yqyo1.cachix.org-1:8v2GAv9lm0AURGOHo92N4+lgAhVE0+v8ou3DFT7hDEg="
    ];
  };

  # WARN: `path:../.` needs Nix >= 2.26 for correct relative-path handling
  # in flakes (cf. catppuccin/nix dev/flake.nix).
  inputs.dsh-nix.url = "path:../.";
  inputs.nixpkgs.follows = "dsh-nix/nixpkgs";
  inputs.home-manager = {
    url = "github:nix-community/home-manager/d9d750e4fc11c10cab2da677bdd31e427f3a3a71";
    inputs.nixpkgs.follows = "nixpkgs";
  };

  outputs =
    {
      self,
      dsh-nix,
      nixpkgs,
      home-manager,
      ...
    }:
    let
      lib = nixpkgs.lib;
      # Supported systems always track the parent flake — no flake-utils,
      # no independent systems pin.
      supportedSystems = import dsh-nix.inputs.systems;
      forAllSystems = f: lib.genAttrs supportedSystems (system: f system);
    in
    {
      checks = forAllSystems (
        system:
        let
          pkgs = nixpkgs.legacyPackages.${system};
        in
        {
          # NOTE: the test file itself (tests/hm-real.nix) is unchanged and
          # is reached through the parent source tree (dsh-nix.outPath), not
          # a literal ./hm-real.nix: a subflake source tree contains only
          # tests/, so the test's own ../lib, ../modules and ../examples
          # imports would escape the flake boundary under pure evaluation.
          # Importing the identical file via the path input keeps every
          # relative import inside the parent tree.
          home-manager-integration = (import (dsh-nix.outPath + "/tests/hm-real.nix") {
            inherit pkgs;
            hmPath = home-manager;
          }).check;

          test-flake-contract = import ./test-flake-contract.nix {
            inherit pkgs lib system nixpkgs;
            dshNix = dsh-nix;
            rootSrc = dsh-nix.outPath;
            testsLock = builtins.fromJSON (builtins.readFile ./flake.lock);
          };
        }
      );

      devShells = forAllSystems (
        system:
        let
          pkgs = nixpkgs.legacyPackages.${system};
        in
        {
          default = pkgs.mkShell {
            inputsFrom = [ dsh-nix.devShells.${system}.default ];
            packages = with pkgs; [
              bash
              jq
              nix
            ];
          };
        }
      );
    };
}
