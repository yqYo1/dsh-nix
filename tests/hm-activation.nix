# Extract the Home Manager module's activation script and artifact paths for
# a realistic end-to-end run: evaluate the module with stubs, print
# activation to stdout and artifact store paths. Not part of flake checks.
#
# Optional args drive multi-generation scenarios (config refresh, plugin
# removal, profile removal) for tests/hm-activation-contract.sh:
#   profiles  attrset of profile declarations; each value accepts
#             { plugins, userPatches ?, userPatchesFile ?, specsHash ?, specsLock ? }
#   settings  seed-only settings.yaml content
#   homePatchesFile  machine-level patch layer path or null
{ pkgs
, profiles ? {
    agent.plugins = [ "@deepseek-ai/dsh-base" ../examples/plugins/tui-core ];
  }
, settings ? { }
, homePatchesFile ? null
}:

let
  lib = pkgs.lib;
  pluginsLib = import ../lib/plugins.nix { inherit lib; };
  profilesLib = import ../lib/profiles.nix { inherit lib; };
  inBoxNames = [ "@deepseek-ai/dsh-base" "@deepseek-ai/dsh-web-app" ];
  module = import ../modules/home-manager/dsh.nix {
    inherit pluginsLib profilesLib inBoxNames;
    dshSrc = null;
  };
  stub = { lib, ... }: {
    options.home.packages = lib.mkOption { type = lib.types.listOf lib.types.package; default = [ ]; };
    options.home.file = lib.mkOption { type = lib.types.attrs; default = { }; };
    options.home.activation = lib.mkOption { type = lib.types.attrs; default = { }; };
  };
  profileDefaults = {
    plugins = [ ];
    userPatchesFile = null;
    userPatches = [ ];
    specsHash = "";
    # Threaded (not dropped): a lock-bearing caller profile must reach
    # mkProfileBundle intact, never silently fall back to live resolve.
    specsLock = null;
  };
  normalized = lib.mapAttrs (name: p: profileDefaults // (if builtins.isAttrs p then p else { plugins = p; })) profiles;
  cfg = {
    programs.dsh = {
      enable = true;
      package = pkgs.writeText "dsh-dummy" "dummy";
      profiles = normalized;
      inherit settings homePatchesFile;
    };
  };
  evaluated = lib.evalModules {
    modules = [ stub module cfg ];
    specialArgs = { inherit pkgs; };
  };

  declarations = lib.mapAttrs (name: p:
    profilesLib.mkProfileBundle {
      inherit name;
      inherit (p) plugins userPatchesFile userPatches specsHash specsLock;
      inherit inBoxNames;
    }) normalized;
  artifacts = lib.mapAttrs (name: d: profilesLib.buildProfileBundle { inherit pkgs; profile = d; }) declarations;

  activationValue = evaluated.config.home.activation.dshProfiles;
  activation = if builtins.isString activationValue then activationValue else activationValue.data;
in
{
  inherit activation artifacts;
  artifact = artifacts.agent;
  package = evaluated.config.home.packages;
  files = evaluated.config.home.file;
}
