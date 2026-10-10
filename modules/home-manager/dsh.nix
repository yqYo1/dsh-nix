# Home Manager module factory for `programs.dsh`.
#
# Declarative plugin management in the Thunderbird style: the module owns the
# COMPOSITION layers under ~/.dsh (profiles/<name>/ + the home-level
# cordis.patch.yml), while the app owns its mutable data (settings.yaml after
# seeding, .credentials.yaml, sessions/, storages/).
#
# Activation materialises each immutable Nix-built profile into
# ~/.dsh/profiles/<name> (writable; dsh rewrites the profile root cordis.yml
# on every boot), comparing a stamp against the artifact store path.
#
# `plugins` accepts four forms in one ordered list:
#   - in-box bundle names  ("@deepseek-ai/dsh-base")          name only
#   - pnpm spec strings    ("github:someone/plugin")          resolved at build
#     time by a fixed-output derivation; pin with `specsHash`
#   - Nix packages/paths   (pkgs.buildNpmPackage { ... })     symlinked in at
#     their effective root (package manifest or installed npm layout)
#   - local plugin paths   (./my-plugin)                      symlinked in
#
# Requires the user's nixpkgs to provide fetchPnpmDeps + pnpmConfigHook when
# `package` defaults to the callPackage-built dsh.
{ pluginsLib, profilesLib, inBoxNames, dshSrc }:

{ config, lib, pkgs, ... }:

let
  cfg = config.programs.dsh;

  profileModule = lib.types.submodule {
    options = {
      plugins = lib.mkOption {
        type = lib.types.listOf (lib.types.oneOf [ lib.types.str lib.types.path lib.types.package ]);
        default = [ ];
        description = ''
          Ordered plugin list. Each entry is one of: an in-box bundle name
          (@deepseek-ai/dsh-*), a pnpm spec string (resolved at build time;
          pin with specsHash), or a Nix package/path.
        '';
      };
      userPatchesFile = lib.mkOption {
        type = lib.types.nullOr lib.types.path;
        default = null;
        description = "Profile-level cordis.patch.yml (the DSH user patch layer).";
      };
      userPatches = lib.mkOption {
        type = lib.types.listOf lib.types.attrs;
        default = [ ];
        description = "Inline profile patch list (JSON-serialisable only; use userPatchesFile for !!js).";
      };
      specsHash = lib.mkOption {
        type = lib.types.str;
        default = "";
        description = "spec plugin 成果物を検証する固定出力 hash。依存解決の固定には specsLock も指定します。";
      };
      specsLock = lib.mkOption {
        type = lib.types.nullOr lib.types.path;
        default = null;
        description = ''
          spec plugin の依存解決を固定する、Git 管理の pnpm-lock.yaml。
          指定時は root importer から manifest を復元し、frozen-lockfile で構築します。
          宣言と一致しない lockfile は拒否し、未固定の依存解決へ fallback しません。
          省略時の hash-only 設定は registry の範囲指定を build 時に再解決します。
        '';
      };
    };
  };

  declarations = lib.mapAttrs (name: p:
    profilesLib.mkProfileBundle {
      inherit name;
      inherit (p) userPatchesFile userPatches specsHash specsLock;
      plugins = p.plugins;
      inherit inBoxNames;
    }) cfg.profiles;

  artifacts = lib.mapAttrs (name: declaration:
    profilesLib.buildProfileBundle { inherit pkgs; profile = declaration; }) declarations;

  # Profile names become a single pathname component under
  # ~/.dsh/profiles.  Validation mirrors upstream dsh (profile.ts): only
  # empty, slash, backslash, ".", "..", and "node_modules" are rejected
  # there; we additionally reject ASCII control characters (including
  # newline) because the managed-profile manifest below is
  # newline-separated and could not round-trip them.  Everything else --
  # spaces, Unicode, quotes, glob characters -- is allowed, so the
  # activation script must interpolate names with lib.escapeShellArg as a
  # SEPARATE shell word: "$HOME/.dsh/profiles"/'my profile'.
  # NOTE: "$HOME/..." must NOT be combined with lib.escapeShellArg in a
  # single double-quoted string: that helper emits single-quoted literals
  # ('web'), which are literal quote characters once wrapped in double
  # quotes ("$HOME/.../'web'").
  invalidNameReason = name:
    if name == "" then "must not be empty"
    else if name == "." || name == ".." then "must not be ${builtins.toJSON name}"
    else if name == "node_modules" then "is reserved"
    else if builtins.match ".*[\\/].*" name != null then "must not contain '/' or '\\'"
    else if builtins.match ".*[[:cntrl:]].*" name != null then "must not contain control characters"
    else null;
  checkedArtifacts = lib.mapAttrs (name: artifact:
    let reason = invalidNameReason name;
    in if reason == null then artifact
    else throw "programs.dsh: profile name ${builtins.toJSON name} ${reason}") artifacts;

  # Separate shell words: double-quoted $HOME prefix, single-quoted name.
  profileDir = name: "\"$HOME/.dsh/profiles\"/" + lib.escapeShellArg name;
  stampFile = name: "\"$HOME/.dsh/profiles\"/" + lib.escapeShellArg name + "/\".dsh-nix-stamp\"";
  managedFile = "$HOME/.dsh/.dsh-nix-managed-profiles";

  # Refuse symlinked roots BEFORE any profile write: the per-profile
  # rm -rf/mkdir/cp below must never run through a user-supplied symlink.
  # Checked again in activateCleanup below (defence in depth); this early
  # guard is what makes the refusal effective.
  activateRootGuard = ''
    if [ -L "$HOME/.dsh" ]; then
      echo "programs.dsh: refusing to manage $HOME/.dsh: symlinked root" >&2
      exit 1
    fi
    if [ -L "$HOME/.dsh/profiles" ]; then
      echo "programs.dsh: refusing to manage $HOME/.dsh/profiles: symlinked root" >&2
      exit 1
    fi
  '';

  activateProfile = name: artifact:
    let
      dir = profileDir name;
      stamp = stampFile name;
      artifactString = toString artifact;
    in
    ''
      if [ -f ${stamp} ] && [ "$(cat ${stamp})" = ${lib.escapeShellArg artifactString} ]; then
        :
      elif [[ -v DRY_RUN ]]; then
        echo "dshProfiles: would materialise profile ${lib.escapeShellArg name} from ${lib.escapeShellArg artifactString}"
      else
        rm -rf ${dir}
        mkdir -p ${dir}
        cp -a ${lib.escapeShellArg artifactString}/. ${dir}/
        # cp -a syncs the destination directory attributes (read-only store
        # modes) too; dsh rewrites the profile root cordis.yml on every boot.
        chmod -R u+w ${dir}
        printf '%s' ${lib.escapeShellArg artifactString} > ${stamp}
      fi
    '';

  activateSettings = lib.optionalString (cfg.settings != { }) ''
    if [ ! -f "$HOME/.dsh/settings.yaml" ]; then
      if [[ -v DRY_RUN ]]; then
        echo "dshProfiles: would seed $HOME/.dsh/settings.yaml"
      else
      mkdir -p "$HOME/.dsh"
      umask 077
      cat > "$HOME/.dsh/settings.yaml" <<'DSH_NIX_SETTINGS'
    ${builtins.toJSON cfg.settings}
    DSH_NIX_SETTINGS
      fi
    fi
  '';

  currentNames = lib.attrNames checkedArtifacts;

  # Remove profile directories this module previously managed but which are
  # no longer declared.  Only names recorded in our own manifest are ever
  # removed, and only as a single path component under
  # ~/.dsh/profiles (belt and braces alongside the eval-time name check),
  # so user-owned profiles are never touched.
  activateCleanup = ''
    # Never follow a user-supplied symlink: rm -rf through a symlinked
    # root would delete the link target's contents.
    if [ -L "$HOME/.dsh/profiles" ]; then
      echo "programs.dsh: refusing to manage $HOME/.dsh/profiles: symlinked root" >&2
      exit 1
    fi
    if [[ -v DRY_RUN ]]; then
      echo "dshProfiles: dry run, skipping profile cleanup and manifest update"
    else
    mkdir -p "$HOME/.dsh/profiles"
    if [ -f "${managedFile}" ]; then
      while IFS= read -r old; do
        case "$old" in
          ${lib.concatStringsSep "|" (map lib.escapeShellArg (currentNames ++ [ "" ]))}) : ;; # still declared (or empty line)
          "." | ".." | "node_modules" | "" | *[/\\]*) : ;; # never delete unsafe, reserved, or empty entries
          *) if printf '%s' "$old" | grep -q '[[:cntrl:]]'; then :; else rm -rf "$HOME/.dsh/profiles/$old"; fi ;;
        esac
      done < "${managedFile}"
    fi
    # Rewrite the manifest only when it changed, so repeat activations are
    # byte-identical no-ops (command substitution strips trailing newlines
    # on both sides, keeping the comparison exact).
    new_managed=$(printf '%s\n' ${lib.escapeShellArgs currentNames})
    if [ ! -f "${managedFile}" ] || [ "$(cat "${managedFile}")" != "$new_managed" ]; then
      printf '%s\n' ${lib.escapeShellArgs currentNames} > "${managedFile}"
    fi
    fi
  '';

  activationScript =
    activateRootGuard
    + "\n" + lib.concatStringsSep "\n" (lib.mapAttrsToList activateProfile checkedArtifacts)
    + "\n" + activateCleanup
    + "\n" + activateSettings;
