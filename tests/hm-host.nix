# Host E2E fixture: TESTS-flake-pinned real Home Manager activation of the
# REAL packaged dsh, with zero Nix-CLI shims and zero faked success.
#
# Evaluated by scripts/hm-e2e.sh with the real Nix CLI. The caller passes
# the pinned input sources from the tests subflake (builtins.getFlake
# "git+file://$repo_root?dir=tests"), so the whole repository is the source
# root and the public flake stays Home Manager-independent:
#   import ./tests/hm-host.nix {
#     pkgsPath = <tests-flake inputs.nixpkgs.outPath>;  # follows dsh-nix/nixpkgs
#     hmPath   = <tests-flake inputs.home-manager.outPath>;
#     dshSrc   = <tests-flake inputs.dsh-nix.inputs.dsh>;  # whole input: carries .rev
#     system username homeDirectory
#   }
# (This fixture file itself is still imported relative to the repo checkout,
# exactly as before.)
#
# The script drives this fixture in two stages. First an evaluation-only
# gate: it asserts `checks` and reads `activationDrvPath` / expected
# artifact paths as store-path STRINGS (toString never realises). Then the
# real stage: the same fixture's `generation` builds for real (the dsh
# package hash is a real pinned hash) and its ./activate runs with
# driver 0 (default): `nix-env --profile $XDG_STATE_HOME/nix/profiles/
# home-manager --set` performs the profile install owned by pinned Home
# Manager, and `nix-env -i home-manager-path` installs cfg.package.
#
# The single `agent` profile uses ONLY examples/plugins/tui-core (a plain
# path plugin: no in-box bundles, no network) whose apply()
# appends `activated` and whose dispose appends `disposed` to
# $DSH_HOME/tui-fixture-lifecycle.log.
#
{ pkgsPath
, hmPath
, dshSrc
, system
, username
, homeDirectory
}:

