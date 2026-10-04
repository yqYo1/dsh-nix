{ lib }:

let
  mkPluginBundle =
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
      # resolution to build time, where buildProfileBundle reads package.json
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
            throw "dsh plugin bundle: missing package.json at ${manifestPath}"
        else
          null;
      resolvedPackageName = if packageName != null then packageName else manifest.name or null;
      # Raw Nix packages (derivations) are not inspectable at evaluation time:
      # reading their package.json would be IFD.  Defer the missing-name
      # error to buildProfileBundle, which reads package.json at build time.
      checkedPackageName =
        if resolvedPackageName == null || resolvedPackageName == "" then
          if manifest == null then null
          else
            throw "dsh plugin bundle: packageName is required (set it explicitly or provide package.json name)"
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
      plugin,
    }:
    if builtins.isString plugin then
      if builtins.elem plugin inBoxNames then
        {
          kind = "in-box";
          name = plugin;
        }
      else
        {
          kind = "spec";
          spec = plugin;
        }
    else if builtins.isAttrs plugin && plugin ? packageName && plugin ? packagePath then
      {
        kind = "nix";
        inherit plugin;
      }
    else
      {
        kind = "nix";
        plugin = mkPluginBundle { path = plugin; };
      };

  fetchSpecs =
    {
      pkgs,
      specs,
      hash ? "",
    }:
    let
      # Preserve store-path context for file: specs.  Without this explicit
      # builtins.storePath reference, the fixed-output derivation has no input
      # source and sandboxed pnpm cannot see the local package.
      contextualSpecs = lib.imap0 (
        index: spec:
        if lib.hasPrefix "file:/nix/store/" spec then "file:/build/spec-inputs/${toString index}" else spec
      ) specs;
      specCopies = lib.concatStringsSep "\n" (
        lib.imap0 (
          index: spec:
          if lib.hasPrefix "file:/nix/store/" spec then
            let
              source = builtins.path { path = lib.removePrefix "file:" spec; };
            in
            ''
              mkdir -p /build/spec-inputs
                          cp -rL ${lib.escapeShellArg (toString source)} ${lib.escapeShellArg "/build/spec-inputs/${toString index}"}''
          else
            ""
        ) specs
      );
    in
    pkgs.stdenv.mkDerivation {
      name = "dsh-spec-plugins";
      outputHashMode = "recursive";
      # An empty hash is the discovery mode: fakeHash lets evaluation proceed
      # and Nix reports the actual recursive hash at build time.
      outputHash = if hash == "" then lib.fakeHash else hash;
      nativeBuildInputs = [
        pkgs.cacert
        pkgs.nodejs
        pkgs.pnpm
      ];
      impureEnvVars = pkgs.lib.fetchers.proxyImpureEnvVars ++ [ "NIX_NPM_REGISTRY" ];
      buildCommand = ''
        # The fixed-output sandbox does not inherit the caller's CA file.
        # Use the Nix CA bundle; retain certificate verification for pnpm.
        export NODE_EXTRA_CA_CERTS="$NIX_SSL_CERT_FILE"
        export HOME=/build/home
        mkdir -p "$HOME"
        pnpm config set store-dir /build/pnpm-store
        mkdir -p /build/project
        cd /build/project
        printf '%s' '{"name":"dsh-profile-plugins","private":true,"version":"0.0.0","type":"module"}' > package.json
        printf '%s\n' \
          'packages:' \
          '  - .' \
          'strictDepBuilds: false' \
          > pnpm-workspace.yaml
        ${specCopies}
        pnpm add --ignore-scripts --package-import-method=copy ${lib.escapeShellArgs contextualSpecs}
        node -e 'const fs=require("fs"); const p=JSON.parse(fs.readFileSync("package.json")); p.dependencies=Object.fromEntries(Object.keys(p.dependencies||{}).map(k=>[k,"0.0.0"])); fs.writeFileSync("package.json", JSON.stringify(p));'
        mkdir -p node_modules/.dsh-spec
        node -e 'const fs=require("fs"); const p=JSON.parse(fs.readFileSync("package.json")); for (const k of Object.keys(p.dependencies||{})) console.log(k);' |
          while IFS= read -r packageName; do
            [ -e "node_modules/$packageName" ] || continue
            sourcePath=$(readlink -f "node_modules/$packageName")
            stablePath="node_modules/.dsh-spec/$packageName"
            mkdir -p "$(dirname "$stablePath")"
            cp -rL "$sourcePath" "$stablePath"
            rm -rf "node_modules/$packageName"
            ln -s "$(realpath --relative-to="$(dirname "node_modules/$packageName")" "$stablePath")" "node_modules/$packageName"
          done
        rm -rf node_modules/.pnpm
        rm -f pnpm-lock.yaml node_modules/.pnpm/lock.yaml
        rm -rf node_modules/.cache node_modules/.modules.yaml node_modules/.pnpm-workspace-state-v1.json
        cp -r . "$out"
      '';
    };
in
{
  inherit mkPluginBundle;
  mkPlugin = mkPluginBundle;
  inherit classifyPlugin fetchSpecs;
}
