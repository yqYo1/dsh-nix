{
  profilesLib,
  inBoxNames,
  dshSrc,
  buildPkgsFor,
  dshPackageFor ? (_: null),
  profileTemplates ? [ ],
  onDemandBundles ? [ ],
  fetchPnpmDepsFor ? (_: null),
}:

{
  config,
  lib,
  pkgs,
  ...
}:

let
  cfg = config.programs.dsh;
  buildPkgs = buildPkgsFor pkgs.stdenv.hostPlatform.system;
  dshPackage = dshPackageFor pkgs.stdenv.hostPlatform.system;

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
        type = lib.types.listOf (
          lib.types.oneOf [
            lib.types.str
            lib.types.path
            lib.types.package
          ]
        );
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
        type = lib.types.listOf (
          lib.types.oneOf [
            lib.types.str
            lib.types.path
            lib.types.package
          ]
        );
        default = [ ];
        description = ''
          Entries appended after the extended template's bundles. Accepts the
          same forms as plugins (official bundle names, Nix packages, plugin
          paths). Only valid together with `extends`.
        '';
      };
      plugins = lib.mkOption {
        type = lib.types.nullOr (
          lib.types.listOf (
            lib.types.oneOf [
              lib.types.str
              lib.types.path
              lib.types.package
            ]
          )
        );
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

  templateReason =
    name:
    if builtins.elem name profileTemplates then
      null
    else
      "is not a shipped profile template (expected one of ${lib.concatStringsSep ", " profileTemplates})";

  profileReason =
    name: p:
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
    else if p.extends == null && p.plugins == [ ] then
      "plugins must not be empty; disable the profile instead"
    else
      null;

  checkedTemplates = lib.mapAttrs (
    name: t:
    let
      reason = templateReason name;
    in
    if reason == null then
      t
    else
      throw "programs.dsh: template profile ${builtins.toJSON name} ${reason}"
  ) cfg.templates;

  checkedProfiles = lib.mapAttrs (
    name: p:
    let
      reason = profileReason name p;
    in
    if reason == null then p else throw "programs.dsh: profile ${builtins.toJSON name} ${reason}"
  ) cfg.profiles;

  templateDeclarations = lib.mapAttrs (
    name: t:
    profilesLib.mkProfile {
      inherit name;
      extends = name;
      inherit (t) extraPlugins userPatchesFile userPatches;
      inherit inBoxNames;
      installBundles = onDemandBundles;
    }
  ) (lib.filterAttrs (_: t: t.enable) checkedTemplates);

  profileDeclarations = lib.mapAttrs (
    name: p:
    profilesLib.mkProfile {
      inherit name;
      inherit (p) extends;
      plugins = if p.plugins == null then [ ] else p.plugins;
      inherit (p) extraPlugins userPatchesFile userPatches;
      inherit inBoxNames;
      installBundles = onDemandBundles;
    }
  ) (lib.filterAttrs (_: p: p.enable) checkedProfiles);

  declarations = templateDeclarations // profileDeclarations;

  artifacts = lib.mapAttrs (
    _name: declaration:
    profilesLib.buildProfile {
      pkgs = buildPkgs;
      profile = declaration;
      install = cfg.package.dev or cfg.package;
      profileMeta = cfg.package.profileMeta or null;
      catalogNames = inBoxNames;
    }
  ) declarations;

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
  checkedArtifacts = lib.mapAttrs (
    name: artifact:
    let
      reason = profilesLib.invalidNameReason name;
    in
    if reason == null then
      artifact
    else
      throw "programs.dsh: profile name ${builtins.toJSON name} ${reason}"
  ) artifacts;

  activation = import ../../lib/hm-activation.nix { inherit lib cfg checkedArtifacts; };
in
{
  options.programs.dsh = {
    enable = lib.mkEnableOption "DeepSeek Harness (dsh)";

    package = lib.mkOption {
      type = lib.types.package;
      default =
        if dshPackage != null then
          dshPackage
        else
          let
            fetcher = fetchPnpmDepsFor buildPkgs.stdenv.hostPlatform.system;
          in
          if fetcher == null then
            throw "programs.dsh: buildPkgsFor must provide the pinned fetchPnpmDeps support"
          else
            buildPkgs.callPackage ../../pkgs/dsh.nix {
              src = dshSrc;
              fetchPnpmDeps = fetcher;
            };
      defaultText = "pkgs.dsh (via inputs.dsh-nix.overlays.default) or the bundled callPackage build with the pinned pnpm-deps fetch support";
      description = "The dsh CLI package to install. Keep it the unwrapped dsh installation: template profiles read PROFILE_TEMPLATES from it and on-demand bundles link its source tree.";
    };

    removeOrphanProfiles = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = ''
        Remove profile directories that this module previously managed but
        that are no longer declared.  Only profiles with a valid dsh-nix
        stamp are considered; user-owned profiles are never touched.  The
        default keeps orphans in place and reports them.
      '';
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
        lib.hm.dag.entryAfter [ "writeBoundary" "linkGeneration" ] activation.activationScript
      else
        activation.activationScript;
  };
}
