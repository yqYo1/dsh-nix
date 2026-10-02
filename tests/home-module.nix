# Self-test for modules/home-manager/dsh.nix: evaluate the module with stub
# home-manager options and assert composition, activation content, and the
# install-exactly contract. Run: nix-instantiate --eval --strict --json
#   tests/home-module.nix --arg pkgs 'import <nixpkgs> {}'
# (or via nix develop -c; see tests/hm-activation-contract.sh)
{ pkgs }:

let
  lib = pkgs.lib;
  pluginsLib = import ../lib/plugins.nix { inherit lib; };
  profilesLib = import ../lib/profiles.nix { inherit lib; };
  module = import ../modules/home-manager/dsh.nix {
    inherit pluginsLib profilesLib;
    inBoxNames = [ "@deepseek-ai/dsh-base" "@deepseek-ai/dsh-web-app" ];
    dshSrc = null;
  };

  stub = { lib, ... }: {
    options.home.packages = lib.mkOption { type = lib.types.listOf lib.types.package; default = [ ]; };
    options.home.file = lib.mkOption { type = lib.types.attrs; default = { }; };
    options.home.activation = lib.mkOption { type = lib.types.attrs; default = { }; };
  };

  # An external package the module must install EXACTLY (no wrapping): the
  # regression proof is derivation identity below, not just list length.
  externalPackage = pkgs.writeText "dsh-external-dummy" "external";

  evaluated = lib.evalModules {
    modules = [
      stub
      module
      {
        programs.dsh = {
          enable = true;
          package = externalPackage;
          homePatchesFile = null;
          profiles.agent = {
            plugins = [ "@deepseek-ai/dsh-base" ../examples/plugins/tui-core ];
            userPatches = [ ];
          };
        };
      }
    ];
    specialArgs = { inherit pkgs; };
  };

  config = evaluated.config;
  activationValue = config.home.activation.dshProfiles or "";
  activation = if builtins.isString activationValue then activationValue else activationValue.data;
in
{
  checks = [
    # No machine layer configured: no home.file entry for it.
    (lib.hasAttr ".dsh/cordis.patch.yml" config.home.file == false)
    # Real directory layout: $HOME-anchored, no literal quote characters
    # baked into profile paths (regression: "$HOME/.../'agent'" from
    # escapeShellArg interpolated inside double quotes).
    (lib.hasInfix "\"$HOME/.dsh/profiles\"/agent" activation)
    (lib.hasInfix "/'" activation == false)
    (lib.hasInfix ".dsh-nix-stamp" activation)
    (lib.hasInfix "dsh-profile-agent" activation)
    # Removed profiles are cleaned: manifest tracks managed names.
    (lib.hasInfix ".dsh-nix-managed-profiles" activation)
    # The CLI installs EXACTLY unmodified: derivation identity, not shape.
    (builtins.length config.home.packages == 1)
    (builtins.head config.home.packages == externalPackage)
    ((builtins.head config.home.packages).outPath == externalPackage.outPath)
  ];
  all = lib.all (x: x) [
    (lib.hasAttr ".dsh/cordis.patch.yml" config.home.file == false)
    (lib.hasInfix "\"$HOME/.dsh/profiles\"/agent" activation)
    (lib.hasInfix "/'" activation == false)
    (lib.hasInfix ".dsh-nix-stamp" activation)
    (lib.hasInfix "dsh-profile-agent" activation)
    (lib.hasInfix ".dsh-nix-managed-profiles" activation)
    (builtins.length config.home.packages == 1)
    (builtins.head config.home.packages == externalPackage)
    ((builtins.head config.home.packages).outPath == externalPackage.outPath)
  ];
}
