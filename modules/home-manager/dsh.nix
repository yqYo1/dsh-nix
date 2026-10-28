# Home Manager module factory for `programs.dsh`.
#
# Declarative plugin management in the Thunderbird style: the module owns the
# COMPOSITION under ~/.dsh (profiles/<name>/ and the home-level
# cordis.patch.yml), while the app owns its mutable data (settings.yaml after
# seeding, .credentials.yaml, sessions/, storages/).
#
# Activation materialises each immutable Nix-built profile into
# ~/.dsh/profiles/<name> (writable; dsh rewrites the profile root cordis.yml
# on every boot), comparing a stamp against the artifact store path.
#
# `plugins` and `extraPlugins` accept forms in one ordered list:
#   - official bundle names ("@deepseek-ai/dsh-base": the bundles of the
#     shipped profile templates, the shipped optional bundles, and the
#     on-demand subagent bundles linked from the pinned dsh source)
#                                      name only, nothing to package
#   - Nix packages/paths   (pkgs.buildNpmPackage { ... })     symlinked in at
#     their effective root (package manifest or installed npm layout)
#   - local plugin paths   (./my-plugin)                      symlinked in
#
# Plugins that are not official bundles must be provided as Nix packages or
# paths (package them yourself); bare non-official names are rejected.
#
# A profile with `extends` set starts from that shipped template: the bundles
# come from the dsh installation (PROFILE_TEMPLATES) at build time,
# `extraPlugins` appends entries, and `userPatches` overrides only the rows it
# names.  `extends` works even while the template profile is disabled.  A
# profile with `plugins` set is fully custom and uses no template.  The
# `templates` option installs the template profiles themselves; enabling one
# excludes a user profile of the same name.
#
# Official cordis plugin packages that ship without a bundle of their own
# (for example `@deepseek-ai/dsh-tool-str-replace-editor`) are mounted with
# `userPatches` rows named after the installed package
# (`{ insert = [ { id = "str-replace-editor"; name = "@deepseek-ai/dsh-tool-str-replace-editor"; } ]; }`);
# the name resolves from the running installation.  A package without
# `dsh.bundle` is a plain dependency, so a row is its mount point.
#
# `package` defaults to `pkgs.dsh` (overlay) or the bundled callPackage build.
# The bundled build threads `fetchPnpmDepsFor` (system -> fetchPnpmDeps,
# supplied by the flake from the pinned `nixpkgs-fetch` input) so the
# pnpm-deps fixed-output hash stays valid under consumer nixpkgs overrides;
# the user's nixpkgs must still provide `pnpmConfigHook` and pnpm 11 for the
# main build.
{ pluginsLib, profilesLib, inBoxNames, dshSrc, profileTemplates ? [ ], onDemandBundles ? [ ], fetchPnpmDepsFor ? (_: null) }:

{ config, lib, pkgs, ... }:

