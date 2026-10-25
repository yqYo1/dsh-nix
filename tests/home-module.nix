# Self-test for modules/home-manager/dsh.nix: evaluate the module with stub
# home-manager options and assert composition, activation content, and the
# install-exactly contract. Run: nix-instantiate --eval --strict --json
#   tests/home-module.nix --arg pkgs 'import <nixpkgs> {}'
# (or via the root flake check: nix build .#checks.<system>.home-module)
{ pkgs }:

let
  lib = pkgs.lib;
  pluginsLib = import ../lib/plugins.nix { inherit lib; };
  profilesLib = import ../lib/profiles.nix { inherit lib; };
  module = import ../modules/home-manager/dsh.nix {
    inherit pluginsLib profilesLib;
    inBoxNames = [ "@deepseek-ai/dsh-base" "@deepseek-ai/dsh-web-app" "@deepseek-ai/dsh-experimental-session-search" ];
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
          # Eval-only spec profile: proves the module accepts a
          # lock-pinned spec composition (specsLock + specsHash thread
          # through to the declaration). Never built here: this gate is
          # evaluation-only (nix-instantiate --eval, no builds), so the
          # FOD hash stays discovery-blank.
          profiles.agent-spec = {
            plugins = [ "dsh-codex@0.3.2" ];
            userPatches = [ ];
            specsLock = ./fixtures/codex-pnpm-lock.yaml;
            specsHash = "";
          };
        };
      }
    ];
    specialArgs = { inherit pkgs; };
  };

  config = evaluated.config;
  activationValue = config.home.activation.dshProfiles or "";
  activation = if builtins.isString activationValue then activationValue else activationValue.data;

  # Template mode: the shipped templates are installed by default without
  # listing their bundles, a profile can extend one with extraPlugins, and
  # enable = false removes one.  A template name with `plugins` is a full
  # custom profile instead.
  templateModule = import ../modules/home-manager/dsh.nix {
    inherit pluginsLib profilesLib;
    inBoxNames = [ "@deepseek-ai/dsh-base" "@deepseek-ai/dsh-web-app" "@deepseek-ai/dsh-experimental-session-search" ];
    profileTemplates = [ "headless" "web" ];
    dshSrc = null;
  };
  templateEvaluated = lib.evalModules {
    modules = [
      stub
      templateModule
      {
        programs.dsh = {
          enable = true;
          package = externalPackage;
          profiles.web.extraPlugins = [ "@deepseek-ai/dsh-experimental-session-search" ];
          profiles.headless.enable = false;
        };
      }
    ];
    specialArgs = { inherit pkgs; };
  };
  templateConfig = templateEvaluated.config;
  templateActivationValue = templateConfig.home.activation.dshProfiles or "";
  templateActivation =
    if builtins.isString templateActivationValue then templateActivationValue else templateActivationValue.data;
  templateProfiles = lib.attrNames templateConfig.programs.dsh.profiles;
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
    (lib.hasInfix "\"$HOME/.dsh/profiles\"/agent-spec" activation)
    (lib.hasInfix "dsh-profile-agent-spec" activation)
    # Removed profiles are cleaned: manifest tracks managed names.
    (lib.hasInfix ".dsh-nix-managed-profiles" activation)
    # The CLI installs EXACTLY unmodified: derivation identity, not shape.
    (builtins.length config.home.packages == 1)
    (builtins.head config.home.packages == externalPackage)
    ((builtins.head config.home.packages).outPath == externalPackage.outPath)
    # Shipped templates are declared by default and individually removable.
    (templateProfiles == [ "headless" "web" ])
    (lib.hasInfix "\"$HOME/.dsh/profiles\"/web" templateActivation)
    (lib.hasInfix "\"$HOME/.dsh/profiles\"/headless" templateActivation == false)
    # Extending a template keeps it materialised (the extra bundle is part of
    # its declaration, not a separate profile).
    (lib.hasInfix "dsh-profile-web" templateActivation)
  ];
  all = lib.all (x: x) [
    (lib.hasAttr ".dsh/cordis.patch.yml" config.home.file == false)
    (lib.hasInfix "\"$HOME/.dsh/profiles\"/agent" activation)
    (lib.hasInfix "/'" activation == false)
    (lib.hasInfix ".dsh-nix-stamp" activation)
    (lib.hasInfix "dsh-profile-agent" activation)
    (lib.hasInfix "\"$HOME/.dsh/profiles\"/agent-spec" activation)
    (lib.hasInfix "dsh-profile-agent-spec" activation)
    (lib.hasInfix ".dsh-nix-managed-profiles" activation)
    (builtins.length config.home.packages == 1)
    (builtins.head config.home.packages == externalPackage)
    ((builtins.head config.home.packages).outPath == externalPackage.outPath)
    (templateProfiles == [ "headless" "web" ])
    (lib.hasInfix "\"$HOME/.dsh/profiles\"/web" templateActivation)
    (lib.hasInfix "\"$HOME/.dsh/profiles\"/headless" templateActivation == false)
    (lib.hasInfix "dsh-profile-web" templateActivation)
  ];
}
