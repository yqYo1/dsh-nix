# Build one pinned OFFICIAL on-demand dsh bundle from its published npm
# tarball: the package's own files plus its production dependency closure, so
# a profile links it like any Nix-package plugin.  The version, tarball hash,
# committed lockfile and pnpm-store hash are pinned by
# lib/official-plugins.nix; users only ever name the package.
{ lib
, stdenvNoCC
, runCommand
, fetchurl
, fetchPnpmDeps
, pnpmConfigHook
, jq
, nodejs
, pnpm_11
, npmName
, version
, tarballHash
, depsHash
, lockFile
}:

let
  parts = lib.splitString "/" npmName;
  scope = builtins.head parts;
  short = lib.last parts;

  src = fetchurl {
    url = "https://registry.npmjs.org/${scope}/${short}/-/${short}-${version}.tgz";
    hash = tarballHash;
  };

  # pnpm project: the published package (unpacked tarball), the committed
  # lockfile, and the pnpm settings the lockfile was generated with.
  projectSrc = runCommand "${short}-${version}-project" { nativeBuildInputs = [ jq ]; } ''
    mkdir -p "$out"
    tar -xzf ${src} -C "$out" --strip-components=1
    chmod -R u+w "$out"
    # The published manifest carries devDependencies/scripts for monorepo
    # development; the runtime artifact needs only the production manifest the
    # committed lockfile was generated from.
    jq 'del(.devDependencies, .scripts, .packageManager)' "$out/package.json" > "$out/package.json.tmp"
    mv "$out/package.json.tmp" "$out/package.json"
    cp ${lockFile} "$out/pnpm-lock.yaml"
    cat > "$out/pnpm-workspace.yaml" <<EOF
    packages:
      - .
    autoInstallPeers: false
    EOF
  '';

  pnpmDeps = fetchPnpmDeps {
    pname = "${short}-deps";
    inherit version;
    src = projectSrc;
    fetcherVersion = 4;
    hash = depsHash;
  };
in
stdenvNoCC.mkDerivation {
  pname = "dsh-official-plugin-${short}";
  inherit version;

  src = projectSrc;

  nativeBuildInputs = [ nodejs pnpm_11 pnpmConfigHook ];
  inherit pnpmDeps;

  buildPhase = ''
    runHook preBuild
    # Host peers (cordis, dsh-llm, dsh-session, ...) come from the running
    # dsh installation at runtime; only the package's own dependencies live
    # in the artifact.
    pnpm install --offline --frozen-lockfile --prod --ignore-scripts
    runHook postBuild
  '';

  installPhase = ''
    runHook preInstall
    mkdir -p "$out"
    cp -a . "$out/"
    # Build-time pnpm plumbing and caches are not part of the plugin.
    rm -rf "$out/node_modules/.cache" "$out/node_modules/.modules.yaml" \
      "$out/pnpm-workspace.yaml"
    runHook postInstall
  '';

  meta = {
    description = "Official dsh plugin bundle ${npmName} ${version} (pinned npm build)";
    homepage = "https://github.com/deepseek-ai/deepseek-harness";
    license = lib.licenses.mit;
    platforms = lib.platforms.all;
  };
}