let
  cfg = config.programs.dsh;

  # Built-in template profiles and user-defined profiles are separate.
  # Enabling a template installs a profile of that name; a user profile with
  # the same name is then a clash and waits for the template's disable.
  # `extends` builds a user profile on a template regardless of that template
  # profile's own enable flag.
  templateModule = lib.types.submodule {
    options = {
      enable = lib.mkOption {
        type = lib.types.bool;
        default = true;
        description = ''
          Whether the shipped template profile is materialised under
          ~/.dsh/profiles/<name>. Disabling it removes the profile and allows a
          user-defined profile with the same name.
        '';
      };
      extraPlugins = lib.mkOption {
        type = lib.types.listOf (lib.types.oneOf [ lib.types.str lib.types.path lib.types.package ]);
        default = [ ];
        description = ''
          Entries appended to the template profile after its template bundles.
          Accepts the same forms as plugins (official bundle names, Nix
          packages, plugin paths). Only the listed entries are added;
          everything else keeps the template's settings.
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
        description = ''
          Inline profile patch list (JSON-serialisable only; use
          userPatchesFile for !!js). Overrides only the rows it names, on top
          of the template's bundles.
        '';
      };
    };
  };

  profileModule = lib.types.submodule {
    options = {
      enable = lib.mkOption {
        type = lib.types.bool;
        default = true;
        description = ''
          Whether this user-defined profile is materialised under
          ~/.dsh/profiles. A disabled profile is removed on activation.
        '';
      };
      extends = lib.mkOption {
        type = lib.types.nullOr lib.types.str;
        default = null;
        description = ''
          Shipped profile template to extend (one of the dsh
          PROFILE_TEMPLATES names). The template's bundles and settings are
          kept, `extraPlugins` appends entries, and `userPatches` overrides
          only the rows they name. Works even while that template profile is
          disabled. Mutually exclusive with `plugins`.
        '';
      };
      extraPlugins = lib.mkOption {
        type = lib.types.listOf (lib.types.oneOf [ lib.types.str lib.types.path lib.types.package ]);
        default = [ ];
        description = ''
          Entries appended after the extended template's bundles. Accepts the
          same forms as plugins (official bundle names, Nix packages, plugin
          paths). Only valid together with `extends`.
        '';
      };
      plugins = lib.mkOption {
        type = lib.types.nullOr (lib.types.listOf (lib.types.oneOf [ lib.types.str lib.types.path lib.types.package ]));
        default = null;
        description = ''
          Full custom plugin list: the profile is entirely user-defined, uses
          no template, and may therefore share a name with an enabled template
          only after that template profile is disabled. Accepts official
          bundle names, Nix packages, and plugin paths. Mutually exclusive
          with `extends`.
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
        description = ''
          Inline profile patch list (JSON-serialisable only; use userPatchesFile
          for !!js). This is also how an installed cordis plugin package without
          a bundle of its own is mounted by name, for example
          { insert = [ { id = "str-replace-editor"; name = "@deepseek-ai/dsh-tool-str-replace-editor"; } ]; }.
        '';
      };
    };
  };

  templateReason = name:
    if builtins.elem name profileTemplates then null
    else "is not a shipped profile template (expected one of ${lib.concatStringsSep ", " profileTemplates})";

  profileReason = name: p:
    if (cfg.templates ? ${name}) && cfg.templates.${name}.enable && p.enable then
      "is also an enabled shipped template profile; disable templates.${name} first or rename the profile"
    else if p.extends != null && p.plugins != null then
      "sets both plugins and extends; use extraPlugins to extend a template"
    else if p.extends != null && !(builtins.elem p.extends profileTemplates) then
      "extends unknown shipped profile template ${builtins.toJSON p.extends}"
    else if p.extends == null && p.extraPlugins != [ ] then
      "sets extraPlugins without extends; use plugins for a custom profile"
    else if p.extends == null && p.plugins == null then
      "must set plugins (custom profile) or extends (template profile)"
    else
      null;

  checkedTemplates = lib.mapAttrs (name: t:
    let reason = templateReason name; in
    if reason == null then t
    else throw "programs.dsh: template profile ${builtins.toJSON name} ${reason}") cfg.templates;

  checkedProfiles = lib.mapAttrs (name: p:
    let reason = profileReason name p; in
    if reason == null then p
    else throw "programs.dsh: profile ${builtins.toJSON name} ${reason}") cfg.profiles;

  templateDeclarations = lib.mapAttrs (name: t:
    profilesLib.mkProfile {
      inherit name;
      extends = name;
      inherit (t) extraPlugins userPatchesFile userPatches;
      inherit inBoxNames;
      installBundles = onDemandBundles;
    }) (lib.filterAttrs (_: t: t.enable) checkedTemplates);

  profileDeclarations = lib.mapAttrs (name: p:
    profilesLib.mkProfile {
      inherit name;
      extends = p.extends;
      plugins = if p.plugins == null then [ ] else p.plugins;
      inherit (p) extraPlugins userPatchesFile userPatches;
      inherit inBoxNames;
      installBundles = onDemandBundles;
    }) (lib.filterAttrs (_: p: p.enable) checkedProfiles);

  declarations = templateDeclarations // profileDeclarations;

  artifacts = lib.mapAttrs (name: declaration:
    profilesLib.buildProfile { inherit pkgs; profile = declaration; install = cfg.package; }) declarations;

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
          *) if [[ "$old" == *[[:cntrl:]]* ]]; then :; else rm -rf "$HOME/.dsh/profiles/$old"; fi ;;
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
      default =
        let
          fetcher = fetchPnpmDepsFor pkgs.stdenv.hostPlatform.system;
        in
        pkgs.dsh or (pkgs.callPackage ../../pkgs/dsh.nix (
          { src = dshSrc; } // lib.optionalAttrs (fetcher != null) { fetchPnpmDeps = fetcher; }
        ));
      defaultText = "pkgs.dsh (via inputs.dsh-nix.overlays.default) or the bundled callPackage build with the pinned pnpm-deps fetch support";
      description = "The dsh CLI package to install. Keep it the unwrapped dsh installation: template profiles read PROFILE_TEMPLATES from it and on-demand bundles link its source tree.";
    };

    templates = lib.mkOption {
      type = lib.types.attrsOf templateModule;
      # The shipped profile templates are installed by default, each without
      # listing its bundles: the template definition comes from the dsh
      # installation.  Disable one with templates.<name>.enable = false.
      default = lib.genAttrs profileTemplates (_: { });
      description = ''
        Shipped profile templates materialised under ~/.dsh/profiles/<name>.
        Enabled by default; extend with extraPlugins/userPatches, or disable
        one to free its name for a user profile.
      '';
    };

    profiles = lib.mkOption {
      type = lib.types.attrsOf profileModule;
      default = { };
      description = ''
        User-defined profiles. Each sets plugins (a fully custom composition)
        or extends a shipped template. A profile name shared with an enabled
        template profile is rejected.
      '';
    };

    homePatchesFile = lib.mkOption {
      type = lib.types.nullOr lib.types.path;
      default = null;
      description = "Machine-level patch layer written to ~/.dsh/cordis.patch.yml and applied after each profile patch.";
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
