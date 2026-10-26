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
            plugins = [ "@deepseek-ai/dsh-base" ../examples/plugins/lifecycle-probe ];
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

  # Template profiles are separate from user profiles: templates are enabled
  # by default and can be extended in place; a user profile may reuse a
  # template's name only after disabling it; `extends` works while disabled.
  templateFactory = import ../modules/home-manager/dsh.nix {
    inherit pluginsLib profilesLib;
    inBoxNames = [ "@deepseek-ai/dsh-base" "@deepseek-ai/dsh-web-app" "@deepseek-ai/dsh-experimental-session-search" ];
    profileTemplates = [ "headless" "web" ];
    dshSrc = null;
  };
  evalWith = extra: (lib.evalModules {
    modules = [
      stub
      templateFactory
      {
        programs.dsh = { enable = true; package = externalPackage; } // extra;
      }
    ];
    specialArgs = { inherit pkgs; };
  }).config;
  activationOf = config:
    let value = config.home.activation.dshProfiles or ""; in
    if builtins.isString value then value else value.data;

  templateConfig = evalWith {
    templates.web.extraPlugins = [ "@deepseek-ai/dsh-experimental-session-search" ];
    templates.headless.enable = false;
  };
  customConfig = evalWith {
    templates.web.enable = false;
    profiles.web = { plugins = [ "@deepseek-ai/dsh-base" ]; };
  };
  extendsConfig = evalWith {
    templates.web.enable = false;
    profiles.research = {
      extends = "web";
      extraPlugins = [ "@deepseek-ai/dsh-experimental-session-search" ];
    };
  };
  clash = builtins.tryEval (builtins.deepSeq
    (evalWith { profiles.web = { plugins = [ "@deepseek-ai/dsh-base" ]; }; }).home.activation.dshProfiles
    true);
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
    # Shipped templates are declared by default and individually removable.
    (lib.attrNames templateConfig.programs.dsh.templates == [ "headless" "web" ])
    (lib.hasInfix "\"$HOME/.dsh/profiles\"/web" (activationOf templateConfig))
    (lib.hasInfix "\"$HOME/.dsh/profiles\"/headless" (activationOf templateConfig) == false)
    # Extending a template in place keeps the web profile.
    (lib.hasInfix "dsh-profile-web" (activationOf templateConfig))
    # A user profile may reuse a disabled template's name ...
    (lib.hasInfix "\"$HOME/.dsh/profiles\"/web" (activationOf customConfig))
    # ... or extend a disabled template under another name.
    (lib.hasInfix "\"$HOME/.dsh/profiles\"/research" (activationOf extendsConfig))
    (lib.hasInfix "\"$HOME/.dsh/profiles\"/web" (activationOf extendsConfig) == false)
    # Enabling a template and defining a profile of the same name clash.
    (clash.success == false)
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
    (lib.attrNames templateConfig.programs.dsh.templates == [ "headless" "web" ])
    (lib.hasInfix "\"$HOME/.dsh/profiles\"/web" (activationOf templateConfig))
    (lib.hasInfix "\"$HOME/.dsh/profiles\"/headless" (activationOf templateConfig) == false)
    (lib.hasInfix "dsh-profile-web" (activationOf templateConfig))
    (lib.hasInfix "\"$HOME/.dsh/profiles\"/web" (activationOf customConfig))
    (lib.hasInfix "\"$HOME/.dsh/profiles\"/research" (activationOf extendsConfig))
    (lib.hasInfix "\"$HOME/.dsh/profiles\"/web" (activationOf extendsConfig) == false)
    (clash.success == false)
  ];
}
