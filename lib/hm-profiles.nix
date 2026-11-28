{
  lib,
  profilesLib,
  cfg,
  profileTemplates,
  inBoxNames,
  onDemandBundles,
  buildPkgs,
}:
let
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

in
{
  inherit checkedArtifacts;
}
