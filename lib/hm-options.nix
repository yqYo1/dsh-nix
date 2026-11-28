{ lib }:
let
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
in
{
  inherit templateModule profileModule;
}
