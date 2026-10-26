{ lib }:

let
  mkBundle =
    {
      packageName ? null,
      path,
      patchPath ? null,
      ...
    }:
    let
      packagePath = if builtins.isPath path then builtins.path { inherit path; } else path;
      # Only local directories are inspectable at evaluation time.  A raw
      # derivation (or any non-path package) defers package.json name/patch
      # resolution to build time, where buildProfile reads package.json
      # with jq (no IFD).  An explicit patchPath forces layer membership at
      # build time; otherwise the manifest's dsh.bundle.patch declaration
      # decides (plain deps stay inactive).
      inspectable = builtins.isPath path;
      manifest =
        if inspectable then
          let
            manifestPath = "${toString path}/package.json";
          in
          if builtins.pathExists manifestPath then
            builtins.fromJSON (builtins.readFile manifestPath)
          else
            throw "dsh bundle: missing package.json at ${manifestPath}"
        else
          null;
      resolvedPackageName = if packageName != null then packageName else manifest.name or null;
      # Raw Nix packages (derivations) are not inspectable at evaluation time:
      # reading their package.json would be IFD.  Defer the missing-name
      # error to buildProfile, which reads package.json at build time.
      checkedPackageName =
        if resolvedPackageName == null || resolvedPackageName == "" then
          if manifest == null then null
          else
            throw "dsh bundle: packageName is required (set it explicitly or provide package.json name)"
        else
          resolvedPackageName;
      declaredPatch =
        if manifest == null then null else (((manifest.dsh or { }).bundle or { }).patch or null);
      # Carry Nix path context for explicit patch files: a path-typed
      # patchPath (e.g. ./cordis.patch.yml) must materialise into the store
      # so the build sandbox can see it; relative strings stay verbatim as
      # package-relative manifest values.
      explicitPatch =
        if patchPath == null then null
        else if builtins.isPath patchPath then builtins.path { path = patchPath; }
        else patchPath;
      resolvedPatchPath = if explicitPatch != null then explicitPatch else declaredPatch;
    in
    {
      packageName = checkedPackageName;
      inherit packagePath;
      patchPath = resolvedPatchPath;
      # Raw explicit selection (null when the caller did not pass patchPath):
      # projection triggers only on this, never on a manifest-declared patch.
      inherit explicitPatch;
      isLayer = resolvedPatchPath != null;
    };

  classifyPlugin =
    {
      inBoxNames ? [ ],
      installBundles ? [ ],
      plugin,
    }:
    if builtins.isString plugin then
      if builtins.elem plugin inBoxNames then
        {
          kind = "in-box";
          name = plugin;
        }
      else if builtins.elem plugin installBundles then
        {
          kind = "install-bundle";
          name = plugin;
        }
      else
        throw "dsh profile: ${plugin} is not an official bundle; provide it as a Nix package or plugin path (pnpm spec strings are not accepted)"
    else if builtins.isAttrs plugin && plugin ? packageName && plugin ? packagePath then
      {
        kind = "nix";
        inherit plugin;
      }
    else
      {
        kind = "nix";
        plugin = mkBundle { path = plugin; };
      };

in
{
  inherit mkBundle;
  inherit classifyPlugin;
}
