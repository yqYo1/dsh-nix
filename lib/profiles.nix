{ lib }:

let
  pluginsLib = import ./plugins.nix { inherit lib; };
  inherit (pluginsLib) classifyPlugin;

  # Profile names become one path component under ~/.dsh/profiles and part of
  # the derivation name.  Validate here, not only in the Home Manager module:
  # profilesLib is public and tests call mkProfile directly.
  invalidNameReason =
    name:
    if name == "" then
      "must not be empty"
    else if name == "." || name == ".." then
      "must not be ${builtins.toJSON name}"
    else if name == "node_modules" then
      "is reserved"
    else if builtins.match ".*[\\/].*" name != null then
      "must not contain '/' or '\\'"
    else if builtins.match ".*[[:cntrl:]].*" name != null then
      "must not contain control characters"
    else
      null;

  mkProfile =
    {
      name,
      plugins ? [ ],
      extraPlugins ? [ ],
      extends ? null,
      inBoxNames ? [ ],
      installBundles ? [ ],
      userPatchesFile ? null,
      userPatches ? [ ],
    }:
    let
      # A template profile starts from a shipped profile template
      # (PROFILE_TEMPLATES, read from the dsh installation at build time) and
      # adds `extraPlugins`; a custom profile declares every entry in
      # `plugins` and uses no template.
      selected = if extends == null then plugins else extraPlugins;
      classified = map (plugin: classifyPlugin { inherit inBoxNames installBundles plugin; }) selected;
      nixEntries = map (entry: entry.plugin) (builtins.filter (entry: entry.kind == "nix") classified);
      packageNames = map (plugin: plugin.packageName) nixEntries;
      # Deferred (null) names from raw derivations resolve at build time from
      # package.json; they must not collide with each other here.  Check only
      # the eval-known names now; buildProfile enforces runtime
      # uniqueness after resolution.
      knownPackageNames = builtins.filter (n: n != null && n != "") packageNames;
      nameReason = if name == null then "must not be null" else invalidNameReason name;
      uniquePackageNames =
        if builtins.length knownPackageNames == builtins.length (lib.unique knownPackageNames) then
          true
        else
          throw "dsh profile: plugin packageNames must be unique";
    in
    assert nameReason == null;
    assert uniquePackageNames;
    assert extends == null || plugins == [ ];
    assert extends != null || extraPlugins == [ ];
    assert extends != null || plugins != [ ];
    assert userPatchesFile == null || userPatches == [ ];
    {
      inherit
        name
        extends
        userPatchesFile
        userPatches
        ;
      plugins = classified;
      installBundles = map (entry: entry.name) (
        builtins.filter (entry: entry.kind == "install-bundle") classified
      );
      inherit nixEntries;
    };

  # Compile the profile composer once per nixpkgs instance.  Profile
  # derivations provide files and JSON; package-root resolution, bundle
  # ordering and projection happen in the Node/TypeScript script.
  profileBuilder =
    pkgs:
    pkgs.runCommand "dsh-profile-builder"
      {
        nativeBuildInputs = [ pkgs.typescript ];
      }
      ''
        mkdir -p "$out"
        cp ${./profile-builder.ts} "$out/profile-builder.ts"
        (cd "$out" && tsc --target ES2022 --module Node16 --moduleResolution Node16 --skipLibCheck \
          --outDir "$out" profile-builder.ts)
        rm "$out/profile-builder.ts"
      '';

  buildProfile =
    {
      pkgs,
      profile,
      install ? null,
      profileMeta ? null,
    }:
    let
      template = profile.extends or null;
      installBundleNames = profile.installBundles or [ ];
      needsInstall = installBundleNames != [ ] || (template != null && profileMeta == null);
      installArg = if !needsInstall || install == null then "" else toString install;
      templateSource = if profileMeta != null then toString profileMeta else installArg;
      classified = profile.plugins;
      nixEntries = builtins.filter (entry: entry.kind == "nix") classified;
      nixMetadata = map (entry: {
        packageName = entry.plugin.packageName;
        packagePath = toString entry.plugin.packagePath;
        patchPath =
          if (entry.plugin.patchPath or null) == null then null else toString entry.plugin.patchPath;
        explicitPatch =
          if (entry.plugin.explicitPatch or null) == null then null else toString entry.plugin.explicitPatch;
      }) nixEntries;
      metadata = pkgs.writeText "dsh-profile-plugins.json" (
        builtins.toJSON {
          inherit nixMetadata;
          classes = map (
            entry:
            if entry.kind == "in-box" || entry.kind == "install-bundle" then
              {
                inherit (entry) kind;
                inherit (entry) name;
              }
            else
              {
                inherit (entry) kind;
                packageName = entry.plugin.packageName;
                packagePath = toString entry.plugin.packagePath;
                patchPath =
                  if (entry.plugin.patchPath or null) == null then null else toString entry.plugin.patchPath;
              }
          ) classified;
        }
      );
      patches = pkgs.writeText "dsh-profile-patches.json" (builtins.toJSON profile.userPatches);
      patchSource =
        if profile.userPatchesFile != null then builtins.path { path = profile.userPatchesFile; } else null;
      builder = profileBuilder pkgs;
    in
    pkgs.runCommand "dsh-profile-${profile.name}"
      {
        nativeBuildInputs = [
          builder
          pkgs.nodejs
        ];
      }
      ''
        mkdir -p "$out"
        node ${builder}/profile-builder.js \
          --out "$out" \
          --name ${lib.escapeShellArg profile.name} \
          --metadata ${metadata} \
          --template ${lib.escapeShellArg (if template == null then "" else template)} \
          --template-source ${lib.escapeShellArg (if template == null then "" else templateSource)} \
          --install ${lib.escapeShellArg installArg} \
          --patches ${patches} \
          --patch-source ${lib.escapeShellArg (if patchSource == null then "" else toString patchSource)} \
          --reader ${./read-profile-template.mjs}
      '';

in
{
  inherit mkProfile buildProfile invalidNameReason;
}