in
{
  options.programs.dsh = {
    enable = lib.mkEnableOption "DeepSeek Harness (dsh)";

    package = lib.mkOption {
      type = lib.types.package;
      default = pkgs.dsh or (pkgs.callPackage ../../pkgs/dsh.nix { src = dshSrc; });
      defaultText = "pkgs.dsh (via inputs.dsh-nix.overlays.default) or callPackage fallback";
      description = "The dsh CLI package to install.";
    };

    profiles = lib.mkOption {
      type = lib.types.attrsOf profileModule;
      default = { };
      description = "DSH profiles materialised under ~/.dsh/profiles/<name>.";
    };

    homePatchesFile = lib.mkOption {
      type = lib.types.nullOr lib.types.path;
      default = null;
      description = "Machine-level patch layer written to ~/.dsh/cordis.patch.yml.";
    };

    settings = lib.mkOption {
      type = lib.types.attrs;
      default = { };
      description = "Seed-only settings.yaml content; after first activation the app owns the file.";
    };
  };

  config = lib.mkIf cfg.enable {
    # The dsh CLI installs EXACTLY as given: no wrapping, no symlink
    # rewriting.  Plugin composition lives in the ~/.dsh profile
    # directories below, never in the package.
    home.packages = [ cfg.package ];

    home.file = lib.mkIf (cfg.homePatchesFile != null) {
      ".dsh/cordis.patch.yml".source = cfg.homePatchesFile;
    };

    # The block writes files, so under real Home Manager it must run after
    # the writeBoundary DAG node (activation contract: side-effecting blocks
    # after writeBoundary; bare strings sort anywhere).  Plain nixpkgs lib
    # (stub evaluations) has no lib.hm.dag, so fall back to the bare string.
    home.activation.dshProfiles =
      if lib ? hm && lib.hm ? dag && lib.hm.dag ? entryAfter then
        lib.hm.dag.entryAfter [ "writeBoundary" ] activationScript
      else
        activationScript;
  };
}
