# The DeepSeek Harness CLI as a Nix package: pnpm monorepo build of the
# deepseek-harness repo, producing `bin/dsh`.
#
# - `fetchPnpmDeps` materialises the pnpm store from pnpm-lock.yaml.
# - `pnpmConfigHook` points the offline install at that store.
# - The HMR service requires Node internals access, so the wrapper launches
#   node with `--expose-internals` (dsh itself never sets this flag).
{ lib
, stdenv
, nodejs
, pnpm
, pnpmConfigHook
, fetchPnpmDeps
, makeBinaryWrapper
, python3
, node-gyp
, src
}:

let
  version = "0.1.3-alpha.2";
  # rc.8+ embeds the source commit into client artifacts by shelling out to
  # `git rev-parse HEAD`.  The nix build is a gitless tarball with no `git`
  # in the environment, so we feed the pinned rev instead — the dsh build
  # script honours DSH_CLIENT_COMMIT_HASH and skips the git call entirely.
  dshCommitHash = if src ? rev
    then src.rev
    else throw "dsh.nix: source has no .rev to embed as DSH_CLIENT_COMMIT_HASH";
  pnpmDeps = fetchPnpmDeps {
    pname = "deepseek-harness";
    inherit version src;
    fetcherVersion = 4;
    hash = "sha256-t3wLZiWx9Q/QYRcQ7zB8lepRXXH5t4mE5nEoLHfOJO4=";
  };
in
stdenv.mkDerivation {
  pname = "dsh";
  inherit version src;

  nativeBuildInputs = [ nodejs pnpm pnpmConfigHook makeBinaryWrapper python3 node-gyp ];
  inherit pnpmDeps;
  env.DSH_CLIENT_COMMIT_HASH = dshCommitHash;

  buildPhase = ''
    runHook preBuild
    pnpm install --offline --frozen-lockfile
    # node-pty ships no linux prebuilds in its npm tarball, so its install
    # script must fall back to node-gyp — which needs python3 and the node
    # headers. Build it explicitly: pty.node and the unix spawn-helper both
    # come out of this rebuild, and the dsh patch loads both from
    # build/Release.
    (
      cd node_modules/.pnpm/node-pty@*/node_modules/node-pty
      export HOME="$TMPDIR"
      export npm_config_nodedir=${nodejs}
      export npm_config_python=python3
      node-gyp rebuild
    )
    # fs-ext compiles its C++ binding (build/Release/fs_ext.node) in its own
    # install script via node-gyp. That script downloads node headers from
    # nodejs.org, which the build sandbox does not allow, so build the
    # binding explicitly from the pinned nodejs headers, the same way as
    # node-pty above. The headless profile loads fs-ext at boot for its
    # session write lock.
    (
      cd node_modules/.pnpm/fs-ext@*/node_modules/fs-ext
      export HOME="$TMPDIR"
      export npm_config_nodedir=${nodejs}
      export npm_config_python=python3
      node-gyp rebuild
    )
    pnpm run build
    runHook postBuild
  '';

  installPhase = ''
    runHook preInstall
    mkdir -p "$out"
    # The CLI resolves workspace packages through the pnpm node_modules
    # layout at runtime, so ship the built repo together with node_modules.
    cp -r . "$out/"
    rm -rf "$out/.git" "$out/.github" "$out/website" \
      "$out/.agents" "$out/.claude" \
      "$out/node_modules/.pnpm/node_modules/@deepseek-ai/website" \
      "$out/node_modules/.cache"
    mkdir -p "$out/bin"
    makeBinaryWrapper "${nodejs}/bin/node" "$out/bin/dsh" \
      --add-flags "--expose-internals" \
      --add-flags "$out/apps/cli/lib/bin.js" \
      --append-flags ""
    # ACP automation server app: JSON-RPC stdio bin over the agent spine.
    # Same HMR internals requirement as the CLI.
    makeBinaryWrapper "${nodejs}/bin/node" "$out/bin/dsh-acp-demo" \
      --add-flags "--expose-internals" \
      --add-flags "$out/packages/examples/acp-demo/lib/bin.js" \
      --append-flags ""
    runHook postInstall
  '';

  meta = {
    description = "DeepSeek Harness CLI (dsh)";
    homepage = "https://github.com/deepseek-ai/deepseek-harness";
    license = lib.licenses.mit;
    mainProgram = "dsh";
    platforms = lib.platforms.all;
  };
}