let
  pkgs = import pkgsPath { inherit system; };
  lib = pkgs.lib;
  hmLib = import (hmPath + "/lib") { inherit lib; };
  pluginsLib = import ../lib/plugins.nix { inherit lib; };
  profilesLib = import ../lib/profiles.nix { inherit lib; };
  inBoxNames = [
    "@deepseek-ai/dsh-base"
    "@deepseek-ai/dsh-web-app"
    "@deepseek-ai/dsh-headless"
  ];
  dshModule = import ../modules/home-manager/dsh.nix {
    inherit pluginsLib profilesLib inBoxNames dshSrc;
  };

  # Real third-party plugin packaged as a Nix derivation (the user route):
  # the fixture builds dsh-codex from a pinned closure; the module receives
  # the derivation directly in `plugins`.
  codexPlugin = import ./fixtures/codex-plugin.nix { inherit pkgs; };
  codexDecl = {
    plugins = [ "@deepseek-ai/dsh-base" "@deepseek-ai/dsh-web-app" codexPlugin ];
    userPatches = [
      {
        id = "llm-openai-codex";
        config = { searchMode = "live"; useNativeCompaction = true; };
      }
    ];
  };

  # Genuine user-declared buildNpmPackage plugin, passed RAW (no
  # mkBundle selectors, no installed-root path surgery): the
  # build-time resolver reads the installed root
  # ($out/lib/node_modules/@dsh-poc/user-npm-plugin) and the manifest
  # name (@dsh-poc/user-npm-plugin, never the dsh-poc-npm-user-pkg pname).
  userPkg = import ./fixtures/user-npm-plugin.nix { inherit pkgs; };
  userNpmDecl = {
    plugins = [ userPkg ];
    userPatchesFile = null;
    userPatches = [ ];
  };

  # Fixture profile declaration, shared verbatim with the user module below
  # so the expected artifact path matches the installed one exactly.
  agentDecl = {
    plugins = [ ../examples/plugins/tui-core ];
    userPatchesFile = null;
    userPatches = [ ];
  };

  userModule = {
    home.username = username;
    home.homeDirectory = homeDirectory;
    home.stateVersion = "25.11";
    # Suggest-only systemd path (never auto-starts/stops units). The script
    # additionally isolates XDG_RUNTIME_DIR so no user bus is reachable at
    # all, and aborts if one somehow is.
    systemd.user.startServices = false;
    programs.dsh = {
      enable = true;
      # The ACTUAL packaged CLI, installed EXACTLY through home.packages
      # (the module wraps nothing and rewrites no symlinks).
      package = pkgs.callPackage ../pkgs/dsh.nix { src = dshSrc; };
      homePatchesFile = null;
      settings = { };
      profiles = {
        agent = agentDecl;
        codex = codexDecl;
        user-npm = userNpmDecl;
      };
    };
  };

  evaluated = hmLib.homeManagerConfiguration {
    inherit pkgs;
    modules = [ dshModule userModule ];
  };

  config = evaluated.config;
  activationValue = config.home.activation.dshProfiles;
  activationScript =
    if builtins.isString activationValue then activationValue else activationValue.data;

  # Expected immutable profile artifact, as a store-path STRING only
  # (toString never realises: no build happens in this evaluation).
  expectedAgentArtifact = toString (profilesLib.buildProfile {
    inherit pkgs;
    profile = profilesLib.mkProfile ({
      name = "agent";
      inherit inBoxNames;
    } // agentDecl);
  });
  expectedCodexArtifact = toString (profilesLib.buildProfile {
    inherit pkgs;
    profile = profilesLib.mkProfile ({
      name = "codex";
      inherit inBoxNames;
    } // codexDecl);
  });
  # Expected immutable user-npm artifact, built from THE SAME module
  # declaration above (store-path string only, same as above).
  expectedUserNpmArtifact = toString (profilesLib.buildProfile {
    inherit pkgs;
    profile = profilesLib.mkProfile ({
      name = "user-npm";
      inherit inBoxNames;
    } // userNpmDecl);
  });
in
{
  generation = config.home.activationPackage;
  activationDrvPath = config.home.activationPackage.drvPath;
  package = config.programs.dsh.package;
  # Immutable store path of the packaged CLI, as a string: the e2e script
  # asserts `readlink -f $HOME/.nix-profile/bin/dsh` lands exactly here.
  packageOutPath = config.programs.dsh.package.outPath;
  packageDrvPath = config.programs.dsh.package.drvPath;
  # Project-pinned node (tests-flake nixpkgs, the same pkgs the profiles
  # build with): the script realises this derivation and runs its runtime
  # probes with bin/node, never an ambient runtime.
  nodePackage = pkgs.nodejs;
  nodeOutPath = pkgs.nodejs.outPath;
  checks = {
    # The CLI installs EXACTLY unmodified: derivation identity inside
    # home.packages (HM adds its own entries alongside, so membership, not
    # equality).
    packageExact = builtins.elem config.programs.dsh.package config.home.packages;
    # Side-effecting block ordered after writeBoundary under the real HM DAG
    # (a dependency cycle would abort while forcing activationPackage).
    dagOrdered =
      builtins.isAttrs activationValue
      && activationValue.after == [ "writeBoundary" ];
    layoutOk = lib.hasInfix "\"$HOME/.dsh/profiles\"/agent" activationScript;
    userNpmLayoutOk = lib.hasInfix "\"$HOME/.dsh/profiles\"/user-npm" activationScript;
    codexLayoutOk = lib.hasInfix "\"$HOME/.dsh/profiles\"/codex" activationScript;
  };
  inherit expectedAgentArtifact expectedCodexArtifact;
  inherit expectedUserNpmArtifact;
  # Immutable installed package path of the raw user derivation (the
  # effective root lives at $out/lib/node_modules/@dsh-poc/user-npm-plugin;
  # the harness derives it from here, never from the pname string).
  userNpmOutPath = userPkg.outPath;
  userNpmDrvPath = userPkg.drvPath;
}
