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
  hmOptions = import ../../lib/hm-options.nix { inherit lib; };
  inherit (hmOptions) templateModule profileModule;

  hmProfiles = import ../../lib/hm-profiles.nix {
    inherit
      lib
      profilesLib
      cfg
      profileTemplates
      inBoxNames
      onDemandBundles
      buildPkgs
      ;
  };
  inherit (hmProfiles) checkedArtifacts;

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
